#!/bin/sh

# ライブビュー セッションランナー(オンデマンド)。
# 常時ロングポーリングは廃止。mocula.sh の camera-sync が liveAction=offer を
# 受け取ると `mocula_live.sh start <sessionId>` をオンデマンド起動し、この
# プロセスが 1 セッションの生存期間だけ存在してストリームを張り、終わったら exit する。

PIDFILE=/var/run/mocula-live.pid       # = セッション実行中ロック
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
  LIVE_IMAGE_MAX="${live_imageMax:-600}"
  LIVE_SESSION_POLL="${live_sessionPoll:-10}"
  LIVE_SESSION_MAX="${live_sessionMax:-600}"
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
  if [ -f "$STACK_MARKER" ]; then
    # マーカーが残っていても異常終了の残骸の可能性があるため、go2rtc の応答を実際に確認する
    curl -s -o /dev/null -m 2 "http://127.0.0.1:1984/api" 2>/dev/null && return 0
    log "stack_start: stale stack marker detected, cleaning up"
    _stack_stop_internal
  fi

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

# offer SDP を単発 GET で取得する(camera-sync には SDP を載せない)
fetch_offer() {
  local session_id="$1"
  local http_code
  rm -f "$OFFER_FILE"
  http_code=$(curl -s -m 15 -X GET \
    -o "$OFFER_FILE" \
    -w '%{http_code}' \
    "$API_ORIGIN/api/v1/live-signal/$TENANT_KEY/$CAMERA_KEY/offer?session=${session_id}" 2>/dev/null)
  log_debug "fetch_offer: http=$http_code size=$(wc -c < "$OFFER_FILE" 2>/dev/null)"
  [ "$http_code" = "200" ] && [ -s "$OFFER_FILE" ]
}

# TODO(確認待ち): 確定プロトコルにカメラ→backend の answer 提出/エラー報告経路が
# 明示されていない。既存の POST /answer?session=id(application/sdp, ?error=busy|stack_failed)
# が据え置きである前提で実装している。オーケストレーターの確認後に確定させる。
report_answer_error() {
  curl -s -m 15 -X POST \
    "$API_ORIGIN/api/v1/live-signal/$TENANT_KEY/$CAMERA_KEY/answer?session=${1}&error=${2}" \
    > /dev/null 2>&1
}

# OFFER_FILE の offer を go2rtc に渡して answer を得て backend に提出する
handle_offer() {
  local session_id="$1"
  local http_code
  log_debug "handle_offer: session=$session_id"

  if ! stack_start; then
    log "handle_offer: stack_start failed, reporting busy"
    report_answer_error "$session_id" busy
    return 1
  fi

  # go2rtc が ICE candidates を収集し終えるまでブロック(non-trickle)。
  # 旧仕様の 28 秒デッドラインは撤廃されたため、固定の妥当なタイムアウトにする。
  http_code=$(curl -s -m 25 -X POST \
    -H 'Content-Type: application/sdp' \
    --data-binary @"$OFFER_FILE" \
    -o "$ANSWER_FILE" \
    -w '%{http_code}' \
    "http://127.0.0.1:1984/api/webrtc?src=video0" 2>/dev/null)
  log_debug "handle_offer: go2rtc exchange http=$http_code"

  if [ "$http_code" != "201" ] || [ ! -s "$ANSWER_FILE" ]; then
    log "handle_offer: go2rtc exchange failed http=$http_code"
    report_answer_error "$session_id" stack_failed
    stack_stop
    return 1
  fi

  # answer を backend に提出(TODO 確認待ちのエンドポイント、上記参照)
  http_code=$(curl -s -m 15 -X POST \
    -H 'Content-Type: application/sdp' \
    --data-binary @"$ANSWER_FILE" \
    -o /dev/null \
    -w '%{http_code}' \
    "$API_ORIGIN/api/v1/live-signal/$TENANT_KEY/$CAMERA_KEY/answer?session=${session_id}" 2>/dev/null)

  case "$http_code" in
    2*)
      log_debug "handle_offer: answer sent http=$http_code"
      return 0
      ;;
    *)
      # answer がバックエンドに届いていないため streaming にはせず、スタックを畳んで失敗を返す
      log "handle_offer: answer delivery failed http=$http_code"
      stack_stop
      return 1
      ;;
  esac
}

