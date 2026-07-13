#!/bin/sh

PIDFILE=/var/run/mocula-live.pid
DISABLEFILE=/var/run/mocula-live.disabled
LOGFILE=/tmp/log/mocula-live.log
STACK_MARKER=/var/run/mocula-live.stack
GO2RTC_CONFIG=/tmp/go2rtc-mocula.yaml
OFFER_FILE=/tmp/mocula-live-offer.sdp
ANSWER_FILE=/tmp/mocula-live-answer.sdp
CURL_HDRS=/tmp/mocula-live-headers.txt

log() {
  echo "$(date +"%Y/%m/%d %H:%M:%S") : $*" >> "$LOGFILE"
}

log_debug() {
  [ "$DEBUG_MODE" = "1" ] || return 0
  echo "$(date +"%Y/%m/%d %H:%M:%S") : [DEBUG] $*" >> "$LOGFILE"
}

load_config() {
  [ -f /media/mmc/mconfig ] || return 1
  eval $(awk -F "=" '
    /^\[/ { section=$0; gsub(/\[/, "", section); gsub(/\]/, "", section); next }
    /^[a-zA-Z]/ { printf "%s_%s=%s\n", section, $1, $2 }
  ' /media/mmc/mconfig)
  API_ORIGIN="${global_origin:-https://app.mocula.jp}"
  TENANT_KEY="$global_tenantKey"
  CAMERA_KEY="$global_cameraKey"
  DEBUG_MODE="${global_debug:-0}"
  LIVE_DISABLED="${live_disabled:-0}"
  LIVE_IDLE_TIMEOUT="${live_idleTimeout:-120}"
  LIVE_POLL_TIMEOUT="${live_pollTimeout:-55}"
  LIVE_IMAGE_MAX="${live_imageMax:-600}"
}

stop_daemon() {
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" > /dev/null 2>&1
    rm -f "$PIDFILE"
  fi
}

# returns 0 (true) if a go2rtc/v4l2rtspserver not started by us is running
foreign_stack_running() {
  [ -f "$STACK_MARKER" ] && return 1
  pidof go2rtc > /dev/null 2>&1 || pidof v4l2rtspserver > /dev/null 2>&1
}

stack_start() {
  if foreign_stack_running; then
    log "stack_start: foreign stack detected, refusing"
    return 1
  fi
  [ -f "$STACK_MARKER" ] && return 0

  log "stack_start: enabling video encoder ch0"
  /scripts/cmd video 0 on > /dev/null 2>&1

  # Wait for port 8554 to be free
  local i=0
  while netstat -ltn 2>/dev/null | grep -q ':8554 ' && [ $i -lt 10 ]; do
    sleep 0.5
    i=$((i + 1))
  done

  log "stack_start: starting v4l2rtspserver"
  # URL = {device_basename}_{default_unicast} = video0_unicast (no -u flag needed)
  /usr/bin/v4l2rtspserver /dev/video0 >> /tmp/log/mocula-live.log 2>&1 &

  i=0
  while ! pidof v4l2rtspserver > /dev/null 2>&1 && [ $i -lt 20 ]; do
    sleep 0.5
    i=$((i + 1))
  done
  if ! pidof v4l2rtspserver > /dev/null 2>&1; then
    log "stack_start: v4l2rtspserver failed to start"
    /scripts/cmd video 0 off > /dev/null 2>&1
    return 1
  fi

  cat > "$GO2RTC_CONFIG" << 'YAML'
log:
    streams: error
api:
    listen: "127.0.0.1:1984"
rtsp:
    listen: ''
webrtc:
    listen: ":8555"
    candidates:
        - stun:8555
    ice_servers:
        - urls: [ "stun:stun.l.google.com:19302" ]
streams:
    video0:
        - rtsp://localhost:8554/video0_unicast
YAML

  log "stack_start: starting go2rtc"
  /usr/bin/go2rtc -config "$GO2RTC_CONFIG" >> /tmp/log/go2rtc-mocula.log 2>&1 &

  i=0
  while [ $i -lt 20 ]; do
    curl -s -o /dev/null -m 2 "http://127.0.0.1:1984/api" 2>/dev/null && break
    sleep 0.5
    i=$((i + 1))
  done
  if ! curl -s -o /dev/null -m 2 "http://127.0.0.1:1984/api" 2>/dev/null; then
    log "stack_start: go2rtc API not ready"
    _stack_stop_internal
    return 1
  fi

  touch "$STACK_MARKER"
  log "stack_start: ready"
  return 0
}

_stack_stop_internal() {
  /scripts/cmd video 0 off > /dev/null 2>&1
  local i=0
  while pidof go2rtc > /dev/null 2>&1 && [ $i -lt 10 ]; do
    killall go2rtc > /dev/null 2>&1
    sleep 0.5
    i=$((i + 1))
  done
  i=0
  while pidof v4l2rtspserver > /dev/null 2>&1 && [ $i -lt 10 ]; do
    killall v4l2rtspserver > /dev/null 2>&1
    sleep 0.5
    i=$((i + 1))
  done
  rm -f "$STACK_MARKER" "$GO2RTC_CONFIG"
}

stack_stop() {
  [ -f "$STACK_MARKER" ] || return 0
  log "stack_stop: stopping"
  _stack_stop_internal
  log "stack_stop: done"
}

has_consumers() {
  # Non-empty consumers array: "consumers":[{...}]
  curl -s -m 5 "http://127.0.0.1:1984/api/streams" 2>/dev/null | grep -q '"consumers":\[{'
}

poll_backend() {
  local state="$1"
  local consumers="$2"
  local timeout="$LIVE_POLL_TIMEOUT"
  [ "$state" = "streaming" ] && timeout=10

  ACTION=""
  SESSION_ID=""
  rm -f "$CURL_HDRS" "$OFFER_FILE"

  local http_code
  http_code=$(curl -s -m $((timeout + 5)) -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"state\":\"${state}\",\"consumers\":${consumers}}" \
    -D "$CURL_HDRS" \
    -o "$OFFER_FILE" \
    -w '%{http_code}' \
    "$API_ORIGIN/api/v1/live-signal/$TENANT_KEY/$CAMERA_KEY/poll" 2>/dev/null)

  log_debug "poll_backend: state=$state http=$http_code"

  case "$http_code" in
    200)
      ACTION=$(grep -i '^x-mocula-action:' "$CURL_HDRS" 2>/dev/null | awk -F': ' '{ gsub(/\r/, "", $2); print $2 }')
      SESSION_ID=$(grep -i '^x-mocula-session:' "$CURL_HDRS" 2>/dev/null | awk -F': ' '{ gsub(/\r/, "", $2); print $2 }')
      return 0
      ;;
    204)
      return 0
      ;;
    *)
      log_debug "poll_backend: error http=$http_code"
      return 1
      ;;
  esac
}

