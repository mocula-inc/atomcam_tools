#!/bin/sh
#
# health_check.sh : ネットワーク死活監視 (cron から毎分実行)
#
# 設計方針:
#   1. スクリプト内で sleep ループを回さない。1回の実行は数秒で終わる。
#      毎分の刻みは cron が供給し、経過時間は /tmp の状態ファイルで管理する。
#      -> 実行が重ならないので、killall が他インスタンスの wpa_supplicant を
#         撃ち殺す事故が構造的に起きない。
#   2. 「起動後まだ一度も疎通していない」= ルーター起動待ちの可能性が高いので
#      辛抱強く待つ。「一度疎通してから切れた」= 実障害なので早く復旧する。
#   3. 経過時間は必ず /proc/uptime (単調増加) で測る。ntpd が時計を飛ばすため
#      date +%s で測ると「繋がった瞬間に再起動」する事故が起きる。
#   4. 正常時は /media/mmc に一切書き込まない。障害が起きたときだけ記録する。
#
# 状態ファイル (tmpfs = 再起動でクリアされるのが仕様):
#   /tmp/health_check.lock/     多重起動防止 (mkdir は atomic。flock は非搭載)
#   /tmp/health_check.up        起動後に一度でも疎通した印
#   /tmp/health_check.down      現在の連続失敗の開始 uptime 秒
#   /tmp/health_check.act       最後に復旧アクションを打った uptime 秒
#   /tmp/health_check.wedge     スキャン結果ゼロの連続回数
#   /tmp/health_check.hist      障害中の cause 別カウント (復帰時の経緯サマリー用)
#   /tmp/health_check.scan      この実行での scan_results 件数キャッシュ
#   /tmp/health_check.bootmark  このブートで netdiag.log に境界を書き済みの印
# SD カード上 (ログの読み取り補助。復旧の判断には使わない):
#   /media/mmc/.health_boot     ブート通番 (単調増加)
#   /media/mmc/healthcheck.log  障害時のみの1行サマリー
#   /media/mmc/netdiag.log      障害時のみの詳細スナップショット

# --- テスト用フック。cron 実行時は未設定なので本番パスと完全に同一になる ---
HC_ROOT="${HC_ROOT:-}"
UPTIME_FILE="${HC_UPTIME:-${HC_ROOT}/proc/uptime}"

TMP=${HC_ROOT}/tmp
MMC=${HC_ROOT}/media/mmc
SCRIPTS=${HC_ROOT}/scripts
LOGFILE=$MMC/healthcheck.log
DIAGFILE=$MMC/netdiag.log
HACK_INI=$TMP/hack.ini
BOOTSEQ=$MMC/.health_boot

LOCKDIR=$TMP/health_check.lock
F_UP=$TMP/health_check.up
F_DOWN=$TMP/health_check.down
F_ACT=$TMP/health_check.act
F_WEDGE=$TMP/health_check.wedge
F_HIST=$TMP/health_check.hist
F_SCAN=$TMP/health_check.scan
F_BOOTMARK=$TMP/health_check.bootmark

WPA_CONF=${HC_ROOT}/configs/etc/wpa_supplicant.conf
WPA_LOG=$TMP/log/wpa_supplicant.log
WPA_SOCK=${HC_ROOT}/var/run/wpa_supplicant/wlan0
PRODUCT_CONFIG=${HC_ROOT}/atom/configs/.product_config
# /atom_patch/bin/wpa_cli は常に COMPLETED を返す偽物なので絶対パスで呼ぶ
WPA_CLI=${HC_ROOT}/usr/sbin/wpa_cli

# --- しきい値 (秒) ---
BOOT_GRACE=120          # 起動直後は何もしない (network_init.sh の初期化中)
COLD_INTERVAL=300       # 未接続: 5 分ごとに穏やかな復旧
COLD_REBOOT=1200        # 未接続: 20 分でリブート
COLD_WEDGE_REBOOT=420   # 未接続 + 電波が全く見えない: 7 分でリブート
LOST_INTERVAL=120       # 切断: 2 分ごとに復旧
LOST_REBOOT=360         # 切断: 6 分でリブート
NODEV_INTERVAL=120      # wlan0 が存在しない: 2 分ごとに network_init.sh restart
NODEV_REBOOT=180        # wlan0 が存在しない: 3 分でリブート
WEDGE_TRIGGER=3         # スキャン結果ゼロが何回続いたら「電波が死んでいる」とみなすか

