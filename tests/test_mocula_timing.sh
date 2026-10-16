#!/bin/busybox ash
# mocula.sh が、camera-sync から受け取る firstUploadDelay / checkInterval / uploadUrls を
# 設定した checkInterval どおりの間隔で消化するかを検証する
# （→ atomcam_tools-private の docs/mocula.md の「アップロードタイミング」参照）。
#
# 構造は「run_daemon(60秒ごとに sync) → run_upload_batch(sync 1回ぶんの URL を時刻どおりに
# 消化) → capture_and_upload(撮影〜送信、バックグラウンド)」の3層。前半は時計と sleep を
# スタブ化した仮想時間で、後半は実際のバックグラウンドプロセスと実時間で検証する。
#
# camera_sync のスタブは resolveUploadSchedule
# (mocula-backend/src/models/CameraUploadSchedule.ts) と同じ「サーバ時計基準の
# next_capture_at を horizon 分だけ先出しする」形をなぞっている。
#
# 実機の mocula.sh は bash で動く。busybox ash に加えて bash でも通ること:
#   busybox ash tests/test_mocula_timing.sh && bash tests/test_mocula_timing.sh

REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$REPO/overlay_rootfs/scripts/mocula.sh
FWSTATE=$REPO/overlay_rootfs/scripts/fwstate.sh

PASS=0
FAIL=0
check() { # desc expected actual
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    echo "  ok   $1"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL $1: expected [$2] got [$3]"
  fi
}

# run_daemon 本体を含む関数群だけを取り出す(末尾の on/off/watchdog の CLI ディスパッチは除く)。
# fwstate.sh は絶対パス /scripts/fwstate.sh を参照するため、実ファイルへ差し替える。
FUNCTIONS_FILE=$(mktemp)
awk '/^case "\$1" in/{exit} {print}' "$SCRIPT" | sed "s#\. /scripts/fwstate\.sh#. $FWSTATE#" > "$FUNCTIONS_FILE"

# 仮想時間のスタブ一式。時刻は 1/100 秒単位の整数(SIM_CS)で持ち、fork せずに進める。
# バッチは本番では別プロセスで並行に走る。ここではサブシェルで同期実行し、サブシェルが
# SIM_CS のコピーを独自に進めることで「親の時計を止めずに並行して進む」状況を再現する。
SIM_STUBS=$(mktemp)
cat > "$SIM_STUBS" <<'STUBS'
read_monotonic() {
  SIM_FRAC=$((SIM_CS % 100))
  [ "$SIM_FRAC" -lt 10 ] && SIM_FRAC=0$SIM_FRAC
  MONO_NOW=$((SIM_CS / 100)).$SIM_FRAC
}

sleep() {
  case "$1" in
    *.*)
      SLEEP_INT=${1%%.*}
      SLEEP_FRAC=${1#*.}00
      SLEEP_FRAC=${SLEEP_FRAC%"${SLEEP_FRAC#??}"}
      SLEEP_FRAC=${SLEEP_FRAC#0}
      ;;
    *)
      SLEEP_INT=$1
      SLEEP_FRAC=0
      ;;
  esac
  SIM_CS=$((SIM_CS + ${SLEEP_INT:-0} * 100 + ${SLEEP_FRAC:-0}))
  [ "$SIM_CS" -ge "$SIM_END_CS" ] && exit 0
  return 0
}

spawn_upload_batch() {
  (run_upload_batch)
}

# 撮影〜送信はバックグラウンドなので、スケジューラ側の時計は起動コストぶんしか進まない
spawn_upload() {
  read_monotonic
  echo "$MONO_NOW" >> "$CAPTURE_LOG"
  SIM_CS=$((SIM_CS + SPAWN_COST_CS))
}
STUBS

new_work() {
  WORK=$(mktemp -d)
  CAPTURE_LOG=$WORK/captures.txt
  SYNC_LOG=$WORK/syncs.txt
  : > "$CAPTURE_LOG"
  : > "$SYNC_LOG"
  cat > "$WORK/mconfig" <<'CONF'
[global]
tenantKey=test-tenant
cameraKey=test-camera
CONF
}

