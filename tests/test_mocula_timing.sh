#!/bin/busybox ash
# mocula.sh の run_daemon が、camera-sync から受け取る firstUploadDelay / checkInterval /
# uploadUrls を正しく消化して、設定した checkInterval どおりの間隔で撮影するかを検証する。
# camera_sync / capture_and_upload / sleep をスタブ化し、実時間をシミュレートすることで
# 実機無しで動作フローを検証する（→ mocula.md の「アップロードタイミング」参照）。
#
# camera_sync のスタブは resolveUploadSchedule
# (mocula-backend/src/models/CameraUploadSchedule.ts) と同じ「サーバ時計基準の
# next_capture_at を horizon 分だけ先出しする」形をなぞっている。これにより
# run_daemon 側の URL_QUEUE / UPLOAD_TIMER の扱いが正しいかどうかを検証できる。

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

# checkInterval と、任意でオーバーヘッド秒数(sync 自体に掛かる時間の模擬)を指定して
# run_daemon を MAX_ITERATIONS 秒分シミュレートし、撮影間隔がすべて checkInterval と
# 一致するかどうかを検証する。
run_case() { # checkInterval overheadSeconds
  CASE_CHECK_INTERVAL=$1
  CASE_OVERHEAD=${2:-0}
  WORK=$(mktemp -d)
  CAPTURE_LOG=$WORK/captures.txt
  : > "$CAPTURE_LOG"

  cat > "$WORK/mconfig" <<'EOF'
[global]
tenantKey=test-tenant
cameraKey=test-camera
EOF

  (
    . "$FUNCTIONS_FILE"

    MCONFIG=$WORK/mconfig
    LOGFILE=$WORK/mocula.log
    MAX_ITERATIONS=1500
    HORIZON=90
    SIM_TIME=0
    ITERATIONS=0
    NEXT_CAPTURE_SIM_TIME=-1

    # sleep を実時間を消費しないシミュレート時間の進行に置き換える
    sleep() {
      SIM_TIME=$((SIM_TIME + $1))
      ITERATIONS=$((ITERATIONS + 1))
      [ "$ITERATIONS" -ge "$MAX_ITERATIONS" ] && exit 0
    }

    # resolveUploadSchedule と同じ形の簡易スタブ
    camera_sync() {
      SIM_TIME=$((SIM_TIME + CASE_OVERHEAD))
      IS_ENABLED=true
      CHECK_INTERVAL=$CASE_CHECK_INTERVAL

      if [ "$NEXT_CAPTURE_SIM_TIME" -lt 0 ] || [ "$NEXT_CAPTURE_SIM_TIME" -lt "$SIM_TIME" ]; then
        NEXT_CAPTURE_SIM_TIME=$SIM_TIME
      fi

      HORIZON_END=$((SIM_TIME + HORIZON))
      COUNT=0
      FIRST_UPLOAD_DELAY=0
      URLS=""
      CURSOR=$NEXT_CAPTURE_SIM_TIME
      while [ "$CURSOR" -lt "$HORIZON_END" ]; do
        [ "$COUNT" -eq 0 ] && FIRST_UPLOAD_DELAY=$((CURSOR - SIM_TIME))
        COUNT=$((COUNT + 1))
        URLS="${URLS}dummy-url-${COUNT}
"
        CURSOR=$((CURSOR + CASE_CHECK_INTERVAL))
      done
      NEXT_CAPTURE_SIM_TIME=$CURSOR
      NEW_URL_QUEUE=$(printf '%s' "$URLS")
    }

    # 実際の撮影・アップロードの代わりに、シミュレート時刻をログへ記録するだけ
    capture_and_upload() {
      [ -z "$UPLOAD_URL" ] && return 1
      echo "$SIM_TIME" >> "$CAPTURE_LOG"
    }

    run_daemon
  )

  COUNT=$(wc -l < "$CAPTURE_LOG")
  check "checkInterval=$CASE_CHECK_INTERVAL overhead=${CASE_OVERHEAD}s: enough captures observed (not stalled)" "yes" \
    "$([ "$COUNT" -ge 3 ] && echo yes || echo no)"

  if [ "$CASE_OVERHEAD" -eq 0 ]; then
    # sync 自体に遅延が無い場合は、連続する撮影間隔がすべて checkInterval と厳密に
    # 一致するはず(2番目以降の間隔で判定。1本目は初期化直後の即時撮影であり得るため)
    BAD_GAPS=$(awk -v want="$CASE_CHECK_INTERVAL" 'NR>2 && ($1-prev)!=want{c++} {prev=$1} END{print c+0}' "$CAPTURE_LOG")
    check "checkInterval=$CASE_CHECK_INTERVAL: all gaps equal checkInterval" "0" "$BAD_GAPS"
  fi

  rm -rf "$WORK"
}

echo "== 同期周期(60秒)の約数・倍数を含む様々な checkInterval で、間隔が縮まない/伸びないことを確認 =="
for ci in 25 30 45 59 60 61 90 119 120 300; do
  run_case "$ci" 0
done

echo "== camera-sync 自体に遅延がある場合でも、撮影が永久に止まらないことを確認 =="
# checkInterval=60 は sync 周期そのものと一致し、以前の実装ではここで
# 2回目以降のアップロードが永久に発生しなくなる不具合があった(回帰確認)
run_case 60 5
run_case 300 5
run_case 90 5

rm -f "$FUNCTIONS_FILE"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