# ==================================================================
# 共通ヘルパー
# ==================================================================

uptime_sec() {
  awk '{print int($1); exit}' $UPTIME_FILE 2>/dev/null
}

read_int() {
  _v=""
  [ -f "$1" ] && _v=$(awk 'NR==1{print int($1); exit}' "$1" 2>/dev/null)
  [ -z "$_v" ] && _v=0
  echo $_v
}

mmc_writable() {
  [ -d "$MMC" ] && [ -w "$MMC" ]
}

# そのブートで最初にログを書く直前に一度だけ呼ばれる。
# 正常なブートでは一度も呼ばれない = SD に何も書かれない。
boot_marker() {
  [ -f "$F_BOOTMARK" ] && return 0
  mmc_writable || return 0
  _bn=$(read_int $BOOTSEQ)
  _bn=$((_bn + 1))
  echo $_bn > $BOOTSEQ
  echo $_bn > $F_BOOTMARK
  echo "==== boot=$_bn $(date +'%Y/%m/%d %H:%M:%S') up=${UPT}s ====" >> $DIAGFILE
}

boot_num() {
  read_int $F_BOOTMARK
}

# healthcheck.log への1行ログ。障害系のイベントでのみ呼ぶこと (正常時には呼ばない)。
log() {
  mmc_writable || return 0
  boot_marker
  echo "$(date +'%Y/%m/%d %H:%M:%S') : up=${UPT}s $*" >> $LOGFILE
}

# ==================================================================
# ロック (mkdir は atomic。flock は busybox 非搭載)
# ==================================================================

release_lock() {
  if [ "$LOCK_OWNED" = "1" ] ; then
    LOCK_OWNED=0
    rm -rf $LOCKDIR 2>/dev/null
  fi
}

acquire_lock() {
  if mkdir $LOCKDIR 2>/dev/null ; then
    echo $$ > $LOCKDIR/pid
    echo $UPT > $LOCKDIR/at
    LOCK_OWNED=1
    return 0
  fi
  # 既に誰かが持っている。生きているか / 古すぎないかを見る。
  # trap EXIT は SIGKILL では走らないので、age だけが最終的な安全弁になる。
  _lat=$(read_int $LOCKDIR/at)
  _lpid=$(cat $LOCKDIR/pid 2>/dev/null)
  if [ $((UPT - _lat)) -lt 300 ] ; then
    if [ -z "$_lpid" ] || kill -0 "$_lpid" 2>/dev/null ; then
      return 1
    fi
  fi
  log "stale lock (pid=$_lpid age=$((UPT - _lat))s) : taking over"
  rm -rf $LOCKDIR 2>/dev/null
  if mkdir $LOCKDIR 2>/dev/null ; then
    echo $$ > $LOCKDIR/pid
    echo $UPT > $LOCKDIR/at
    LOCK_OWNED=1
    return 0
  fi
  return 1
}

# ==================================================================
# wpa_cli / プロセス操作
# ==================================================================

# busybox 1.24 は "timeout -t SECS"、新しめの busybox/coreutils は "timeout SECS"
detect_timeout() {
  TMO=""
  if timeout -t 1 true > /dev/null 2>&1 ; then
    TMO="-t"
  elif timeout 1 true > /dev/null 2>&1 ; then
    TMO="plain"
  fi
}

wpa() {
  if [ "$TMO" = "-t" ] ; then
    timeout -t 5 $WPA_CLI -i wlan0 "$@" 2>/dev/null
  elif [ "$TMO" = "plain" ] ; then
    timeout 5 $WPA_CLI -i wlan0 "$@" 2>/dev/null
  else
    $WPA_CLI -i wlan0 "$@" 2>/dev/null
  fi
}

has_dev() {
  ip link 2>/dev/null | grep -q "$1"
}

has_addr() {
  ifconfig "$1" 2>/dev/null | grep -q 'inet addr'
}