handle_offer() {
  local session_id="$1"
  log_debug "handle_offer: session=$session_id"

  if ! stack_start; then
    log "handle_offer: stack_start failed, reporting busy"
    curl -s -m 15 -X POST \
      "$API_ORIGIN/api/v1/live-signal/$TENANT_KEY/$CAMERA_KEY/answer?session=${session_id}&error=busy" \
      > /dev/null 2>&1
    return 1
  fi

  # Blocks until go2rtc gathers ICE candidates (non-trickle), up to 25s
  local http_code
  http_code=$(curl -s -m 25 -X POST \
    -H 'Content-Type: application/sdp' \
    --data-binary @"$OFFER_FILE" \
    -o "$ANSWER_FILE" \
    -w '%{http_code}' \
    "http://127.0.0.1:1984/api/webrtc?src=video0" 2>/dev/null)

  log_debug "handle_offer: go2rtc exchange http=$http_code"

  if [ "$http_code" != "201" ] || [ ! -s "$ANSWER_FILE" ]; then
    log "handle_offer: go2rtc exchange failed http=$http_code"
    curl -s -m 15 -X POST \
      "$API_ORIGIN/api/v1/live-signal/$TENANT_KEY/$CAMERA_KEY/answer?session=${session_id}&error=stack_failed" \
      > /dev/null 2>&1
    return 1
  fi

  http_code=$(curl -s -m 15 -X POST \
    -H 'Content-Type: application/sdp' \
    --data-binary @"$ANSWER_FILE" \
    -o /dev/null \
    -w '%{http_code}' \
    "$API_ORIGIN/api/v1/live-signal/$TENANT_KEY/$CAMERA_KEY/answer?session=${session_id}" 2>/dev/null)

  log_debug "handle_offer: answer sent http=$http_code"
  return 0
}

