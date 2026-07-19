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

# live_sessionMax (mconfig) 未設定時の既定値。配信開始(session start)からの合計経過秒数の上限。
# WebRTC P2P・画像フォールバックいずれのモードで過ごした時間も合算してこの値に達すると
# 自動切断する(再接続には新規セッション作成が必要)。後で変更する場合はここだけ変える。
DEFAULT_LIVE_SESSION_MAX=600

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
  LIVE_SESSION_POLL="${live_sessionPoll:-10}"
  LIVE_SESSION_MAX="${live_sessionMax:-$DEFAULT_LIVE_SESSION_MAX}"
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
    # マーカーが残っていても異常終了の残骸の可能性があるため、go2rtc の応答を実際に確認する。
    # http_code を明示比較し、4xx/5xx (エラー応答はあるがプロセスは死んでいない状態) を
    # 「生きている」と誤判定しないようにする。curl 自体の接続失敗(タイムアウト等)は http_code が
    # 空/000 になるため、HTTPエラー応答と区別してログに残せる。
    local stale_check_http_code
    stale_check_http_code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:1984/api" 2>/dev/null)
    [ "$stale_check_http_code" = "200" ] && return 0
    log "stack_start: stale stack marker detected (http=${stale_check_http_code:-000}), cleaning up"
    _stack_stop_internal
  fi

  log "stack_start: enabling video encoder ch0"
  # on の失敗は stack_start 自体を中断させる致命的な失敗なので log (常時記録)。
  # off はここより下の複数のクリーンアップ経路(失敗時・正常終了時)から呼ばれるベストエフォートの
  # 後片付けであり、それ自体の失敗で処理を止める意味がないため log_debug に留めている。
  if ! /scripts/cmd video 0 on > /dev/null 2>&1; then
    log "stack_start: cmd video 0 on failed"
    return 1
  fi

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
    /scripts/cmd video 0 off > /dev/null 2>&1 || log_debug "stack_start: cmd video 0 off failed (cleanup)"
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

  # http_code を明示比較し、4xx/5xx (プロセスは起きているがAPIがエラーを返している状態) を
  # 「準備完了」と誤判定しないようにする。curl 自体の接続失敗とHTTPエラー応答をログで区別できる。
  local go2rtc_http_code
  i=0
  while [ $i -lt 20 ]; do
    go2rtc_http_code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:1984/api" 2>/dev/null)
    [ "$go2rtc_http_code" = "200" ] && break
    sleep 0.5
    i=$((i + 1))
  done
  if [ "$go2rtc_http_code" != "200" ]; then
    log "stack_start: go2rtc API not ready (http=${go2rtc_http_code:-000})"
    _stack_stop_internal
    return 1
  fi

  touch "$STACK_MARKER"
  log "stack_start: ready"
  return 0
}

_stack_stop_internal() {
  /scripts/cmd video 0 off > /dev/null 2>&1 || log_debug "_stack_stop_internal: cmd video 0 off failed"
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
  # kill 試行後も生き残っていれば、その旨を記録する。ここで無言のまま STACK_MARKER を
  # 消すと、次回 stack_start 時に foreign_stack_running が「見知らぬプロセスがいる」と
  # 誤誘導するログを出す(実際の原因はここでの停止漏れなのに気づけなくなる)。
  if pidof go2rtc > /dev/null 2>&1 || pidof v4l2rtspserver > /dev/null 2>&1; then
    log "_stack_stop_internal: WARNING process still alive after kill attempts (go2rtc=$(pidof go2rtc 2>/dev/null) v4l2rtspserver=$(pidof v4l2rtspserver 2>/dev/null))"
  fi
  rm -f "$STACK_MARKER" "$GO2RTC_CONFIG"
}

stack_stop() {
  [ -f "$STACK_MARKER" ] || return 0
  log "stack_stop: stopping"
  _stack_stop_internal
  log "stack_stop: done"
}

# 戻り値: 0=consumerあり, 1=consumerなし(確認できた), 2=go2rtc への問い合わせ自体が失敗(不明)。
# 呼び出し側は 2 を「consumerなし」と混同しないこと(視聴中セッションの誤切断につながる)。
has_consumers() {
  local body_file="/tmp/mocula-live-streams.json"
  local http_code result
  http_code=$(curl -s -m 5 -o "$body_file" -w '%{http_code}' "http://127.0.0.1:1984/api/streams" 2>/dev/null)
  if [ "$http_code" != "200" ]; then
    log_debug "has_consumers: go2rtc API unreachable (http=$http_code)"
    rm -f "$body_file"
    return 2
  fi
  # Non-empty consumers array: "consumers":[{...}]
  grep -q '"consumers":\[{' "$body_file"
  result=$?
  rm -f "$body_file"
  return $result
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

# stack_start/go2rtc 交換失敗をbackendへ報告する。この報告自体が失敗すると、backend側
# セッションは SENT_TO_CAMERA のまま取り残される(このプロセスはここで終了し以後 /status も
# 送らないため、offer→answer タイムアウト以外に気づく手段がない)。他のcurl呼び出しと同様に
# http_code を検証しログを残す。
report_answer_error() {
  local session_id="$1"
  local reason="$2"
  local http_code
  http_code=$(curl -s -m 15 -X POST \
    -o /dev/null -w '%{http_code}' \
    "$API_ORIGIN/api/v1/live-signal/$TENANT_KEY/$CAMERA_KEY/answer?session=${session_id}&error=${reason}" 2>/dev/null)
  case "$http_code" in
    2*)
      log_debug "report_answer_error: reported reason=$reason http=$http_code"
      ;;
    *)
      log "report_answer_error: FAILED to report reason=$reason http=$http_code session=$session_id"
      ;;
  esac
}