# 指定インターフェース向けの udhcpc の PID だけを返す
# (killall udhcpc が USB-Ethernet 側の udhcpc まで巻き込むのを防ぐ)
udhcpc_pids() {
  ps 2>/dev/null | awk -v ifn="$1" '/[u]dhcpc/ { if (index($0, "-i " ifn)) print $1 }'
}

# SIGTERM -> 待つ -> それでも生きていたら SIGKILL。
# wpa_supplicant を SIGKILL すると ctrl_iface ソケットが残り、次回の起動が
# "ctrl_iface exists and seems to be in use" で失敗しうるため。
stop_pids() {
  [ -z "$1" ] && return 0
  kill -TERM $1 2>/dev/null
  _n=0
  while [ $_n -lt 8 ] ; do
    sleep 0.5
    _alive=""
    for _p in $1 ; do
      kill -0 "$_p" 2>/dev/null && _alive="$_alive $_p"
    done
    [ -z "$_alive" ] && return 0
    _n=$((_n + 1))
  done
  kill -KILL $_alive 2>/dev/null
  sleep 0.5
  return 0
}

start_wpa() {
  wpa_supplicant -f $WPA_LOG -D nl80211 -i wlan0 -c $WPA_CONF -B
}

start_dhcp() {
  # udhcpc 自身の標準出力は SD ではなく tmpfs に流す。SD が無くても常に成功する。
  udhcpc -i wlan0 -b >> $TMP/log/udhcpc.log 2>&1
}

kick_dhcp() {
  _d=$(udhcpc_pids wlan0)
  if [ -n "$_d" ] ; then
    log "DHCP renew (SIGUSR1) : $_d"
    kill -USR1 $_d 2>/dev/null
  else
    log "DHCP client restart"
    start_dhcp
  fi
}

restart_wifi() {
  log "wifi restart (wpa_state=${WSTATE:-none})"
  stop_pids "$(pidof wpa_supplicant)"
  stop_pids "$(udhcpc_pids wlan0)"
  rm -f $WPA_SOCK 2>/dev/null
  HWADDR=$(awk -F "=" '/(CONFIG_INFO|NETRELATED_MAC)=/ { print substr($2,1,2) ":" substr($2,3,2) ":" substr($2,5,2) ":" substr($2,7,2) ":" substr($2,9,2) ":" substr($2,11,2); exit;}' $PRODUCT_CONFIG 2>/dev/null)
  ifconfig wlan0 down
  if [ -n "$HWADDR" ] ; then
    ifconfig wlan0 hw ether $HWADDR up
  else
    ifconfig wlan0 up
  fi
  start_wpa
  start_dhcp
}

# ==================================================================
# 診断: 失敗原因の分類
# ==================================================================

target_ssid() {
  awk -F'"' '/ssid=/{print $2; exit}' $WPA_CONF 2>/dev/null
}

# scan_results は1回の実行で1度しか取らない (スキャンは数秒かかるため)
scan_snapshot() {
  [ -f "$F_SCAN" ] && return 0
  wpa scan_results > $TMP/health_check.scan_raw 2>/dev/null
  awk 'NR>1 && NF>=5 {n++} END{print n+0}' $TMP/health_check.scan_raw > $F_SCAN
}

scan_count() {
  scan_snapshot
  read_int $F_SCAN
}

target_in_scan() {
  scan_snapshot
  [ -n "$TARGET_SSID" ] && grep -qF "$TARGET_SSID" $TMP/health_check.scan_raw 2>/dev/null
}

