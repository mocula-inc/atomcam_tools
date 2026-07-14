#!/bin/bash

PIDFILE=/var/run/mocula.pid
DISABLEFILE=/var/run/mocula.disabled
LOGFILE=/tmp/log/mocula.log
MCONFIG=/media/mmc/mconfig
# /var/run は tmpfs。起動ごとに消えることが前提で、fwrollback.sh は「更新後の起動で一度でも
# camera-sync に成功したか」の判定にこのファイルを使う。永続領域へ移してはならない。
SYNC_OK_FILE=/var/run/mocula.sync_ok
VERSION_FILE=/etc/mocula.ver
UPDATE_DIR=/media/mmc/update
BACKUP_DIR=/media/mmc/fwbackup
STATE_DIR=/media/mmc/fwupdate
STATE_FILE=$STATE_DIR/state
# ファームウェア更新の記録用。$LOGFILE は /tmp(tmpfs) にあり、まさに診断したい更新再起動で
# 消えてしまうため、更新関連のイベントだけは永続領域にも残す（logrotate 対象のファイルを使う）
FWLOGFILE=/media/mmc/atomhack.log

# stateの読み書き(load_state / write_state / set_state_phase)は fwrollback.sh・S76mocula と
# 共有する必要があるため専用ライブラリに置いてある
FWSTATE_DIR=$STATE_DIR
FWSTATE_LOGFILE=$FWLOGFILE
. /scripts/fwstate.sh

log() {
  echo "$(date +"%Y/%m/%d %H:%M:%S") : $*" >> $LOGFILE
}

# 更新・ロールバック関連のイベント用。再起動を跨いで残す必要があるものだけに使う
log_fw() {
  log "$*"
  echo "$(date +"%Y/%m/%d %H:%M:%S") : mocula.sh: $*" >> $FWLOGFILE 2>/dev/null
}

log_debug() {
  [ "$DEBUG_MODE" = "1" ] || return 0
  echo "$(date +"%Y/%m/%d %H:%M:%S") : [DEBUG] $*" >> $LOGFILE
}

camera_sync_save_error() {
  FAIL_TYPE="$1"
  FAIL_DETAIL="$2"
  SYNC_FAIL_COUNT=$((SYNC_FAIL_COUNT + 1))
  # SD カードの摩耗を防ぐため、連続失敗の 1 回目と以降 10 回ごとにのみ保存する
  [ $SYNC_FAIL_COUNT -ne 1 ] && [ $((SYNC_FAIL_COUNT % 10)) -ne 0 ] && return 0
  ERROR_DIR=/media/mmc/errors
  [ -d /media/mmc ] || return 0
  if ! mkdir -p "$ERROR_DIR" 2>/dev/null; then
    log "camera_sync_save_error: cannot create $ERROR_DIR"
    return 0
  fi

  ROUTER=$(cat /tmp/router_address 2>/dev/null)
  BOOT_TIME=$(awk '/^btime/ {print $2}' /proc/stat)
  BOOT_TIME_STR=$(date -d "@$BOOT_TIME" +"%Y/%m/%d %H:%M:%S" 2>/dev/null)
  if ! cat > "$ERROR_DIR/error-status.txt" 2>/dev/null << EOF
=== Mocula camera-sync error ===
Boot time        : $BOOT_TIME_STR
Error time       : $(date +"%Y/%m/%d %H:%M:%S")
Type             : $FAIL_TYPE
Detail           : $FAIL_DETAIL
Consecutive fails: $SYNC_FAIL_COUNT
WiFi SSID        : ${WIFI_SSID:-(unknown)}
WiFi RSSI        : ${WIFI_RSSI:-(unknown)}
WiFi MAC         : ${WIFI_MAC:-(unknown)}
IP Address       : ${IP_ADDR:-(unknown)}
Default Gateway  : ${ROUTER:-(unknown)}
API origin       : ${API_ORIGIN:-(unknown)}
EOF
  then
    log "camera_sync_save_error: failed to write $ERROR_DIR/error-status.txt"
    return 0
  fi

  [ -f "$LOGFILE" ] && cp "$LOGFILE" "$ERROR_DIR/mocula.log" 2>/dev/null
  [ -f /media/mmc/healthcheck.log ] && cp /media/mmc/healthcheck.log "$ERROR_DIR/healthcheck.log" 2>/dev/null
}