# カメラが backend からの stop/gone 指示を経ずに自発的にセッションを終える経路
# (LIVE_SESSION_MAX 到達) で呼ぶ。呼ばなければ backend 側セッションが CLOSED に
# 遷移せず、カメラ単位ロックが LOCK_TTL_MARGIN_SECONDS(backend 側定数)の猶予いっぱいまで
# 残留し、その間ブラウザは image フォールバックへ倒れたまま何のフレームも受け取れなくなる。
# 通知自体が失敗しても最終的にはロックが自然に失効するため retry はしない (ベストエフォート)。
report_session_ended() {
  local session_id="$1"
  local http_code
  http_code=$(curl -s -m 15 -X POST \
    -o /dev/null -w '%{http_code}' \
    "$API_ORIGIN/api/v1/live-signal/$TENANT_KEY/$CAMERA_KEY/end?session=${session_id}" 2>/dev/null)
  case "$http_code" in
    2*)
      log_debug "report_session_ended: reported http=$http_code"
      ;;
    *)
      log "report_session_ended: FAILED to report http=$http_code session=$session_id"
      ;;
  esac
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
      # curl 自体の失敗(000/空)や 5xx 等の真の異常系。DEBUG_MODE 無しでも追えるよう記録する。
      # STATUS_ACTION は空のままなので run_session 側の case はどれにもマッチせず継続する
      # (一過性の障害を想定した挙動だが、繰り返す場合はここのログが唯一の手がかりになる)。
      log "session_status: unexpected response http=$http_code session=$session_id"
      ;;
  esac
}

# $2 には run_session 側で既に経過した秒数(session_sec)を渡す。P2P区間+画像区間の
# 合計経過時間で LIVE_SESSION_MAX を判定するため、ここで 0 にリセットしてはならない。
image_mode() {
  local session_id="$1"
  local elapsed="${2:-0}"
  local fail_count=0
  local post_fail=0
  local frame_file="/tmp/mocula-live-frame.jpg"
  local action http_code

  log "image_mode: starting session=$session_id elapsed=${elapsed}s"

  while [ $elapsed -lt "$LIVE_SESSION_MAX" ]; do
    /scripts/cmd jpeg 1 | sed '1,3d' > "$frame_file"
    # JPEG マジックバイト(ff d8)を確認し、cmd のエラー出力等をフレームとして送らない
    # (BusyBox od は -A/-t/-N 非対応のため od -b を使う)
    if [ ! -s "$frame_file" ] || \
       [ "$(head -c 2 "$frame_file" | od -b | awk 'NR==1{print $2 $3}')" != "377330" ]; then
      fail_count=$((fail_count + 1))
      log_debug "image_mode: capture failed count=$fail_count"
      if [ $fail_count -ge 5 ]; then
        log "image_mode: JPEG capture failed ${fail_count} times, aborting"
        report_session_ended "$session_id"
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
          # post 自体が失敗し続けている状況なので report_session_ended も届かない可能性が高いが、
          # 呼び出し自体は idempotent (既に消えているセッションに対しては何もしない) なので
          # 無条件に試みる。届けば即座にロックが解放される。
          report_session_ended "$session_id"
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

  if [ $elapsed -ge "$LIVE_SESSION_MAX" ]; then
    log "session: max duration reached"
    report_session_ended "$session_id"
  fi

  rm -f "$frame_file"
  log "image_mode: ended elapsed=${elapsed}s"
}

# 1 セッションを最初から最後まで実行する
run_session() {
  local session_id="$1"
  local idle_sec=0
  local session_sec=0
  local consumers=0

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

    has_consumers
    case $? in
      0)
        idle_sec=0
        consumers=1
        ;;
      1)
        idle_sec=$((idle_sec + LIVE_SESSION_POLL))
        consumers=0
        if [ $idle_sec -ge "$LIVE_IDLE_TIMEOUT" ]; then
          log "session: idle timeout (no consumers)"
          break
        fi
        ;;
      *)
        # go2rtc への問い合わせ自体が失敗(一時的な負荷等)。実際に視聴者がいなくなったのかは
        # 分からないため、idle_sec は進めず直前の consumers 値のまま次周期へ進む
        # (誤って視聴中セッションをアイドルタイムアウトで切断しないため)。session_status の
        # 異常系と同様、DEBUG_MODE 無しでも追えるよう記録する (go2rtc がフリーズしたまま
        # pidof のクラッシュ検知をすり抜けるケースを本番でも発見できるようにするため)。
        log "session: has_consumers query failed, keeping previous idle state"
        ;;
    esac

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
        image_mode "$session_id" "$session_sec"
        break
        ;;
    esac

    session_sec=$((session_sec + LIVE_SESSION_POLL))
    if [ $session_sec -ge "$LIVE_SESSION_MAX" ]; then
      log "session: max duration reached"
      report_session_ended "$session_id"
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