# CAUSE / MODE / INTERVAL / REBOOT_AT を確定する。
# 順序は下位レイヤーから: デバイス無し -> プロセス無し -> 設定無し -> 電波無し ->
# 認証失敗 -> 関連付け拒否 -> AP 不在 -> DHCP -> 経路 -> 到達性。
# 認証/関連付け拒否はログの signature の方が SCANNING という状態そのものより
# 特定的なので、一般的な AP_NOT_FOUND より先に見る (両方とも一時的に
# wpa_state=SCANNING を経由するため、後に判定すると先に埋もれてしまう)。
classify() {
  WLAN=0 ; has_dev wlan0 && WLAN=1
  OTHER=0 ; { has_dev eth0 || has_dev usb0 ; } && OTHER=1

  if [ $WLAN = 0 -a $OTHER = 0 ] ; then
    CAUSE=NO_WLAN_DEV
    MODE=nodev ; INTERVAL=$NODEV_INTERVAL ; REBOOT_AT=$NODEV_REBOOT
    return
  fi

  if [ $WLAN = 0 ] ; then
    # wlan0 は無いが eth0/usb0 はある。無線側の話ではないので手を出さない。
    CAUSE=GW_UNREACHABLE
    MODE=lost ; INTERVAL=$LOST_INTERVAL ; REBOOT_AT=$LOST_REBOOT
    return
  fi

  WSTATE=$(wpa status | awk -F= '$1=="wpa_state"{print $2; exit}')
  TARGET_SSID=$(target_ssid)

  if [ -z "$(pidof wpa_supplicant)" ] ; then
    CAUSE=NO_SUPPLICANT
  elif [ -z "$TARGET_SSID" ] ; then
    CAUSE=SSID_UNCONFIGURED
  elif [ "$(scan_count)" = "0" ] ; then
    CAUSE=RADIO_DEAD
  elif [ -f "$WPA_LOG" ] && tail -n 30 "$WPA_LOG" 2>/dev/null | grep -qE '4-Way Handshake failed|SSID-TEMP-DISABLED|AUTH-REJECT' ; then
    CAUSE=AUTH_FAILED
  elif [ -f "$WPA_LOG" ] && tail -n 30 "$WPA_LOG" 2>/dev/null | grep -q 'ASSOC-REJECT' ; then
    CAUSE=ASSOC_REJECTED
  elif ! target_in_scan ; then
    CAUSE=AP_NOT_FOUND
  elif [ "$WSTATE" = "COMPLETED" ] && ! has_addr wlan0 ; then
    CAUSE=NO_DHCP_LEASE
  elif has_addr wlan0 && [ -z "$ROUTER" ] ; then
    CAUSE=NO_DEFAULT_ROUTE
  else
    CAUSE=GW_UNREACHABLE
  fi

  if [ -f $F_UP ] ; then
    MODE=lost ; INTERVAL=$LOST_INTERVAL ; REBOOT_AT=$LOST_REBOOT
  else
    MODE=cold ; INTERVAL=$COLD_INTERVAL ; REBOOT_AT=$COLD_REBOOT
  fi

  # 未接続かつ電波が全く見えない = 無線チップが死んでいる公算が高いので待ち時間を縮める
  if [ "$MODE" = "cold" -a "$CAUSE" = "RADIO_DEAD" ] ; then
    echo $(( $(read_int $F_WEDGE) + 1 )) > $F_WEDGE
    [ $(read_int $F_WEDGE) -ge $WEDGE_TRIGGER ] && REBOOT_AT=$COLD_WEDGE_REBOOT
  elif [ "$MODE" = "cold" ] ; then
    rm -f $F_WEDGE
  fi
}

# ==================================================================
# 診断: netdiag.log への詳細スナップショット
# ==================================================================

diag_snapshot() {
  mmc_writable || return 0
  boot_marker
  {
    echo "==== $(date +'%Y/%m/%d %H:%M:%S') up=${UPT}s boot=$(boot_num) event=$1 cause=${CAUSE:-unknown} ===="
    echo "[status]   $(wpa status 2>/dev/null | tr '\n' ' ')"
    echo "[config]   ssid=\"${TARGET_SSID}\""
    echo "[scan]     $(scan_count) AP visible"
    wpa scan_results 2>/dev/null | awk 'NR>1 && NR<=11' | sed 's/^/             /'
    echo "[link]     router=${ROUTER:-none} iface=${IFACE:-none} addr=$(has_addr wlan0 && echo yes || echo no)"
    if [ -f "$WPA_LOG" ] ; then
      echo "[wpa_log]"
      tail -n 30 "$WPA_LOG" 2>/dev/null | grep 'CTRL-EVENT' | sed 's/^/             /'
    fi
    echo "[dmesg]"
    dmesg 2>/dev/null | grep -iE 'wifi|atbm|rtl81|mmc|sdio' | tail -n 20 | sed 's/^/             /'
  } >> $DIAGFILE
  sync
}

# ==================================================================
# 本体
# ==================================================================

UPT=$(uptime_sec)
[ -z "$UPT" ] && UPT=0