stop_daemon() {
  if [ -f $PIDFILE ]; then
    kill $(cat $PIDFILE) > /dev/null 2>&1
    rm -f $PIDFILE
  fi
  # killall は自スクリプトも巻き込むため、自PID($$)を除外して個別に kill する
  for pid in $(ps | awk -v mypid=$$ '/mocula\.sh/ && $1 != mypid {print $1}'); do
    kill "$pid" > /dev/null 2>&1
  done
}

load_config() {
  eval $(awk -F "=" '
    /^\[/ { section=$0; gsub(/\[/, "", section); gsub(/\]/, "", section); next }
    /^[a-zA-Z]/ { printf "%s_%s=%s\n", section, $1, $2 }
  ' $MCONFIG)

  API_ORIGIN="${global_origin:-https://app.mocula.jp}"
  TENANT_KEY="$global_tenantKey"
  CAMERA_KEY="$global_cameraKey"
  ROLLBACK_TIMEOUT="${firmware_rollbackTimeout:-600}"
  # サーバ時刻によるカメラ時計のフォールバック補正の閾値(秒)。0 で無効化。
  # 常駐 ntpd (S42ntpd) と綱引きにならないよう、既定は大きめにしてある。
  # → mocula.md の「時刻同期」参照
  CLOCK_SKEW_THRESHOLD="${global_clockSkewThreshold:-60}"
}

# カメラ時計での現在時刻(エポックミリ秒)。$((...)) はこの環境では32bit算術で
# オーバーフローするため awk で計算する。
current_epoch_ms() {
  awk '
    FNR==NR && $1=="btime" {b=$2; next}
    FNR==1 {u=$1}
    END {printf "%.0f\n", (b+u)*1000}
  ' /proc/stat /proc/uptime
}

collect_device_info() {
  WIFI_SSID=$(wpa_cli -i wlan0 status 2>/dev/null | grep '^ssid=' | cut -d= -f2)
  WIFI_RSSI=$(awk '/wlan0/ {print int($4)}' /proc/net/wireless 2>/dev/null)
  WIFI_MAC=$(cat /sys/class/net/wlan0/address 2>/dev/null)
  IP_ADDR=$(ifconfig wlan0 2>/dev/null | grep 'inet addr' | awk '{print $2}' | cut -d: -f2)
  IP_MASK=$(ifconfig wlan0 2>/dev/null | grep 'inet addr' | awk '{print $4}' | cut -d: -f2)
  TIMESTAMP=$(current_epoch_ms)
  log_debug "collect_device_info: ssid=$WIFI_SSID rssi=$WIFI_RSSI mac=$WIFI_MAC ip=$IP_ADDR mask=$IP_MASK ts=$TIMESTAMP"
}

build_firmware_update_report() {
  REPORT_JSON=""
  load_state || return 0

  case "$PHASE" in
    failed | rolled_back | rollback_failed) ;;
    *) return 0 ;;
  esac

  if [ -n "$REASON" ]; then
    REPORT_JSON=$(printf ',"firmwareUpdateReport":{"targetVersion":"%s","result":"%s","reason":"%s"}' \
      "$TARGET_VERSION" "$PHASE" "$REASON")
  else
    REPORT_JSON=$(printf ',"firmwareUpdateReport":{"targetVersion":"%s","result":"%s"}' "$TARGET_VERSION" "$PHASE")
  fi
}