# run_daemon を SIM_SECONDS 秒ぶん仮想時間で動かす。
#   $1 checkInterval  $2 sync の所要秒数  $3 N回に1回 sync を失敗させる(0 で無効)
simulate_daemon() {
  CASE_CHECK_INTERVAL=$1
  CASE_SYNC_SECONDS=$2
  CASE_FAIL_EVERY=${3:-0}
  new_work
  (
    . "$FUNCTIONS_FILE"
    . "$SIM_STUBS"

    MCONFIG=$WORK/mconfig
    LOGFILE=$WORK/mocula.log
    PAUSED_FILE=$WORK/paused
    UPLOAD_PID_DIR=$WORK/uploads
    SIM_CS=0
    SIM_END_CS=$((SIM_SECONDS * 100))
    SPAWN_COST_CS=30
    HORIZON_CS=9000
    NEXT_CAPTURE_CS=-1
    SYNC_CALLS=0

    # resolveUploadSchedule と同じ形の簡易スタブ。サーバが時刻を見る瞬間は往復の中間に置く
    camera_sync() {
      read_monotonic
      SYNC_SENT_MONO=$MONO_NOW
      echo "$MONO_NOW" >> "$SYNC_LOG"
      SERVER_NOW_CS=$((SIM_CS + CASE_SYNC_SECONDS * 50))
      SIM_CS=$((SIM_CS + CASE_SYNC_SECONDS * 100))
      read_monotonic
      SYNC_RECEIVED_MONO=$MONO_NOW
      LIVE_ACTION=none
      NEW_URL_QUEUE=""

      SYNC_CALLS=$((SYNC_CALLS + 1))
      if [ "$CASE_FAIL_EVERY" -gt 0 ] && [ $((SYNC_CALLS % CASE_FAIL_EVERY)) -eq 0 ]; then
        return 1
      fi

      IS_ENABLED=true
      CHECK_INTERVAL=$CASE_CHECK_INTERVAL
      # 過去になった next_capture_at は now から立て直す(自己修復クランプ)
      [ "$NEXT_CAPTURE_CS" -lt "$SERVER_NOW_CS" ] && NEXT_CAPTURE_CS=$SERVER_NOW_CS

      COUNT=0
      FIRST_UPLOAD_DELAY=0
      URLS=""
      CURSOR=$NEXT_CAPTURE_CS
      while [ "$CURSOR" -lt $((SERVER_NOW_CS + HORIZON_CS)) ] && [ "$COUNT" -lt 60 ]; do
        # サーバは firstUploadDelay を秒へ四捨五入して返す
        [ "$COUNT" -eq 0 ] && FIRST_UPLOAD_DELAY=$(((CURSOR - SERVER_NOW_CS + 50) / 100))
        COUNT=$((COUNT + 1))
        URLS="${URLS}https://example.invalid/image-${SYNC_CALLS}-${COUNT}.tar?X-Amz-Signature=abc&X-Amz-Expires=300
"
        CURSOR=$((CURSOR + CASE_CHECK_INTERVAL * 100))
      done
      NEXT_CAPTURE_CS=$CURSOR
      NEW_URL_QUEUE=$(printf '%s' "$URLS")
    }

    apply_firmware_update() { :; }

    run_daemon
  )
}

count_lines() { wc -l < "$1" | tr -d ' '; }

# 連続する値の差のうち、[want-tol, want+tol] に収まらないものの個数。
# warmup 秒より前に始まる差は見ない。起動直後の1回目の sync は、応答が返った時点で
# 最初の枠の時刻を過ぎているため、その枠だけ sync の所要時間ぶん遅れて撮影される。
bad_gaps() { # file want tolerance warmup
  sort -n "$1" | awk -v want="$2" -v tol="$3" -v warmup="${4:-0}" '
    NR > 1 && prev >= warmup { d = $1 - prev; if (d < want - tol - 0.001 || d > want + tol + 0.001) c++ }
    { prev = $1 }
    END { print c + 0 }'
}

max_gap() { # file
  sort -n "$1" | awk 'NR > 1 && $1 - prev > m { m = $1 - prev } { prev = $1 } END { printf "%d\n", m }'
}

SIM_SECONDS=1500

echo "== 撮影間隔が checkInterval と一致する(sync の所要時間ゼロ) =="
for ci in 3 10 25 30 45 59 60 61 90 119 120 300; do
  simulate_daemon "$ci" 0
  check "checkInterval=$ci: all gaps equal checkInterval" "0" "$(bad_gaps "$CAPTURE_LOG" "$ci" 0)"
  # 取りこぼしも滞留もしていなければ、撮影枚数は経過時間 / checkInterval になる
  EXPECTED=$((SIM_SECONDS / ci))
  COUNT=$(count_lines "$CAPTURE_LOG")
  check "checkInterval=$ci: capture count matches elapsed time" "yes" \
    "$([ "$COUNT" -ge $((EXPECTED - 1)) ] && [ "$COUNT" -le $((EXPECTED + 1)) ] && echo yes || echo "no($COUNT/$EXPECTED)")"
  rm -rf "$WORK"
done