MONITORING_NETWORK=$(awk -F "=" '/^MONITORING_NETWORK *=/ {print $2}' $HACK_INI 2>/dev/null)
MONITORING_REBOOT=$(awk -F "=" '/^MONITORING_REBOOT *=/ {print $2}' $HACK_INI 2>/dev/null)
HEALTHCHECK=$(awk -F "=" '/^HEALTHCHECK *=/ {print $2}' $HACK_INI 2>/dev/null)
HEALTHCHECK_PING_URL=$(awk -F "=" '/^HEALTHCHECK_PING_URL *=/ {print $2}' $HACK_INI 2>/dev/null)

LOCK_OWNED=0
trap release_lock EXIT INT TERM HUP
acquire_lock || exit 0

detect_timeout

# --- 疎通判定 -------------------------------------------------------
# ルーターアドレスは毎回 ip route から取り直す。
# /tmp/router_address を信用し続けると、ルーター交換や別サブネットへの移動で
# 「健康なのに永久に ping 失敗 -> 永久リブート」になる。
IFACE=$(ip route 2>/dev/null | awk '$1=="default" {print $5; exit}')
ROUTER=$(ip route 2>/dev/null | awk '$1=="default" {print $3; exit}')
[ -n "$ROUTER" ] && echo "$ROUTER" > $TMP/router_address

NET_OK=0
if [ -n "$ROUTER" ] ; then
  if ping -c 1 -W 2 $ROUTER > /dev/null 2>&1 ; then
    NET_OK=1
  elif ping -c 2 -W 3 $ROUTER > /dev/null 2>&1 ; then
    # 1 パケット落ちただけで障害扱いしない (無線では日常的に起きる)
    NET_OK=1
  fi
fi

# --- 正常系 ---------------------------------------------------------
if [ $NET_OK = 1 ] ; then
  if [ -s $F_HIST ] ; then
    _summary=$(awk '{c[$1]+=$2} END{for(k in c) printf "%s×%d ", k, c[k]}' $F_HIST)
    if [ -f $F_UP ] ; then
      log "Network recovered : router=$ROUTER ($_summary)"
    else
      log "Network up : router=$ROUTER (${UPT}s after boot / $_summary)"
    fi
  fi
  [ ! -f $F_UP ] && echo $UPT > $F_UP
  rm -f $F_DOWN $F_ACT $F_WEDGE $F_HIST $F_SCAN $TMP/health_check.scan_raw $TMP/health_check.ssid_warned
  if [ "$HEALTHCHECK" = "on" -a "$HEALTHCHECK_PING_URL" != "" ] ; then
    RES=`curl --ipv4 --max-time 5 --retry 3 --retry-delay 1 --location --silent --show-error --output /dev/null --write-out "%{http_code}" $HEALTHCHECK_PING_URL`
    case "$RES" in
      2??) ;; # 正常。ローカルには残さない (外形監視の目的は curl 自体で達成済み)
      *) log "healthcheck ping : $RES" ;;
    esac
  fi
  exit 0
fi

# --- 異常系 ---------------------------------------------------------
[ "$MONITORING_NETWORK" = "off" ] && exit 0
[ -n "$(pidof hostapd)" ] && exit 0     # ペアリング (AP) モード中は何もしない
[ $UPT -lt $BOOT_GRACE ] && exit 0      # 起動直後。network_init.sh がまだ動いている

FAILSINCE=$(read_int $F_DOWN)
if [ $FAILSINCE -eq 0 ] ; then
  FAILSINCE=$UPT
  echo $UPT > $F_DOWN
fi
FAILED=$((UPT - FAILSINCE))
[ $FAILED -lt 0 ] && FAILED=0

classify

# SSID 未設定は「ユーザーがペアリングするまで永久に直らない」静的な状態なので、
# 毎分書き続けても摩耗が増えるだけで得るものがない。ブートにつき1回だけ記録する。
if [ "$CAUSE" = "SSID_UNCONFIGURED" ] ; then
  if [ ! -f $TMP/health_check.ssid_warned ] ; then
    log "cause=$CAUSE : SSID not configured (pairing required) : will not retry or reboot"
    touch $TMP/health_check.ssid_warned
  fi
  exit 0
fi