parse_firmware_update_offer() {
  FW_JSON=$(echo "$RESPONSE" | sed -n 's/.*"firmwareUpdate":{\([^}]*\)}.*/\1/p')
  if [ -n "$FW_JSON" ]; then
    FW_VERSION=$(echo "$FW_JSON" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
    FW_URL=$(echo "$FW_JSON" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
    FW_SIZE=$(echo "$FW_JSON" | sed -n 's/.*"size":\([0-9]*\).*/\1/p')
    FW_SHA=$(echo "$FW_JSON" | sed -n 's/.*"checksum":"\([a-f0-9]*\)".*/\1/p')
  else
    FW_VERSION=""
    FW_URL=""
    FW_SIZE=""
    FW_SHA=""
  fi
}

# サーバ時刻をフォールバックとしてカメラ時計を補正する。用途はあくまで常駐 ntpd
# (S42ntpd) が機能しない環境（NTPポートが塞がれている等）の救済であり、通常運用では
# CLOCK_SKEW_THRESHOLD 未満の差は無視して ntpd と競合しないようにする。
# capturedAt が不連続になるため、補正した事実は必ずログに残す。
sync_clock_from_server() {
  [ -z "$SERVER_EPOCH" ] && return 0
  [ "$CLOCK_SKEW_THRESHOLD" -le 0 ] && return 0

  # curl の往復時間の半分だけ、サーバがレスポンスを生成した時刻より現在が進んでいると仮定する
  ESTIMATED_SERVER_MS=$(awk "BEGIN{printf \"%.0f\", $SERVER_EPOCH*1000 + $RTT_MS/2}")
  CAMERA_NOW_MS=$(current_epoch_ms)
  SKEW_MS=$(awk "BEGIN{printf \"%.0f\", $ESTIMATED_SERVER_MS - $CAMERA_NOW_MS}")
  SKEW_ABS_MS=$(awk "BEGIN{v=$SKEW_MS; if (v < 0) v = -v; printf \"%.0f\", v}")
  THRESHOLD_MS=$((CLOCK_SKEW_THRESHOLD * 1000))

  if [ "$SKEW_ABS_MS" -gt "$THRESHOLD_MS" ]; then
    NEW_EPOCH_SEC=$(awk "BEGIN{printf \"%.0f\", $ESTIMATED_SERVER_MS/1000}")
    if date -s "@$NEW_EPOCH_SEC" > /dev/null 2>&1; then
      log_fw "clock corrected: skew=${SKEW_MS}ms rtt=${RTT_MS}ms -> set to server time (epoch=${NEW_EPOCH_SEC})"
    else
      log "clock correction failed: date -s @$NEW_EPOCH_SEC"
    fi
  fi
}

camera_sync() {
  collect_device_info
  FW_CURRENT=$(cat "$VERSION_FILE" 2>/dev/null)
  FW_VERSION_JSON=""
  [ -n "$FW_CURRENT" ] && FW_VERSION_JSON=$(printf ',"firmwareVersion":"%s"' "$FW_CURRENT")
  build_firmware_update_report

  log_debug "camera_sync: POST ${API_ORIGIN}/api/v1/camera-sync/${TENANT_KEY}/${CAMERA_KEY}"
  SYNC_REQUEST_MS=$(current_epoch_ms)
  RESPONSE=$(curl --silent --max-time 30 \
    -X POST -H 'Content-Type: application/json' \
    -d "$(printf '{"wifi":{"ssid":"%s","rssi":%s,"mac":"%s"},"ip":{"address":"%s","netmask":"%s"},"timestamp":%s%s%s}' \
      "$WIFI_SSID" "${WIFI_RSSI:-0}" "$WIFI_MAC" "$IP_ADDR" "$IP_MASK" "$TIMESTAMP" "$FW_VERSION_JSON" "$REPORT_JSON")" \
    "${API_ORIGIN}/api/v1/camera-sync/${TENANT_KEY}/${CAMERA_KEY}")
  CURL_EXIT=$?
  SYNC_RESPONSE_MS=$(current_epoch_ms)
  # curl --max-time 30 があるため、RTT を補正しないと最大30秒の誤差になりうる。
  # 差は小さい値だが、両オペランドはエポックミリ秒(32bit算術ではオーバーフローする桁数)
  # なので他の時刻計算と同様に awk で引き算する。
  RTT_MS=$(awk "BEGIN{printf \"%.0f\", $SYNC_RESPONSE_MS - $SYNC_REQUEST_MS}")
  log_debug "camera_sync: curl_exit=$CURL_EXIT response_len=${#RESPONSE}"
  # sync 失敗時、まだ消化していない URL_QUEUE はそのまま残す(有効期限内の
  # pre-signed URL であり、この sync が失敗したことと無関係に使える)。
  # NEW_URL_QUEUE だけクリアして、直前の成功時の値を誤って合流させない。
  if [ $CURL_EXIT -ne 0 ]; then
    log "camera-sync failed: curl error $CURL_EXIT"
    camera_sync_save_error "curl_error" "exit_code=$CURL_EXIT"
    NEW_URL_QUEUE=""
    FW_URL=""
    return 1
  fi
  if [ -z "$RESPONSE" ]; then
    log "camera-sync failed: empty response"
    camera_sync_save_error "empty_response" "(no body)"
    NEW_URL_QUEUE=""
    FW_URL=""
    return 1
  fi
  if ! echo "$RESPONSE" | grep -q '"success":true'; then
    log "camera-sync failed: $RESPONSE"
    camera_sync_save_error "bad_response" "$RESPONSE"
    NEW_URL_QUEUE=""
    FW_URL=""
    return 1
  fi
  SYNC_FAIL_COUNT=0

  touch "$SYNC_OK_FILE"
  # 障害/ロールバック報告がサーバに届いたことが確認できたので、再試行ガードのstateを消す
  [ -n "$REPORT_JSON" ] && rm -rf "$STATE_DIR"

  # 前回成功時の値が残らないよう、レスポンスに無ければ空になる項目は毎回リセットする
  FIRST_UPLOAD_DELAY=""
  SERVER_EPOCH=""
  eval $(echo "$RESPONSE" | awk '{
    gsub(/[{}]/, ""); gsub(/\[/, ""); gsub(/\]/, ""); gsub(/"/, "")
    n = split($0, pairs, ",")
    for(i=1; i<=n; i++) {
      m = split(pairs[i], kv, ":")
      key = kv[m-1]
      val = kv[m]
      if(key == "isEnabled") printf "IS_ENABLED=%s\n", val
      if(key == "checkInterval") printf "CHECK_INTERVAL=%s\n", val
      if(key == "firstUploadDelay") printf "FIRST_UPLOAD_DELAY=%s\n", val
      if(key == "serverEpoch") printf "SERVER_EPOCH=%s\n", val
      if(key == "uptimeStart") printf "UPTIME_START=%s\n", val
      if(key == "uptimeEnd") printf "UPTIME_END=%s\n", val
    }
  }')
  # firstUploadDelay を返さない旧サーバとの互換のため、未取得なら即時アップロード
  # (従来の動作)にフォールバックする
  FIRST_UPLOAD_DELAY="${FIRST_UPLOAD_DELAY:-0}"
  # run_daemon 側で URL_QUEUE への合流方法(上書きか追記か)を判断するため、
  # ここでは直接 URL_QUEUE を書き換えない
  NEW_URL_QUEUE=$(echo "$RESPONSE" | sed 's/.*"uploadUrls":\[//; s/\].*//; s/"//g' | tr ',' '\n')
  log_debug "camera_sync: isEnabled=$IS_ENABLED checkInterval=$CHECK_INTERVAL urlCount=$(echo "$NEW_URL_QUEUE" | grep -c .)"
  parse_firmware_update_offer
  sync_clock_from_server
}

next_upload_url() {
  UPLOAD_URL=$(echo "$URL_QUEUE" | head -1)
  URL_QUEUE=$(echo "$URL_QUEUE" | tail -n +2)
}

capture_and_upload() {
  if [ -z "$UPLOAD_URL" ]; then
    return 1
  fi
  log_debug "capture_and_upload: url=$UPLOAD_URL"

  MSEC=$(current_epoch_ms)
  # $((MSEC / 1000)) は 32bit 算術でオーバーフローするため awk で計算する
  SEC=$(awk "BEGIN{printf \"%d\", $MSEC/1000}")
  MS=$(awk "BEGIN{printf \"%d\", $MSEC%1000}")
  ISO_TIME="$(TZ=UTC date -d @$SEC +"%Y-%m-%dT%H:%M:%S")$(printf ".%03dZ" $MS)"

  TMPDIR=$(mktemp -d)
  /scripts/cmd jpeg 1 | sed '1,3d' > "$TMPDIR/${MSEC}.jpg"  # ch1: サブストリーム 640x360
  if [ ! -s "$TMPDIR/${MSEC}.jpg" ]; then
    log "JPEG capture failed"
    rm -rf "$TMPDIR"
    return 1
  fi
  log_debug "capture_and_upload: jpeg_size=$(wc -c < "$TMPDIR/${MSEC}.jpg") bytes"

  printf '[{"filename":"%s.jpg","capturedAt":"%s"}]' "$MSEC" "$ISO_TIME" > "$TMPDIR/contents.json"
  tar -C "$TMPDIR" -cf "$TMPDIR/tarball.tar" "${MSEC}.jpg" contents.json

  HTTP_CODE=$(curl -X PUT -H 'Content-Type: application/tar' --max-time 30 --silent \
    --output "$TMPDIR/upload_response.txt" --write-out "%{http_code}" \
    "$UPLOAD_URL" --data-binary @"$TMPDIR/tarball.tar")
  CURL_EXIT=$?
  log_debug "capture_and_upload: http_code=$HTTP_CODE curl_exit=$CURL_EXIT"
  if [ $CURL_EXIT -ne 0 ] || [ "$HTTP_CODE" != "200" ]; then
    BODY=$(cat "$TMPDIR/upload_response.txt" 2>/dev/null)
    log "upload failed: curl=$CURL_EXIT HTTP=$HTTP_CODE $BODY"
  fi
  rm -rf "$TMPDIR"
}

KERNEL_IMAGE=/boot/factory_t31_ZMC6tiIDQN
ROOTFS_IMAGE=/media/mmc/rootfs_hack.squashfs

# 失敗を記録して再試行を止める。
# 失敗の扱いは2種類に分かれる（意図的）:
#   - ネットワーク起因(curl失敗): state を書かず次周期に再試行する。一時的な障害とみなす。
#   - それ以外(サイズ不一致/チェックサム不一致/空き容量不足/バックアップ検証失敗):
#     PHASE=failed を書いて再試行を止める。再試行しても同じ結果になるため。
#     failed はサーバへ報告され、予約が reserved から外れてオファーが止まる。
fail_firmware_update() {
  log_fw "firmware update failed ($1): $2"
  if ! write_state "$FW_VERSION" "$FW_CURRENT" failed "$ROLLBACK_TIMEOUT" 0 "$1"; then
    log_fw "could not persist failure state to $STATE_FILE (SD read-only or full)"
  fi
}

file_size_kb() {
  SIZE_BYTES=$(wc -c < "$1" 2>/dev/null)
  case "$SIZE_BYTES" in
    '' | *[!0-9]*) echo 0; return 1 ;;
  esac
  echo $(((SIZE_BYTES + 1023) / 1024))
}

# 更新に必要な空き容量(KB)。以前は 40MB 固定だったが、それはzip単体(約46MB)よりも小さく、
# チェックを通過してから容量不足に陥っていた。実際に同時に置かれるのは:
#   - ダウンロードしたzip (FW_SIZE)
#   - SDへ退避する旧カーネルと旧rootfs
#   - 再起動後、initramfs が zip を展開する分の余裕 (zipと同程度)
required_space_kb() {
  ZIP_KB=$(((FW_SIZE + 1023) / 1024))
  KERNEL_KB=$(file_size_kb "$KERNEL_IMAGE")
  ROOTFS_KB=$(file_size_kb "$ROOTFS_IMAGE")
  # 10% を余裕として乗せる
  echo $(((ZIP_KB * 2 + KERNEL_KB + ROOTFS_KB) * 110 / 100))
}

free_space_kb() {
  # デバイス名が長いと df が2行に折り返すため、マウントポイント行から取り出す
  FREE=$(df /media/mmc 2>/dev/null | awk '$NF=="/media/mmc"{print $(NF-2)}')
  case "$FREE" in
    '' | *[!0-9]*) return 1 ;;
  esac
  echo "$FREE"
}

apply_firmware_update() {
  [ -z "$FW_URL" ] && return 0
  [ -z "$FW_VERSION" ] && return 0
  [ -z "$FW_SIZE" ] && return 0
  [ -z "$FW_SHA" ] && return 0
  [ "$FW_VERSION" = "$FW_CURRENT" ] && return 0
  # state が残っている間は同一バージョンを再ダウンロードしない。
  # サーバは予約が reserved の間、毎回同じオファーを返す（配信保証のための意図的な仕様）ため、
  # このガードで重複ダウンロードを弾く。恒久的な再試行停止はサーバ側が担う。
  [ "$FW_VERSION" = "$TARGET_VERSION" ] && return 0

  # 現在のバージョンが読めない状態で更新すると、再起動後に完了判定もロールバック判定も
  # できなくなり、同じ更新を延々と繰り返す
  if [ -z "$FW_CURRENT" ]; then
    log_fw "firmware update skipped: cannot read current version from $VERSION_FILE"
    return 1
  fi

  # state ファイルに書ける文字だけを受け付ける。想定外の文字を含むバージョンをそのまま
  # 扱うと、state が壊れていると判定されて破棄され、ロールバック監視が無効になる
  case "$FW_VERSION" in
    '' | *[!A-Za-z0-9._-]*)
      fail_firmware_update invalid_version "server offered an unusable version string"
      return 1
      ;;
  esac

  NEED_KB=$(required_space_kb)
  FREE_KB=$(free_space_kb)
  if [ -z "$FREE_KB" ]; then
    fail_firmware_update df_unreadable "cannot determine free space on /media/mmc"
    return 1
  fi
  if [ "$FREE_KB" -lt "$NEED_KB" ]; then
    fail_firmware_update insufficient_space "need ${NEED_KB}KB, have ${FREE_KB}KB"
    return 1
  fi

  mkdir -p "$UPDATE_DIR"
  TMP_ZIP="$UPDATE_DIR/atomcam_tools.zip.tmp"
  rm -f "$TMP_ZIP"
  curl -L --max-time 600 --silent -o "$TMP_ZIP" "$FW_URL"
  CURL_EXIT=$?
  if [ $CURL_EXIT -ne 0 ] || [ ! -f "$TMP_ZIP" ]; then
    # ネットワーク起因の失敗は一時的な可能性があるため state は書かず、次周期に再試行する
    log "firmware download failed: curl error $CURL_EXIT"
    rm -f "$TMP_ZIP"
    return 1
  fi

  ACTUAL_SIZE=$(wc -c < "$TMP_ZIP")
  if [ "$ACTUAL_SIZE" -ne "$FW_SIZE" ] 2>/dev/null; then
    rm -f "$TMP_ZIP"
    fail_firmware_update size_mismatch "expected=$FW_SIZE actual=$ACTUAL_SIZE"
    return 1
  fi

  ACTUAL_SHA=$(sha256sum "$TMP_ZIP" | awk '{print $1}')
  if [ "$ACTUAL_SHA" != "$FW_SHA" ]; then
    rm -f "$TMP_ZIP"
    fail_firmware_update checksum_mismatch "expected=$FW_SHA actual=$ACTUAL_SHA"
    return 1
  fi

  if ! backup_current_firmware; then
    rm -f "$TMP_ZIP"
    return 1
  fi

  # state を書けないまま再起動すると fwrollback.sh が state を見つけられず、
  # ロールバック監視が丸ごと無効になる。書けないなら更新を諦めるほうが安全。
  if ! write_state "$FW_VERSION" "$FW_CURRENT" applied "$ROLLBACK_TIMEOUT" 0 ""; then
    log_fw "firmware update aborted: cannot persist state to $STATE_FILE; refusing to reboot"
    rm -f "$TMP_ZIP"
    return 1
  fi

  mv "$TMP_ZIP" "$UPDATE_DIR/atomcam_tools.zip"
  log_fw "firmware update staged: $FW_CURRENT -> $FW_VERSION, rebooting"
  sync
  reboot
}