image_mode() {
  local session_id="$1"
  local elapsed=0
  local fail_count=0
  local frame_file="/tmp/mocula-live-frame.jpg"
  local action

  log "image_mode: starting session=$session_id"

  while [ $elapsed -lt "$LIVE_IMAGE_MAX" ]; do
    /scripts/cmd jpeg 1 | sed '1,3d' > "$frame_file"
    if [ ! -s "$frame_file" ]; then
      fail_count=$((fail_count + 1))
      log_debug "image_mode: capture failed count=$fail_count"
      [ $fail_count -ge 5 ] && break
      sleep 5
      elapsed=$((elapsed + 5))
      continue
    fi
    fail_count=0

    rm -f "$CURL_HDRS"
    curl -s -m 15 -X POST \
      -H 'Content-Type: image/jpeg' \
      --data-binary @"$frame_file" \
      -D "$CURL_HDRS" \
      -o /dev/null \
      "$API_ORIGIN/api/v1/live-frame/$TENANT_KEY/$CAMERA_KEY?session=${session_id}" 2>/dev/null

    action=$(grep -i '^x-mocula-action:' "$CURL_HDRS" 2>/dev/null | awk -F': ' '{ gsub(/\r/, "", $2); print $2 }')
    log_debug "image_mode: posted action=${action:-continue}"
    [ "$action" = "stop" ] && break

    sleep 5
    elapsed=$((elapsed + 5))
  done

  rm -f "$frame_file"
  log "image_mode: ended elapsed=${elapsed}s"
}

run_daemon() {
  load_config || exit 0
  [ -z "$TENANT_KEY" ] || [ -z "$CAMERA_KEY" ] && { log "tenantKey/cameraKey not set"; exit 1; }
  [ "$LIVE_DISABLED" = "1" ] && exit 0

  log "mocula-live started pid=$$"
  log_debug "config: origin=$API_ORIGIN tenant=$TENANT_KEY camera=$CAMERA_KEY"

  trap 'stack_stop; exit 0' EXIT INT TERM

  local streaming=0
  local idle_sec=0
  local poll_fail=0
  local consumers=0
  local state

  while true; do
    state="idle"
    consumers=0

    # Detect unexpected go2rtc crash
    if [ "$streaming" = "1" ] && [ -f "$STACK_MARKER" ] && ! pidof go2rtc > /dev/null 2>&1; then
      log "go2rtc died unexpectedly, resetting"
      _stack_stop_internal
      streaming=0
      idle_sec=0
    fi

    if [ "$streaming" = "1" ]; then
      state="streaming"
      if has_consumers; then
        idle_sec=0
        consumers=1
      else
        idle_sec=$((idle_sec + 10))
        if [ $idle_sec -ge "$LIVE_IDLE_TIMEOUT" ]; then
          log "idle timeout, stopping stack"
          stack_stop
          streaming=0
          idle_sec=0
          state="idle"
        fi
      fi
    fi

    if poll_backend "$state" "$consumers"; then
      poll_fail=0
      case "$ACTION" in
        offer)
          log "offer received session=$SESSION_ID"
          handle_offer "$SESSION_ID" && streaming=1
          ;;
        image)
          log "image mode requested session=$SESSION_ID"
          image_mode "$SESSION_ID"
          ;;
        stop)
          log "stop received"
          stack_stop
          streaming=0
          idle_sec=0
          ;;
        ""|*)
          ;;
      esac
    else
      poll_fail=$((poll_fail + 1))
      local backoff=5
      [ $poll_fail -ge 6 ] && backoff=30
      [ $poll_fail -ge 12 ] && backoff=60
      log_debug "poll failed ${poll_fail} times, backoff=${backoff}s"
      sleep $backoff
    fi
  done
}

case "$1" in
  on)
    [ -f /media/mmc/mconfig ] || exit 0
    rm -f "$DISABLEFILE"
    stop_daemon
    run_daemon &
    echo $! > "$PIDFILE"
    ;;
  off)
    touch "$DISABLEFILE"
    stop_daemon
    log "mocula-live stopped"
    ;;
  restart)
    rm -f "$DISABLEFILE"
    stop_daemon
    [ -f /media/mmc/mconfig ] || exit 0
    run_daemon &
    echo $! > "$PIDFILE"
    ;;
  watchdog)
    [ -f /media/mmc/mconfig ] || exit 0
    [ -f "$DISABLEFILE" ] && exit 0
    if [ -f "$PIDFILE" ]; then
      PID=$(cat "$PIDFILE")
      if kill -0 "$PID" > /dev/null 2>&1; then
        exit 0
      fi
    fi
    log "watchdog: restarting mocula-live"
    run_daemon &
    echo $! > "$PIDFILE"
    ;;
  *)
    echo "Usage: $0 {on|off|restart|watchdog}"
    exit 1
    ;;
esac

exit 0
