#!/bin/busybox ash
# mocula.sh のデジタルズーム（取得範囲指定）関連の関数を検証する。
# camera-sync レスポンスのパース(parse_capture_region)と、撮影経路の切り替え・
# タイムスタンプ OSD のオンオフ・失敗時フォールバック(capture_jpeg)を、
# /scripts/cmd と ffmpeg をスタブ化することで実機無しで検証する
# （→ atom-linked-firefly.md 実装計画、mocula.md「タイムスタンプ(OSD)の扱い」参照）。

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
# /scripts/cmd は絶対パス呼び出しなので PATH 経由では差し替えられない。test_mocula_timing.sh
# が /scripts/fwstate.sh を差し替えているのと同じ手法で、$CMD_BIN という間接参照に置き換える
# (シングルクォートの sed なので、ここでは展開されず文字列 "$CMD_BIN" のまま埋め込まれる)。
FUNCTIONS_FILE=$(mktemp)
awk '/^case "\$1" in/{exit} {print}' "$SCRIPT" \
  | sed "s#\. /scripts/fwstate\.sh#. $FWSTATE#" \
  | sed 's#/scripts/cmd#$CMD_BIN#g' \
  > "$FUNCTIONS_FILE"

# テスト毎に隔離された WORK/STUBDIR を用意し、/scripts/cmd 相当のスタブと ffmpeg スタブを置く。
# 呼び出しの有無・順序は CALL_LOG への追記で観測する。
setup() {
  WORK=$(mktemp -d)
  STUBDIR=$WORK/bin
  mkdir -p "$STUBDIR"
  LOGFILE=$WORK/mocula.log
  CALL_LOG=$WORK/calls.log
  : > "$CALL_LOG"
  CMD_BIN=$STUBDIR/cmd
  PROPERTY_OFF_RESULT=ok
  FFMPEG_RESULT=ok

  cat > "$STUBDIR/cmd" <<'STUB'
#!/bin/sh
if [ "$1" = "jpeg" ] && [ "$2" = "0" ]; then
  echo "call:jpeg0" >> "$CALL_LOG"
  printf 'H1\nH2\nH3\nCH0-RAW-DATA\n'
elif [ "$1" = "jpeg" ] && [ "$2" = "1" ]; then
  echo "call:jpeg1" >> "$CALL_LOG"
  printf 'H1\nH2\nH3\nCH1-DATA\n'
elif [ "$1" = "property" ] && [ "$2" = "timestamp" ] && [ "$3" = "off" ]; then
  echo "call:property_off" >> "$CALL_LOG"
  if [ "$PROPERTY_OFF_RESULT" = "fail" ]; then
    echo "error"
  else
    echo "ok"
  fi
elif [ "$1" = "property" ] && [ "$2" = "timestamp" ] && [ "$3" = "on" ]; then
  echo "call:property_on" >> "$CALL_LOG"
  echo "ok"
else
  echo "call:unknown:$*" >> "$CALL_LOG"
fi
STUB
  chmod +x "$STUBDIR/cmd"

  cat > "$STUBDIR/ffmpeg" <<'STUB'
#!/bin/sh
echo "call:ffmpeg" >> "$CALL_LOG"
if [ "$FFMPEG_RESULT" = "fail" ]; then
  exit 1
fi
for OUT in "$@"; do :; done
echo "FFMPEG-OUTPUT" > "$OUT"
STUB
  chmod +x "$STUBDIR/ffmpeg"
}

teardown() { rm -rf "$WORK"; }
calls() { tr '\n' ' ' < "$CALL_LOG"; }

# ---- parse_capture_region ----

# $1=RESPONSE、$2以降は事前に設定しておく CAPTURE_X/Y/W/H(前回値の持ち越し確認用、省略可)
run_parse() {
  RESP=$1
  PREV_X=${2:-}
  PREV_Y=${3:-}
  PREV_W=${4:-}
  PREV_H=${5:-}
  (
    . "$FUNCTIONS_FILE"
    LOGFILE=$WORK/mocula.log
    RESPONSE=$RESP
    CAPTURE_X=$PREV_X
    CAPTURE_Y=$PREV_Y
    CAPTURE_W=$PREV_W
    CAPTURE_H=$PREV_H
    parse_capture_region
    printf '%s %s %s %s\n' "$CAPTURE_X" "$CAPTURE_Y" "$CAPTURE_W" "$CAPTURE_H" > "$WORK/parsed.txt"
  )
  cat "$WORK/parsed.txt"
}

echo "== parse_capture_region: 正常な JSON から x/y/width/height を取得 =="
setup
RESULT=$(run_parse '{"success":true,"data":{"captureRegion":{"x":320,"y":180,"width":1280},"isEnabled":true}}')
check "x/y/width/height" "320 180 1280 720" "$RESULT"
teardown

echo "== parse_capture_region: フィールド欠損は指定なしに倒す =="
setup
RESULT=$(run_parse '{"data":{"captureRegion":{"x":320,"y":180},"isEnabled":true}}')
check "width欠損 -> 指定なし" " " "$(echo "$RESULT" | awk '{print $1, $2}')"
teardown