# 旧ファームウェアをSDへ退避する。ロールバックはこの退避物だけが頼りなので、
# コピー後に必ず内容を検証する。
backup_current_firmware() {
  if [ ! -f "$ROOTFS_IMAGE" ]; then
    # ext2 rootfs で動作している個体などは squashfs が存在しない。
    # 「バックアップ検証失敗」と区別できるログを出す
    fail_firmware_update no_rootfs_image "$ROOTFS_IMAGE not found on this device"
    return 1
  fi

  mkdir -p "$BACKUP_DIR"
  rm -f "$BACKUP_DIR/factory_t31_ZMC6tiIDQN" "$BACKUP_DIR/rootfs_hack.squashfs"
  cp "$KERNEL_IMAGE" "$BACKUP_DIR/factory_t31_ZMC6tiIDQN"
  cp "$ROOTFS_IMAGE" "$BACKUP_DIR/rootfs_hack.squashfs"
  if ! cmp -s "$KERNEL_IMAGE" "$BACKUP_DIR/factory_t31_ZMC6tiIDQN" \
    || ! cmp -s "$ROOTFS_IMAGE" "$BACKUP_DIR/rootfs_hack.squashfs"; then
    rm -f "$BACKUP_DIR/factory_t31_ZMC6tiIDQN" "$BACKUP_DIR/rootfs_hack.squashfs"
    fail_firmware_update backup_failed "copy of the current firmware did not verify"
    return 1
  fi
  return 0
}