echo "== sync に時間が掛かっても、sync 周期と撮影間隔が延びない =="
for ci in 3 10 60 90 300; do
  simulate_daemon "$ci" 6
  check "checkInterval=$ci sync=6s: sync period stays 60s" "0" "$(bad_gaps "$SYNC_LOG" 60 0)"
  check "checkInterval=$ci sync=6s: all gaps equal checkInterval" "0" "$(bad_gaps "$CAPTURE_LOG" "$ci" 0 $((6 + ci)))"
  rm -rf "$WORK"
done

echo "== firstUploadDelay の秒への丸めによるずれは 1 秒以内に収まり、累積しない =="
for ci in 3 10; do
  simulate_daemon "$ci" 5
  check "checkInterval=$ci sync=5s: gaps within 1s of checkInterval" "0" "$(bad_gaps "$CAPTURE_LOG" "$ci" 1 $((5 + ci)))"
  EXPECTED=$((SIM_SECONDS / ci))
  COUNT=$(count_lines "$CAPTURE_LOG")
  check "checkInterval=$ci sync=5s: capture count matches elapsed time" "yes" \
    "$([ "$COUNT" -ge $((EXPECTED - 2)) ] && [ "$COUNT" -le $((EXPECTED + 2)) ] && echo yes || echo "no($COUNT/$EXPECTED)")"
  rm -rf "$WORK"
done

echo "== sync が失敗しても、次に成功した sync から撮影が再開する =="
simulate_daemon 10 0 3
# 失敗した回のぶんは、発行済みの枠(地平線90秒)が尽きてから次の成功 sync までが空く
check "sync fails every 3rd time: captures keep coming" "yes" \
  "$([ "$(count_lines "$CAPTURE_LOG")" -ge 100 ] && echo yes || echo no)"
check "sync fails every 3rd time: longest gap stays within one sync period" "yes" \
  "$([ "$(max_gap "$CAPTURE_LOG")" -le 60 ] && echo yes || echo "no($(max_gap "$CAPTURE_LOG"))")"
rm -rf "$WORK"

# run_upload_batch を単体で、仮想時間で1回だけ動かす。
#   $1 バッチ開始時点で sync からどれだけ経っているか(秒)  $2 追加の設定(eval される)
simulate_batch() {
  new_work
  (
    . "$FUNCTIONS_FILE"
    . "$SIM_STUBS"
    LOGFILE=$WORK/mocula.log
    PAUSED_FILE=$WORK/paused
    UPLOAD_PID_DIR=$WORK/uploads
    SIM_CS=$((1000 * 100 + $1 * 100))
    SIM_END_CS=$((SIM_CS + 100000))
    SPAWN_COST_CS=30
    SYNC_SENT_MONO=1000.00
    SYNC_RECEIVED_MONO=1000.00
    FIRST_UPLOAD_DELAY=0
    CHECK_INTERVAL=10
    UPTIME_START=""
    UPTIME_END=""
    NEW_URL_QUEUE="u1
u2
u3
u4
u5"
    eval "$2"
    run_upload_batch
  )
}

echo "== バッチ単体: 遅れた枠・一時停止・稼働時間外 =="
simulate_batch 0 ""
check "on time: every slot is captured" "5" "$(count_lines "$CAPTURE_LOG")"
rm -rf "$WORK"

# sync から 25 秒遅れて開始: 0秒・10秒の枠は1周期以上遅れているので捨て、20秒の枠から使う
simulate_batch 25 ""
check "started 25s late: slots more than one interval late are dropped" "3" "$(count_lines "$CAPTURE_LOG")"
check "started 25s late: remaining slots keep the original schedule" "1025.00 1030.00 1040.00" \
  "$(tr '\n' ' ' < "$CAPTURE_LOG" | sed 's/ $//')"
check "started 25s late: dropped slots are logged" "2" "$(grep -c 'late' "$WORK/mocula.log")"
rm -rf "$WORK"

simulate_batch 0 'touch "$PAUSED_FILE"'
check "paused after the batch was issued: nothing is captured" "0" "$(count_lines "$CAPTURE_LOG")"
rm -rf "$WORK"

# 現在時刻を含まない稼働時間帯を作る
if [ "$(date +%H)" -lt 12 ]; then
  OUTSIDE='UPTIME_START=130000; UPTIME_END=140000'
else
  OUTSIDE='UPTIME_START=010000; UPTIME_END=020000'
fi
simulate_batch 0 "$OUTSIDE"
check "outside uptime window: nothing is captured" "0" "$(count_lines "$CAPTURE_LOG")"
rm -rf "$WORK"

simulate_batch 0 'UPTIME_START=000000; UPTIME_END=235959'
check "inside uptime window: every slot is captured" "5" "$(count_lines "$CAPTURE_LOG")"
rm -rf "$WORK"