echo "$CAUSE 1" >> $F_HIST
if [ "$CAUSE" = "AP_NOT_FOUND" ] ; then
  _visible=$(wpa scan_results 2>/dev/null | awk -F'\t' 'NR>1 && NF>=5 {printf "\"%s\"(%s) ", $5, $3}')
  log "cause=$CAUSE ssid=\"$TARGET_SSID\" state=${WSTATE:-none} failed=${FAILED}s scan=$(scan_count)"
  [ -n "$_visible" ] && log "  visible: $_visible"
else
  log "cause=$CAUSE state=${WSTATE:-none} failed=${FAILED}s router=${ROUTER:-none}"
fi

# --- デーモンの生存確認 (毎分。エスカレーションとは独立) ------------
if [ $WLAN = 1 -a "$MODE" != "nodev" ] ; then
  if [ -z "$(pidof wpa_supplicant)" ] ; then
    log "wpa_supplicant is not running : starting"
    rm -f $WPA_SOCK 2>/dev/null
    start_wpa
  fi
  if [ -z "$(udhcpc_pids wlan0)" ] ; then
    log "udhcpc(wlan0) is not running : starting"
    start_dhcp
  fi
fi

# --- エスカレーション判定 -------------------------------------------
LASTACT=$(read_int $F_ACT)
[ $LASTACT -eq 0 ] && LASTACT=$FAILSINCE

if [ $FAILED -lt $REBOOT_AT ] ; then
  if [ $FAILED -lt $INTERVAL -o $((UPT - LASTACT)) -lt $INTERVAL ] ; then
    exit 0
  fi
fi

echo $UPT > $F_ACT

# リブートするかどうかをここで確定する (フックより先。フックはこれを覆せる)。
# スナップショットは1回だけ、実際に起きる (であろう) ことに合わせたラベルで書く。
WILL_REBOOT=0
if [ $FAILED -ge $REBOOT_AT ] ; then
  WILL_REBOOT=1
  [ "$MONITORING_REBOOT" = "off" ] && WILL_REBOOT=0
  [ -f $MMC/atom-debug ] && WILL_REBOOT=0
fi

if [ $WILL_REBOOT = 1 ] ; then
  diag_snapshot "reboot"
else
  diag_snapshot "action"
fi

# SD カード上のフックが政策を上書きできる契約は維持する (100 なら以降を抑止)
if [ -x $MMC/network_init.sh ] ; then
  $MMC/network_init.sh restart >> $LOGFILE 2>&1
  [ "$?" = "100" ] && exit 0
fi

# --- リブート -------------------------------------------------------
if [ $WILL_REBOOT = 1 ] ; then
  log "retry error -> reboot : cause=$CAUSE failed=${FAILED}s"
  $SCRIPTS/cmd timelapse stop
  sleep 3
  killall -SIGUSR2 iCamera_app 2>/dev/null
  sync
  release_lock
  reboot
  exit 0
fi

# --- 穏やかな復旧 ---------------------------------------------------
if [ "$MODE" = "nodev" ] ; then
  # ドライバの insmod 自体が失敗している。まず insmod からやり直す
  log "re-running network_init.sh (wlan0/eth0/usb0 not present)"
  $SCRIPTS/network_init.sh restart >> $LOGFILE 2>&1
  exit 0
fi

if [ $WLAN = 0 ] ; then
  # wlan0 は無いが eth0/usb0 はある。無線を触っても意味がないので何もしない
  exit 0
fi

if [ -n "$IFACE" -a "$IFACE" != "wlan0" ] ; then
  log "primary=$IFACE is not wlan0 : leaving wlan0 alone"
  exit 0
fi

case "$WSTATE" in
  ASSOCIATING|ASSOCIATED|AUTHENTICATING|4WAY_HANDSHAKE|GROUP_HANDSHAKE)
    # 接続処理の途中。ここで殺すと必ず失敗する。今回は見送るが
    # 失敗タイマーは止めないので、続くようなら次の段階に進む
    ;;
  COMPLETED)
    # 関連付けは生きている。壊さずに DHCP だけ叩く
    kick_dhcp
    ;;
  *)
    # SCANNING / DISCONNECTED / INACTIVE / 応答なし = 進んでいない
    restart_wifi
    ;;
esac

exit 0