run_daemon() {
  [ -f $MCONFIG ] || exit 0
  load_config
  DEBUG_MODE="${global_debug:-0}"

  if [ -z "$TENANT_KEY" ] || [ -z "$CAMERA_KEY" ]; then
    log "tenantKey or cameraKey not configured"
    exit 1
  fi

  log "mocula started (pid=$$)"
  log_debug "config: origin=$API_ORIGIN tenantKey=$TENANT_KEY cameraKey=$CAMERA_KEY"
  WIFI_MAC=$(cat /sys/class/net/wlan0/address 2>/dev/null)
  [ -n "$WIFI_MAC" ] && echo "$WIFI_MAC" > /media/mmc/mac-addr.txt

  IS_ENABLED=false
  CHECK_INTERVAL=60
  CONFIG_COUNTER=0
  FIRST_UPLOAD_DELAY=0
  UPLOAD_TIMER=0
  URL_QUEUE=""
  UPTIME_START=""
  UPTIME_END=""
  SYNC_FAIL_COUNT=0

  while true; do
    # Sync with server every 60 seconds
    if [ $CONFIG_COUNTER -ge 60 ] || [ $CONFIG_COUNTER -eq 0 ]; then
      log_debug "loop: triggering camera_sync (config_counter=$CONFIG_COUNTER)"
      camera_sync
      CONFIG_COUNTER=0
      if [ -n "$URL_QUEUE" ]; then
        # まだ消化しきっていない分が残っている場合は上書きせず末尾に追加するだけに
        # する。ここで置き換えると、期限がまだ来ていないだけの正当な予約
        # (サーバは既に next_capture_at を前進させて配信済み扱いにしている)が
        # 失われ、二度と再配信されない。UPLOAD_TIMER のカウントダウンも触らない
        # ことで、今まさに期限が来ている撮影が sync の割り込みで消えるのを防ぐ
        # (checkInterval が sync 周期(60秒)の倍数のとき、期限と sync が同じ
        # tick で重なることがあり、旧実装ではこれが原因で2回目以降のアップロード
        # が永久に発生しなくなる不具合があった)。
        [ -n "$NEW_URL_QUEUE" ] && URL_QUEUE="${URL_QUEUE}
${NEW_URL_QUEUE}"
      else
        # サーバが返す firstUploadDelay で再アンカーする。次回撮影予定時刻は
        # サーバの時計だけで管理しているため、このカウンタはカメラの時計に一切
        # 依存しない。sleep 1 と処理時間の分だけ実時間より遅れるが、次に
        # キューが空になったときに上書きされるため誤差は累積しない
        # （→ mocula.md の「アップロードタイミング」参照）。
        UPLOAD_TIMER=$FIRST_UPLOAD_DELAY
        URL_QUEUE=$NEW_URL_QUEUE
      fi
      apply_firmware_update
    fi

    if [ "$IS_ENABLED" = "true" ]; then
      # UPTIME_START と UPTIME_END の両方が設定されている場合、現在時刻(HHMMSS)がその範囲内にあるときのみアップロードする
      # (uptimeStart/uptimeEnd は API のフィールド名。システム稼働時間ではなく時刻(時分秒)を表す)
      if [ -n "$UPTIME_START" ] && [ -n "$UPTIME_END" ]; then
        NOW_HMS_NUM=$(expr $(date +"%H%M%S") + 0)
        if [ $NOW_HMS_NUM -lt $(expr $UPTIME_START + 0) ] || [ $NOW_HMS_NUM -gt $(expr $UPTIME_END + 0) ]; then
          sleep 1
          CONFIG_COUNTER=$((CONFIG_COUNTER + 1))
          UPLOAD_TIMER=$((UPLOAD_TIMER - 1))
          continue
        fi
      fi
      if [ -n "$URL_QUEUE" ] && [ "$UPLOAD_TIMER" -le 0 ]; then
        log_debug "loop: triggering upload (upload_timer=$UPLOAD_TIMER check_interval=$CHECK_INTERVAL)"
        next_upload_url
        capture_and_upload
        # checkInterval <= 60 の場合、1回の sync で複数本の URL が配られる。
        # 2本目以降は checkInterval 秒ごとに均等に消化する。
        UPLOAD_TIMER=$CHECK_INTERVAL
      fi
    fi

    sleep 1
    CONFIG_COUNTER=$((CONFIG_COUNTER + 1))
    UPLOAD_TIMER=$((UPLOAD_TIMER - 1))
  done
}