# セッション中の双方向通信: state/consumers を報告し、action(continue|stop|image)を受ける
session_status() {
  local session_id="$1"
  local state="$2"
  local consumers="$3"
  local http_code
  STATUS_ACTION=""
  rm -f "$CURL_HDRS"
  http_code=$(curl -s -m 15 -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"state\":\"${state}\",\"consumers\":${consumers}}" \
    -D "$CURL_HDRS" \
    -o /dev/null \
    -w '%{http_code}' \
    "$API_ORIGIN/api/v1/live-signal/$TENANT_KEY/$CAMERA_KEY/status?session=${session_id}" 2>/dev/null)
  case "$http_code" in
    2*)
      STATUS_ACTION=$(grep -i '^x-mocula-action:' "$CURL_HDRS" 2>/dev/null | awk -F': ' '{ gsub(/\r/, "", $2); print $2 }')
      ;;
    404|410)
      # backend がセッションを消失させている(TTL失効等の真の異常系)。
      # curl 自体の失敗(000 等、応答なし)とは区別し、一過性エラーとしてリトライしない。
      # 本来 backend は CLOSED 時に 204+stop を返す設計だが、その保険として
      # 最終防衛線でスタックを畳んで正常終了させる。
      log "session_status: backend session not found (http=$http_code), treating as implicit stop"
      STATUS_ACTION="gone"
      ;;
    *)
      log_debug "session_status: http=$http_code"
      ;;
  esac
}

image_mode() {
  local session_id="$1"
  local elapsed=0
  local fail_count=0
  local post_fail=0
  local frame_file="/tmp/mocula-live-frame.jpg"
  local action http_code

  log "image_mode: starting session=$session_id"

  while [ $elapsed -lt "$LIVE_IMAGE_MAX" ]; do
    /scripts/cmd jpeg 1 | sed '1,3d' > "$frame_file"
    # JPEG マジックバイト(ff d8)を確認し、cmd のエラー出力等をフレームとして送らない
    # (BusyBox od は -A/-t/-N 非対応のため od -b を使う)
    if [ ! -s "$frame_file" ] || \
       [ "$(head -c 2 "$frame_file" | od -b | awk 'NR==1{print $2 $3}')" != "377330" ]; then
      fail_count=$((fail_count + 1))
      log_debug "image_mode: capture failed count=$fail_count"
      if [ $fail_count -ge 5 ]; then
        log "image_mode: JPEG capture failed ${fail_count} times, aborting"
        break
      fi
      sleep 5
      elapsed=$((elapsed + 5))
      continue
    fi
    fail_count=0

    rm -f "$CURL_HDRS"
    http_code=$(curl -s -m 15 -X POST \
      -H 'Content-Type: image/jpeg' \
      --data-binary @"$frame_file" \
      -D "$CURL_HDRS" \
      -o /dev/null \
      -w '%{http_code}' \
      "$API_ORIGIN/api/v1/live-frame/$TENANT_KEY/$CAMERA_KEY?session=${session_id}" 2>/dev/null)

    case "$http_code" in
      2*)
        post_fail=0
        ;;
      *)
        # セッションがサーバ側で消えている(404 等)のに送り続けるのを防ぐ
        post_fail=$((post_fail + 1))
        log "image_mode: frame post failed http=$http_code count=$post_fail"
        if [ $post_fail -ge 5 ]; then
          log "image_mode: frame post failed ${post_fail} times, aborting"
          break
        fi
        ;;
    esac

    action=$(grep -i '^x-mocula-action:' "$CURL_HDRS" 2>/dev/null | awk -F': ' '{ gsub(/\r/, "", $2); print $2 }')
    log_debug "image_mode: posted action=${action:-continue}"
    [ "$action" = "stop" ] && break

    sleep 5
    elapsed=$((elapsed + 5))
  done

  rm -f "$frame_file"
  log "image_mode: ended elapsed=${elapsed}s"
}