echo "== parse_capture_region: 境界値 =="
setup
RESULT=$(run_parse '{"data":{"captureRegion":{"x":0,"y":0,"width":639}}}')
check "width=639(下限未満) -> 指定なし" "" "$(echo "$RESULT" | awk '{print $3}')"
teardown

setup
RESULT=$(run_parse '{"data":{"captureRegion":{"x":0,"y":0,"width":640}}}')
check "width=640(下限) -> 採用" "640 360" "$(echo "$RESULT" | awk '{print $3, $4}')"
teardown

setup
RESULT=$(run_parse '{"data":{"captureRegion":{"x":0,"y":0,"width":1920}}}')
check "width=1920(上限) -> 採用" "1920 1080" "$(echo "$RESULT" | awk '{print $3, $4}')"
teardown

setup
RESULT=$(run_parse '{"data":{"captureRegion":{"x":0,"y":0,"width":1921}}}')
check "width=1921(上限超) -> 指定なし" "" "$(echo "$RESULT" | awk '{print $3}')"
teardown

setup
RESULT=$(run_parse '{"data":{"captureRegion":{"x":0,"y":0,"width":1000}}}')
check "width%16!=0 -> 指定なし" "" "$(echo "$RESULT" | awk '{print $3}')"
teardown

setup
RESULT=$(run_parse '{"data":{"captureRegion":{"x":1,"y":0,"width":1920}}}')
check "x+width>1920 -> 指定なし" "" "$(echo "$RESULT" | awk '{print $3}')"
teardown

setup
RESULT=$(run_parse '{"data":{"captureRegion":{"x":0,"y":1,"width":1920}}}')
check "y+height>1080 -> 指定なし" "" "$(echo "$RESULT" | awk '{print $3}')"
teardown

setup
RESULT=$(run_parse '{"data":{"captureRegion":{"x":1280,"y":675,"width":640}}}')
check "右下角ちょうど -> 採用" "1280 675 640 360" "$RESULT"
teardown

echo "== parse_capture_region: レスポンスから消えたら前回値をリセット =="
setup
RESULT=$(run_parse '{"data":{"isEnabled":true}}' 320 180 1280 720)
check "captureRegionキー無し -> 全てリセット" "   " "$RESULT"
teardown

# ---- capture_jpeg ----

run_capture() { # CAPTURE_W が空なら未設定ケース
  (
    . "$FUNCTIONS_FILE"
    LOGFILE=$WORK/mocula.log
    export CALL_LOG PROPERTY_OFF_RESULT FFMPEG_RESULT
    PATH="$STUBDIR:$PATH"
    CAPTURE_X=$1 CAPTURE_Y=$2 CAPTURE_W=$3 CAPTURE_H=$4
    capture_jpeg "$WORK/out.jpg" > /dev/null
  )
}

echo "== capture_jpeg: ズーム未設定なら cmd jpeg 1 のみ(property には触れない) =="
setup
run_capture "" "" "" ""
check "呼び出しは jpeg1 のみ" "call:jpeg1" "$(calls | sed 's/ $//')"
check "出力に ch1 のデータが入る" "yes" "$(grep -q CH1-DATA "$WORK/out.jpg" && echo yes || echo no)"
teardown

echo "== capture_jpeg: ズーム設定時は off -> jpeg0 -> on -> ffmpeg の順 =="
setup
run_capture 320 180 1280 720
check "呼び出し順" "call:property_off call:jpeg0 call:property_on call:ffmpeg" "$(calls | sed 's/ $//')"
check "出力は ffmpeg の結果" "yes" "$(grep -q FFMPEG-OUTPUT "$WORK/out.jpg" && echo yes || echo no)"
teardown

echo "== capture_jpeg: property off が失敗したら ch0 に進まず jpeg1 にフォールバック =="
setup
PROPERTY_OFF_RESULT=fail
run_capture 320 180 1280 720
check "呼び出しは property_off と jpeg1 のみ(jpeg0/ffmpeg は呼ばれない)" "call:property_off call:jpeg1" "$(calls | sed 's/ $//')"
check "フォールバックログが出る" "yes" "$(grep -q 'falling back to ch1' "$LOGFILE" && echo yes || echo no)"
teardown

echo "== capture_jpeg: ffmpeg が失敗したら jpeg1 にフォールバック(on は既に呼ばれている) =="
setup
FFMPEG_RESULT=fail
run_capture 320 180 1280 720
check "呼び出し順(ffmpeg失敗後も jpeg1 で締める)" "call:property_off call:jpeg0 call:property_on call:ffmpeg call:jpeg1" "$(calls | sed 's/ $//')"
check "フォールバックログが出る" "yes" "$(grep -q 'falling back to ch1' "$LOGFILE" && echo yes || echo no)"
check "出力は ch1 のデータ(ffmpeg の出力ではない)" "yes" "$(grep -q CH1-DATA "$WORK/out.jpg" && echo yes || echo no)"
teardown

rm -f "$FUNCTIONS_FILE"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