case "$1" in
  on)
    [ -f $MCONFIG ] || exit 0
    rm -f $DISABLEFILE
    stop_daemon > /dev/null 2>&1
    run_daemon &
    echo $! > $PIDFILE
    /scripts/mocula_live.sh on > /dev/null 2>&1
    ;;
  off)
    touch $DISABLEFILE
    /scripts/mocula_live.sh off > /dev/null 2>&1
    stop_daemon
    log "mocula stopped"
    ;;
  restart)
    rm -f $DISABLEFILE
    stop_daemon
    [ -f $MCONFIG ] || exit 0
    run_daemon &
    echo $! > $PIDFILE
    /scripts/mocula_live.sh restart > /dev/null 2>&1
    ;;
  watchdog)
    [ -f $MCONFIG ] || exit 0
    [ -f $DISABLEFILE ] && exit 0
    /scripts/mocula_live.sh watchdog > /dev/null 2>&1
    if [ -f $PIDFILE ]; then
      PID=$(cat $PIDFILE)
      if kill -0 "$PID" > /dev/null 2>&1; then
        exit 0
      fi
    fi
    log "watchdog: restarting mocula"
    run_daemon &
    echo $! > $PIDFILE
    ;;
  *)
    echo "Usage: $0 {on|off|restart|watchdog}"
    exit 1
    ;;
esac

exit 0
