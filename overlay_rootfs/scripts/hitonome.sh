#!/bin/bash

PIDFILE=/var/run/hitonome.pid
DISABLEFILE=/var/run/hitonome.disabled
LOGFILE=/tmp/log/hitonome.log
MCONFIG=/media/mmc/mconfig

log() {
  echo "$(date +"%Y/%m/%d %H:%M:%S") : $*" >> $LOGFILE
}

stop_daemon() {
  if [ -f $PIDFILE ]; then
    kill $(cat $PIDFILE) > /dev/null 2>&1
    rm -f $PIDFILE
  fi
  # killall は自スクリプトも巻き込むため、自PID($$)を除外して個別に kill する
  for pid in $(ps | awk -v mypid=$$ '/hitonome\.sh/ && $1 != mypid {print $1}'); do
    kill "$pid" > /dev/null 2>&1
  done
}

load_config() {
  eval $(awk -F "=" '
    /^\[/ { section=$0; gsub(/\[/, "", section); gsub(/\]/, "", section); next }
    /^[a-zA-Z]/ { printf "%s_%s=%s\n", section, $1, $2 }
  ' $MCONFIG)

  API_ORIGIN="${dev_apiOrigin:-https://hitonome.cloud}"
  TENANT_KEY="$global_tenantKey"
  CAMERA_KEY="$global_cameraKey"
}

collect_device_info() {
  WIFI_SSID=$(wpa_cli -i wlan0 status 2>/dev/null | grep '^ssid=' | cut -d= -f2)
  WIFI_RSSI=$(awk '/wlan0/ {print int($4)}' /proc/net/wireless 2>/dev/null)
  IP_ADDR=$(ifconfig wlan0 2>/dev/null | grep 'inet addr' | awk '{print $2}' | cut -d: -f2)
  IP_MASK=$(ifconfig wlan0 2>/dev/null | grep 'inet addr' | awk '{print $4}' | cut -d: -f2)
  TIMESTAMP=$(awk '
    FNR==NR && $1=="btime" {b=$2; next}
    FNR==1 {u=$1}
    END {printf "%.0f\n", (b+u)*1000}
  ' /proc/stat /proc/uptime)
}

camera_sync() {
  collect_device_info
  RESPONSE=$(curl --silent --max-time 30 \
    -X POST -H 'Content-Type: application/json' \
    -d "$(printf '{"wifi":{"ssid":"%s","rssi":%s},"ip":{"address":"%s","netmask":"%s"},"timestamp":%s}' \
      "$WIFI_SSID" "${WIFI_RSSI:-0}" "$IP_ADDR" "$IP_MASK" "$TIMESTAMP")" \
    "${API_ORIGIN}/api/v1/camera-sync/${TENANT_KEY}/${CAMERA_KEY}")
  CURL_EXIT=$?
  if [ $CURL_EXIT -ne 0 ]; then
    log "camera-sync failed: curl error $CURL_EXIT"
    URL_QUEUE=""
    return 1
  fi
  if [ -z "$RESPONSE" ]; then
    log "camera-sync failed: empty response"
    URL_QUEUE=""
    return 1
  fi
  if ! echo "$RESPONSE" | grep -q '"success":true'; then
    log "camera-sync failed: $RESPONSE"
    URL_QUEUE=""
    return 1
  fi
  eval $(echo "$RESPONSE" | awk '{
    gsub(/[{}]/, ""); gsub(/\[/, ""); gsub(/\]/, ""); gsub(/"/, "")
    n = split($0, pairs, ",")
    for(i=1; i<=n; i++) {
      m = split(pairs[i], kv, ":")
      key = kv[m-1]
      val = kv[m]
      if(key == "isEnabled") printf "IS_ENABLED=%s\n", val
      if(key == "checkInterval") printf "CHECK_INTERVAL=%s\n", val
    }
  }')
  URL_QUEUE=$(echo "$RESPONSE" | sed 's/.*"uploadUrls":\[//; s/\].*//; s/"//g' | tr ',' '\n')
}

next_upload_url() {
  UPLOAD_URL=$(echo "$URL_QUEUE" | head -1)
  URL_QUEUE=$(echo "$URL_QUEUE" | tail -n +2)
}

capture_and_upload() {
  if [ -z "$UPLOAD_URL" ]; then
    return 1
  fi

  MSEC=$(awk '
    FNR==NR && $1=="btime" {b=$2; next}
    FNR==1 {u=$1}
    END {printf "%.0f\n", (b+u)*1000}
  ' /proc/stat /proc/uptime)
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

  printf '[{"filename":"%s.jpg","capturedAt":"%s"}]' "$MSEC" "$ISO_TIME" > "$TMPDIR/contents.json"
  tar -C "$TMPDIR" -cf "$TMPDIR/tarball.tar" "${MSEC}.jpg" contents.json

  HTTP_CODE=$(curl -X PUT -H 'Content-Type: application/tar' --max-time 30 --silent \
    --output "$TMPDIR/upload_response.txt" --write-out "%{http_code}" \
    "$UPLOAD_URL" --data-binary @"$TMPDIR/tarball.tar")
  CURL_EXIT=$?
  if [ $CURL_EXIT -ne 0 ] || [ "$HTTP_CODE" != "200" ]; then
    BODY=$(cat "$TMPDIR/upload_response.txt" 2>/dev/null)
    log "upload failed: curl=$CURL_EXIT HTTP=$HTTP_CODE $BODY"
  fi
  rm -rf "$TMPDIR"
}

run_daemon() {
  [ -f $MCONFIG ] || exit 0
  load_config

  if [ -z "$TENANT_KEY" ] || [ -z "$CAMERA_KEY" ]; then
    log "tenantKey or cameraKey not configured"
    exit 1
  fi

  log "hitonome started (pid=$$)"

  IS_ENABLED=false
  CHECK_INTERVAL=60
  CONFIG_COUNTER=0
  UPLOAD_COUNTER=0
  URL_QUEUE=""

  while true; do
    # Sync with server every 60 seconds
    if [ $CONFIG_COUNTER -ge 60 ] || [ $CONFIG_COUNTER -eq 0 ]; then
      camera_sync
      CONFIG_COUNTER=0
      UPLOAD_COUNTER=0
    fi

    if [ "$IS_ENABLED" = "true" ]; then
      # TODO: pre-signed URL の有効期限は 60 秒。CHECK_INTERVAL や URL 数の組み合わせ次第では
      #       camera_sync 取得後のアップロードが期限切れになるリスクがある。
      if [ $((UPLOAD_COUNTER % CHECK_INTERVAL)) -eq 0 ] && [ -n "$URL_QUEUE" ]; then
        next_upload_url
        capture_and_upload
      fi
    fi

    sleep 1
    CONFIG_COUNTER=$((CONFIG_COUNTER + 1))
    UPLOAD_COUNTER=$((UPLOAD_COUNTER + 1))
  done
}

case "$1" in
  on)
    [ -f $MCONFIG ] || exit 0
    rm -f $DISABLEFILE
    stop_daemon > /dev/null 2>&1
    run_daemon &
    echo $! > $PIDFILE
    ;;
  off)
    touch $DISABLEFILE
    stop_daemon
    log "hitonome stopped"
    ;;
  restart)
    rm -f $DISABLEFILE
    stop_daemon
    [ -f $MCONFIG ] || exit 0
    run_daemon &
    echo $! > $PIDFILE
    ;;
  watchdog)
    [ -f $MCONFIG ] || exit 0
    [ -f $DISABLEFILE ] && exit 0
    if [ -f $PIDFILE ]; then
      PID=$(cat $PIDFILE)
      if kill -0 "$PID" > /dev/null 2>&1; then
        exit 0
      fi
    fi
    log "watchdog: restarting hitonome"
    run_daemon &
    echo $! > $PIDFILE
    ;;
  *)
    echo "Usage: $0 {on|off|restart|watchdog}"
    exit 1
    ;;
esac

exit 0