# 1 セッションを最初から最後まで実行する
run_session() {
  local session_id="$1"
  local idle_sec=0
  local session_sec=0
  local consumers

  log "session start id=$session_id"
  log_debug "config: origin=$API_ORIGIN tenant=$TENANT_KEY camera=$CAMERA_KEY sessionPoll=$LIVE_SESSION_POLL"

  # 前回異常終了(SIGKILL 等)で残った自前スタックを清算してから始める
  [ -f "$STACK_MARKER" ] && _stack_stop_internal

  if ! fetch_offer "$session_id"; then
    log "session: offer fetch failed id=$session_id"
    return 1
  fi

  if ! handle_offer "$session_id"; then
    return 1
  fi

  # セッション中ループ: state/consumers を報告し stop/image を処理する
  while true; do
    # go2rtc / v4l2rtspserver のクラッシュ検知
    if [ -f "$STACK_MARKER" ] && \
       { ! pidof go2rtc > /dev/null 2>&1 || ! pidof v4l2rtspserver > /dev/null 2>&1; }; then
      log "session: stack died unexpectedly"
      break
    fi

    if has_consumers; then
      idle_sec=0
      consumers=1
    else
      idle_sec=$((idle_sec + LIVE_SESSION_POLL))
      consumers=0
      if [ $idle_sec -ge "$LIVE_IDLE_TIMEOUT" ]; then
        log "session: idle timeout (no consumers)"
        break
      fi
    fi

    session_status "$session_id" "streaming" "$consumers"
    case "$STATUS_ACTION" in
      stop)
        log "session: stop received"
        break
        ;;
      gone)
        # session_status 内で詳細ログ済み。ここでは正常終了としてループを抜けるのみ
        break
        ;;
      image)
        log "session: image fallback requested"
        image_mode "$session_id"
        break
        ;;
    esac

    session_sec=$((session_sec + LIVE_SESSION_POLL))
    if [ $session_sec -ge "$LIVE_SESSION_MAX" ]; then
      log "session: max duration reached"
      break
    fi
    sleep "$LIVE_SESSION_POLL"
  done

  stack_stop
  log "session end id=$session_id"
}

# 実行中セッションを停止する(ロック保持プロセスを kill)
kill_session() {
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" > /dev/null 2>&1
    rm -f "$PIDFILE"
  fi
}

case "$1" in
  start)
    [ -f /media/mmc/mconfig ] || exit 0
    load_config || exit 0
    [ "$LIVE_DISABLED" = "1" ] && exit 0
    [ -f "$DISABLEFILE" ] && exit 0
    [ -z "$TENANT_KEY" ] || [ -z "$CAMERA_KEY" ] && { log "start: tenantKey/cameraKey not set"; exit 1; }
    session_id="$2"
    [ -z "$session_id" ] && { log "start: no session id"; exit 1; }

    # 多重起動防止(ロック): 既にセッション実行中なら何もしない
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" > /dev/null 2>&1; then
      log "start: session already running, ignoring id=$session_id"
      exit 0
    fi
    echo $$ > "$PIDFILE"
    trap 'stack_stop; rm -f "$PIDFILE"; exit 0' EXIT INT TERM
    run_session "$session_id"
    ;;
  off)
    touch "$DISABLEFILE"
    load_config 2>/dev/null
    kill_session
    stack_stop
    log "mocula-live stopped"
    ;;
  on)
    # 常駐は無くオンデマンド起動なので、disable 解除のみ行う
    rm -f "$DISABLEFILE"
    ;;
  restart)
    # 実行中セッションを停止する(次の camera-sync トリガで再開される)
    rm -f "$DISABLEFILE"
    load_config 2>/dev/null
    kill_session
    stack_stop
    ;;
  watchdog)
    # 常駐維持は不要。セッション未実行なのに自前スタックが残っていたら清算する
    [ -f /media/mmc/mconfig ] || exit 0
    load_config 2>/dev/null
    if [ ! -f "$PIDFILE" ] || ! kill -0 "$(cat "$PIDFILE" 2>/dev/null)" > /dev/null 2>&1; then
      rm -f "$PIDFILE"
      [ -f "$STACK_MARKER" ] && { log "watchdog: cleaning orphan stack"; _stack_stop_internal; }
    fi
    ;;
  *)
    echo "Usage: $0 {start <sessionId>|on|off|restart|watchdog}"
    exit 1
    ;;
esac

exit 0
