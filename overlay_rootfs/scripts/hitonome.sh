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
  killall hitonome.sh > /dev/null 2>&1
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

fetch_camera_configs() {
  RESPONSE=$(curl --silent --max-time 30 \
    "${API_ORIGIN}/api/v1/camera-configs/${TENANT_KEY}/${CAMERA_KEY}")
  if [ $? -ne 0 ] || [ -z "$RESPONSE" ]; then
    log "camera-configs fetch failed"
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
}

fetch_upload_urls() {
  RESPONSE=$(curl --silent --max-time 30 \
    "${API_ORIGIN}/api/v1/upload-urls/${TENANT_KEY}/${CAMERA_KEY}")
  if [ $? -ne 0 ] || [ -z "$RESPONSE" ]; then
    log "upload-urls fetch failed"
    URL_QUEUE=""
    return 1
  fi
  URL_QUEUE=$(echo "$RESPONSE" | sed 's/.*\[//; s/\].*//; s/"//g' | tr ',' '\n')
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
  SEC=$((MSEC / 1000))
  MS=$((MSEC % 1000))
  ISO_TIME="$(TZ=UTC date -d @$SEC +"%Y-%m-%dT%H:%M:%S")$(printf ".%03dZ" $MS)"

  TMPDIR=$(mktemp -d)
  /scripts/cmd jpeg | sed '1,3d' > "$TMPDIR/${MSEC}.jpg"
  if [ ! -s "$TMPDIR/${MSEC}.jpg" ]; then
    log "JPEG capture failed"
    rm -rf "$TMPDIR"
    return 1
  fi

  printf '[{"filename":"%s.jpg","capturedAt":"%s"}]' "$MSEC" "$ISO_TIME" > "$TMPDIR/contents.json"
  tar -C "$TMPDIR" -cf "$TMPDIR/tarball.tar" "${MSEC}.jpg" contents.json

  curl -X PUT -H 'Content-Type: application/tar' --max-time 30 --silent \
    "$UPLOAD_URL" --data-binary @"$TMPDIR/tarball.tar"
  if [ $? -ne 0 ]; then
    log "upload failed: $UPLOAD_URL"
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
    # Fetch camera-configs every 60 seconds
    if [ $CONFIG_COUNTER -ge 60 ] || [ $CONFIG_COUNTER -eq 0 ]; then
      fetch_camera_configs
      CONFIG_COUNTER=0
    fi

    if [ "$IS_ENABLED" = "true" ]; then
      if [ "$CHECK_INTERVAL" -le 60 ] 2>/dev/null; then
        # Fast mode: fetch URLs every 60s, upload every checkInterval
        if [ $UPLOAD_COUNTER -ge 60 ] || [ -z "$URL_QUEUE" -a $UPLOAD_COUNTER -eq 0 ]; then
          fetch_upload_urls
          [ $UPLOAD_COUNTER -ge 60 ] && UPLOAD_COUNTER=0
        fi
        if [ $((UPLOAD_COUNTER % CHECK_INTERVAL)) -eq 0 ] && [ -n "$URL_QUEUE" ]; then
          next_upload_url
          capture_and_upload
        fi
      else
        # Slow mode: fetch URL and upload together every checkInterval
        if [ $UPLOAD_COUNTER -ge "$CHECK_INTERVAL" ] || [ $UPLOAD_COUNTER -eq 0 ]; then
          fetch_upload_urls
          if [ -n "$URL_QUEUE" ]; then
            next_upload_url
            capture_and_upload
          fi
          UPLOAD_COUNTER=0
        fi
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
