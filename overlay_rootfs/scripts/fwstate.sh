# ファームウェア更新のstateファイルを読み書きする共通ライブラリ。
# mocula.sh / fwrollback.sh / S76mocula から . で読み込んで使う。
#
# なぜ専用のライブラリにしてあるか:
#   - stateファイルは3つのスクリプトから読み書きされるため、形式のずれが致命的になる
#   - 以前は state を `. "$STATE_FILE"` で直接ソースしていた。この方式では値に空白や
#     シェルのメタ文字が混じるとソースした側のシェルが構文エラーで終了してしまい、
#     S76mocula ならデーモンが起動せず、fwrollback.sh ならロールバック監視が止まる
#     （どちらも復旧不能になる）。値は解釈せず読むだけにする。
#   - 書き込みは一時ファイル+mv で原子的に行い、電源断による切り詰めを防ぐ。
#     部分更新のための sed -i はこの保証を壊すため使わない。

FWSTATE_DIR=${FWSTATE_DIR:-/media/mmc/fwupdate}
FWSTATE_FILE="$FWSTATE_DIR/state"
# 更新関連のイベントは再起動を跨いで残す必要があるため、tmpfs ではなく永続領域に記録する
FWSTATE_LOGFILE=${FWSTATE_LOGFILE:-/media/mmc/atomhack.log}

fwstate_log() {
  echo "$(date +"%Y/%m/%d %H:%M:%S") : fwstate: $*" >> "$FWSTATE_LOGFILE" 2>/dev/null
}

fwstate_get() {
  awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$FWSTATE_FILE" 2>/dev/null
}

# stateを読み、TARGET_VERSION / PREV_VERSION / PHASE / TIMEOUT / BOOT_COUNT / REASON を設定する。
# stateが無い、または壊れている場合は 1 を返す（壊れていた場合は破棄する）。
load_state() {
  TARGET_VERSION=""
  PREV_VERSION=""
  PHASE=""
  TIMEOUT=600
  BOOT_COUNT=0
  REASON=""

  [ -f "$FWSTATE_FILE" ] || return 1

  # 値は解釈せず取り出すだけ。許可された文字以外を含む行があれば壊れているとみなす。
  # 電源断で切り詰められた state や、サーバから来た想定外のバージョン文字列を弾く。
  if ! awk '
    /^[A-Z_]+=[A-Za-z0-9._:-]*$/ { next }
    /./ { exit 1 }
  ' "$FWSTATE_FILE" 2>/dev/null; then
    fwstate_log "state file is corrupt, discarding: $(head -c 200 "$FWSTATE_FILE" 2>/dev/null | tr -d '\n')"
    rm -rf "$FWSTATE_DIR"
    return 1
  fi

  TARGET_VERSION=$(fwstate_get TARGET_VERSION)
  PREV_VERSION=$(fwstate_get PREV_VERSION)
  PHASE=$(fwstate_get PHASE)
  BOOT_COUNT=$(fwstate_get BOOT_COUNT)
  REASON=$(fwstate_get REASON)

  STATE_TIMEOUT=$(fwstate_get TIMEOUT)
  case "$STATE_TIMEOUT" in
    '' | *[!0-9]*) ;;
    *) TIMEOUT="$STATE_TIMEOUT" ;;
  esac

  case "$BOOT_COUNT" in
    '' | *[!0-9]*) BOOT_COUNT=0 ;;
  esac

  return 0
}

# state を原子的に書く。失敗したら 1 を返す。
# 呼び出し側は失敗を必ず検査すること: state が永続化できていないのに更新を適用して再起動すると、
# fwrollback.sh が state を見つけられずロールバック監視が丸ごと無効になる。
write_state() {
  mkdir -p "$FWSTATE_DIR" 2>/dev/null || return 1
  FWSTATE_TMP="$FWSTATE_DIR/state.tmp.$$"
  if ! {
    echo "TARGET_VERSION=$1"
    echo "PREV_VERSION=$2"
    echo "PHASE=$3"
    echo "TIMEOUT=$4"
    echo "BOOT_COUNT=$5"
    echo "REASON=$6"
  } > "$FWSTATE_TMP" 2>/dev/null; then
    rm -f "$FWSTATE_TMP"
    return 1
  fi
  # rename の前に内容をディスクへ流す
  sync
  if ! mv "$FWSTATE_TMP" "$FWSTATE_FILE" 2>/dev/null; then
    rm -f "$FWSTATE_TMP"
    return 1
  fi
  sync
  return 0
}

# PHASE と REASON だけを差し替える。他の値は現在の state から引き継ぐ。
# sed -i による部分書き換えの代わりに使う（原子性を保つため）。
set_state_phase() {
  load_state || return 1
  write_state "$TARGET_VERSION" "$PREV_VERSION" "$1" "$TIMEOUT" "$BOOT_COUNT" "$2"
}

# BOOT_COUNT を +1 する。
increment_state_boot_count() {
  load_state || return 1
  write_state "$TARGET_VERSION" "$PREV_VERSION" "$PHASE" "$TIMEOUT" "$((BOOT_COUNT + 1))" "$REASON"
}