simulate_batch 0 'CHECK_INTERVAL="1; touch $WORK/injected"'
check "non-numeric checkInterval: batch is rejected" "0" "$(count_lines "$CAPTURE_LOG")"
check "non-numeric checkInterval: value is not evaluated" "no" "$([ -e "$WORK/injected" ] && echo yes || echo no)"
rm -rf "$WORK"

# 実際のバックグラウンドプロセスと実時間で run_upload_batch を動かす(スタブは撮影〜送信のみ)。
#   $1 1回の撮影〜送信に掛かる秒数  $2 同時実行数の上限  $3 1バッチの URL の本数
#   $4 続けて起動するバッチの数(省略時 1)。本番同様、バッチごとに別プロセスにする
run_real_batch() {
  CASE_UPLOAD_SECONDS=$1
  CASE_MAX_PARALLEL=$2
  CASE_URL_COUNT=$3
  CASE_BATCHES=${4:-1}
  new_work
  (
    . "$FUNCTIONS_FILE"
    LOGFILE=$WORK/mocula.log
    PAUSED_FILE=$WORK/paused
    UPLOAD_PID_DIR=$WORK/uploads
    MAX_PARALLEL_UPLOADS=$CASE_MAX_PARALLEL
    CHECK_INTERVAL=1
    FIRST_UPLOAD_DELAY=0
    UPTIME_START=""
    UPTIME_END=""
    NEW_URL_QUEUE=""
    i=0
    while [ "$i" -lt "$CASE_URL_COUNT" ]; do
      i=$((i + 1))
      NEW_URL_QUEUE="${NEW_URL_QUEUE}https://example.invalid/tmp/image-$i.tar?X-Amz-Signature=*&X-Amz-Expires=300
"
    done
    NEW_URL_QUEUE=$(printf '%s' "$NEW_URL_QUEUE")

    capture_and_upload() {
      read_monotonic
      echo "$MONO_NOW $UPLOAD_URL" >> "$CAPTURE_LOG"
      sleep "$CASE_UPLOAD_SECONDS"
    }

    cd "$WORK" || exit 1
    BATCH=0
    while [ "$BATCH" -lt "$CASE_BATCHES" ]; do
      BATCH=$((BATCH + 1))
      read_monotonic
      SYNC_SENT_MONO=$MONO_NOW
      SYNC_RECEIVED_MONO=$MONO_NOW
      (run_upload_batch)
    done
  )
}

echo "== 実プロセス: 撮影〜送信が checkInterval より長くても、次の撮影を待たせない =="
run_real_batch 3 10 4
check "upload takes 3s, checkInterval=1: all 4 slots are captured" "4" "$(count_lines "$CAPTURE_LOG")"
# 直列に実行していれば 9 秒掛かる。並行していれば 1本目から4本目まで 3 秒
SPAN_OK=$(awk 'NR == 1 { first = $1 } { last = $1 } END { d = last - first; print (d > 2.7 && d < 3.6) ? "yes" : "no(" d ")" }' "$CAPTURE_LOG")
check "upload takes 3s, checkInterval=1: 4 captures span 3 seconds" "yes" "$SPAN_OK"
check "pre-signed URL reaches the upload intact" "https://example.invalid/tmp/image-4.tar?X-Amz-Signature=*&X-Amz-Expires=300" \
  "$(tail -1 "$CAPTURE_LOG" | cut -d' ' -f2)"
rm -rf "$WORK"

echo "== 実プロセス: 同時実行数の上限 =="
run_real_batch 6 2 4
check "limit=2, uploads never finish in time: only 2 are started" "2" "$(count_lines "$CAPTURE_LOG")"
check "limit=2: skipped slots are logged" "2" "$(grep -c 'still in flight' "$WORK/mocula.log")"
rm -rf "$WORK"

# 上限はバッチごとではなく全体に効く: 1つ目のバッチの 2 本が送信中のまま、次のバッチが始まる
run_real_batch 6 2 2 2
check "limit=2, previous batch still uploading: next batch starts nothing" "2" "$(count_lines "$CAPTURE_LOG")"
check "limit=2, previous batch still uploading: skipped slots are logged" "2" "$(grep -c 'still in flight' "$WORK/mocula.log")"
rm -rf "$WORK"

# 終了した子プロセスを数え続けていると、上限 1 では2本目以降がすべて捨てられる
run_real_batch 0.2 1 3
check "limit=1, uploads finish quickly: finished uploads free their slot" "3" "$(count_lines "$CAPTURE_LOG")"
sleep 1
check "finished uploads remove their own record" "0" "$(ls "$WORK/uploads" | wc -l | tr -d ' ')"
rm -rf "$WORK"

rm -f "$FUNCTIONS_FILE" "$SIM_STUBS"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
