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
#   4. 正常時に /media/mmc へ書くのはブート毎の1行サマリーだけ。それ以外は
#      障害が起きたときと状態が変わったときにしか書かない。
#      (以前は正常時に一切書かなかったが、「ログが空」が「正常」なのか
#       「監視が動いていない」のか区別できず切り分けが遅れたため改めた)
#   5. ゲートウェイへの ping だけを疎通の定義にしない。ルーターより先にカメラが
#      起動した場合、ルーターは応答するのにその先が繋がっていない状態が続く。
#      インターネット / 名前解決 / origin までを別レイヤーとして判定する。
#
# 判定レイヤー (下から順に。上が失敗したらそこで止める):
#   wifi     -> classify() : NO_WLAN_DEV / RADIO_DEAD / AUTH_FAILED / AP_NOT_FOUND ...
#   gateway  -> probe_gw() : NO_DEFAULT_ROUTE / GW_UNREACHABLE
#   internet -> probe_icmp() + probe_http204() : INET_UNREACHABLE / DNS_FAILED /
#               INET_HTTP_BLOCKED / CAPTIVE_PORTAL
#   origin   -> probe_origin() : ORIGIN_UNREACHABLE / ORIGIN_TLS_FAILED /
#               ORIGIN_DNS_FAILED
#   時計     -> clock_recover() : CLOCK_UNSYNCED
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
#   /tmp/health_check.summary   このブートのサマリー行を書き済みの印
#   /tmp/health_check.summary_final 上位レイヤーまで判定したサマリーを書き済みの印
#                               (これが無い間は暫定なので 1 度だけ上書きできる)
#   /tmp/health_check.inet      直近の上位レイヤーの状態 (OK または cause)
#   /tmp/health_check.inet_at   直近に上位レイヤーを確認した uptime 秒
#   /tmp/health_check.inet_since 現在の上位レイヤー障害の開始 uptime 秒
#   /tmp/health_check.inet_beat 直近に「まだ落ちている」を書いた uptime 秒
#   /tmp/health_check.dnskick   直近に DNS 復旧の DHCP RENEW を打った uptime 秒
#   /tmp/health_check.dnskick_n この障害エピソードで打った RENEW の回数
#   /tmp/health_check.ntpact    直近に S42ntpd を再起動した uptime 秒
#   /tmp/health_check.ntpn      このブートでの S42ntpd 再起動回数
#   /tmp/health_check.clock_ok  このブートで時計を検証済みの印
#   /tmp/health_check.clock_http HTTP Date による時刻補正を実施済みの印
#   /tmp/health_check.timeini   直近に time.ini を書いた uptime 秒
# SD カード上:
#   /media/mmc/.health_boot     ブート通番 (単調増加)
#   /media/mmc/healthcheck.log  ブート毎のサマリーと、障害/復帰時の1行ログ
#   /media/mmc/netdiag.log      障害時の詳細スナップショット
#   /media/mmc/time.ini         検証済みの時刻 (次のブートで S42ntpd が読む)

# --- テスト用フック。cron 実行時は未設定なので本番パスと完全に同一になる ---
HC_ROOT="${HC_ROOT:-}"
UPTIME_FILE="${HC_UPTIME:-${HC_ROOT}/proc/uptime}"

TMP=${HC_ROOT}/tmp
MMC=${HC_ROOT}/media/mmc
SCRIPTS=${HC_ROOT}/scripts
INITD=${HC_ROOT}/etc/init.d
LOGFILE=$MMC/healthcheck.log
DIAGFILE=$MMC/netdiag.log
HACK_INI=$TMP/hack.ini
BOOTSEQ=$MMC/.health_boot
MCONFIG=$MMC/mconfig
RESOLV_CONF=$TMP/resolv.conf

LOCKDIR=$TMP/health_check.lock
F_UP=$TMP/health_check.up
F_DOWN=$TMP/health_check.down
F_ACT=$TMP/health_check.act
F_WEDGE=$TMP/health_check.wedge
F_HIST=$TMP/health_check.hist
F_SCAN=$TMP/health_check.scan
F_BOOTMARK=$TMP/health_check.bootmark
F_INET=$TMP/health_check.inet
F_INET_AT=$TMP/health_check.inet_at
F_INET_SINCE=$TMP/health_check.inet_since
F_INET_BEAT=$TMP/health_check.inet_beat
F_DNSKICK=$TMP/health_check.dnskick
F_DNSKICK_N=$TMP/health_check.dnskick_n
F_NTPACT=$TMP/health_check.ntpact
F_NTPN=$TMP/health_check.ntpn
F_CLOCK_OK=$TMP/health_check.clock_ok
F_CLOCK_HTTP=$TMP/health_check.clock_http
F_TIMEINI=$TMP/health_check.timeini
F_SUMMARY=$TMP/health_check.summary
F_SUMMARY_FINAL=$TMP/health_check.summary_final

WPA_CONF=${HC_ROOT}/configs/etc/wpa_supplicant.conf
WPA_LOG=$TMP/log/wpa_supplicant.log
WPA_SOCK=${HC_ROOT}/var/run/wpa_supplicant/wlan0
PRODUCT_CONFIG=${HC_ROOT}/atom/configs/.product_config
NET_WIRELESS=${HC_ROOT}/proc/net/wireless
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

# --- 上位レイヤー (インターネット / 名前解決 / origin) ---
# ゲートウェイに ping が通っても、その先が繋がっているとは限らない。
# ルーターより先にカメラが起動した場合がまさにそれで、旧実装はこれを「正常」と
# 判定して何も記録しなかった。
INET_INTERVAL=600       # 全レイヤー正常時の再確認間隔 (毎分は叩かない)
INET_FAIL_INTERVAL=120  # 上位レイヤー障害中の再確認間隔
# 起動直後は上流が遅れて上がってくる過渡期 (ルーターの起動待ち、SIM ルーターの回線
# 接続待ち等) なので、障害中の再確認を cron の刻みどおり毎分に上げる。開通を最大
# 120 秒見逃す状態だと、時計の修復 (clock_recover は INET_STATE が OK か ORIGIN_* の
# ときしか呼ばれない) がまるごとそのぶん遅れる。
# 30 なのは 60 が境界に張り付くため。cron の刻みは 60 秒ちょうどで uptime_sec() は
# int() で切り捨てるので、閾値 60 だと tick 間の差が 59 に落ちた回だけ黙って
# スキップされ、実質 120 秒になる。ntpd の時刻ジャンプ直後は crond の発火間隔自体も
# 乱れる。「毎 tick 実行したい」意図は 60 未満の閾値で表現すること。
INET_FAIL_INTERVAL_EARLY=30
INET_EARLY_UNTIL=600    # この uptime までを「起動直後」とみなす
INET_HEARTBEAT=1800     # 障害継続中に「まだ落ちている」を1行だけ書く間隔
# 確認先は必ず事業者の異なる 2 系統を持つ。1 社に絞ると、その事業者がまとめて
# 塞がれている網 (Google が届かない国、企業のブロックリスト、ISP の障害) で
# 正常なカメラを INET_UNREACHABLE と誤判定し、60 分ごとにリブートし続ける。
# 予備を叩くのは 1 段目が失敗したときだけなので、正常時の所要時間は変わらない。
INET_PING_HOST=8.8.8.8   # IP 層の確認先 (DNS も TLS も使わない)
INET_PING_HOST2=1.1.1.1  # 予備 (Cloudflare)。別 AS・別事業者であることが要点
INET_PING_TIMEOUT=3
# 平文 HTTP。TLS を使わないので時計が狂っていても判定できるのが選定理由。
# 204 以外が返ったらキャプティブポータルとみなせる。予備も 204 を返す実装を選ぶ
# (captive.apple.com や msftconnecttest は 200 + 本文なので判定式が変わってしまう)。
INET_HTTP_URL=http://connectivitycheck.gstatic.com/generate_204
INET_HTTP_URL2=http://cp.cloudflare.com/generate_204
INET_HTTP_CONNECT_TIMEOUT=3
INET_HTTP_TIMEOUT=5
DNS_CHECK_TIMEOUT=5     # curl 28 が名前解決で詰まったのかを確かめる nslookup の制限
ORIGIN_CONNECT_TIMEOUT=4
ORIGIN_TIMEOUT=8
DNS_KICK_INTERVAL=300   # DNS 復旧のための DHCP RENEW の最短間隔
DNS_KICK_MAX=6          # 1 障害エピソードあたりの RENEW 回数上限 (計 30 分)
INET_REBOOT=3600        # ゲートウェイ OK・インターネット断が継続したときのリブート閾値

# --- 時計 ---
# 時計が狂ったままだと https の証明書検証が "not yet valid" で恒久的に失敗する。
# mocula.sh の sync_clock_from_server() は camera-sync の成功が前提なので、
# その手前にいるこの状態は鶏卵になって救えない。ここで断ち切る。
#
# ★ この値は 4 箇所で揃えること。1 つでも忘れると時計まわりが黙って壊れる:
#      etc/init.d/S42ntpd         の CLOCK_MIN_EPOCH  (起動時の time.ini 復元に使う)
#      tests/test_health_check.sh の CLOCK_EPOCH      (時計フィクスチャ)
#      tests/test_s42ntpd.sh      の CLOCK_EPOCH      (時計フィクスチャ)
#    テスト側のフィクスチャがこの値より前だと clock_sane() が常に false になり、
#    時刻系のテストがまとめて落ちる。
#    リリースのたびに更新する必要はない。気づいたときにビルド時刻へ寄せれば十分。
CLOCK_MIN_EPOCH=1786712722  # 2026-08-14 22:05:22 JST (=13:05:22 UTC)。これより前 = 未同期
CLOCK_MAX_EPOCH=2145916800  # 2038/01/01。32bit 算術を壊さない上限
NTP_MAX_TRIES=2         # 1 ブートあたりの S42ntpd 再起動回数
NTP_RETRY_INTERVAL=900
NTP_RESTART_TIMEOUT=25  # S42ntpd start は ping と ntpd -q で数分ブロックしうる
TIMEINI_INTERVAL=3600   # /media/mmc/time.ini の書き出し間隔

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

# 時計の読み書きは必ずこの2つを経由する (テストで差し替えられるようにするため)。
# 経過時間の計測には絶対に使わないこと -> 設計方針 3.
now_epoch() {
  date +%s
}

set_clock() {
  date -s "@$1" > /dev/null 2>&1
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
# mconfig / 時刻文字列の解釈 (副作用のない純粋関数)
# ==================================================================

# /media/mmc/mconfig の [global] セクションから origin を取り出す。
# mocula.sh の load_config() は awk の出力を eval しているが、ここでは真似しない。
# mconfig は SD カード上のファイルで任意の文字列が入りうるため、値は使う前に
# 文字種を検査し、通らなければ「origin 層は判定しない」として失敗を返す。
#   0: 標準出力に URL   1: mconfig 無し / 値が不正
origin_url() {
  [ -f "$MCONFIG" ] || return 1
  _o=$(awk '
    # busybox awk はブラケット式の中の \[ \] を解釈しないので sub() 2回で切り出す
    /^[ \t]*\[/ { sec = $0 ; sub(/^[ \t]*\[/, "", sec) ; sub(/\].*$/, "", sec) ; next }
    sec == "global" {
      p = index($0, "=")
      if (p == 0) next
      k = substr($0, 1, p - 1) ; v = substr($0, p + 1)
      gsub(/^[ \t]+/, "", k) ; gsub(/[ \t\r]+$/, "", k)
      gsub(/^[ \t]+/, "", v) ; gsub(/[ \t\r]+$/, "", v)
      if (k == "origin" && v != "") { print v ; exit }
    }' "$MCONFIG" 2>/dev/null)
  # origin を書いていない mconfig は mocula.sh と同じ既定値を使う
  [ -z "$_o" ] && _o=https://app.mocula.jp
  case "$_o" in
    *[!A-Za-z0-9:/._-]*) return 1 ;;
  esac
  echo "$_o"
}

# ログ用にホスト名だけを取り出す (URL 全体はログが読みにくくなるため)
origin_host() {
  echo "$1" | sed -e 's|^[A-Za-z][A-Za-z0-9+.-]*://||' -e 's|[/?#].*$||' -e 's|^.*@||'
}

# RFC1123 の Date: ヘッダ ("Sun, 10 Aug 2026 12:34:56 GMT") を epoch 秒へ変換する。
# busybox の date は RFC1123 を解釈できず、-D の挙動はバージョン差が大きい上に
# 失敗しても数時間ずれた値を返すという最悪の壊れ方をするので使わない。
# days-from-civil を awk で自前計算する。解釈できない入力では何も出力しない。
http_date_to_epoch() {
  awk '
    BEGIN { split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", n, " ")
            for (i = 1; i <= 12; i++) mi[n[i]] = i }
    {
      sub(/\r$/, "")
      if (NF < 5) exit
      d = $2 + 0 ; m = mi[$3] + 0 ; y = $4 + 0
      if (m == 0 || d < 1 || d > 31 || y < 1970 || y > 2100) exit
      if (split($5, t, ":") != 3) exit
      if (t[1] > 23 || t[2] > 59 || t[3] > 60) exit
      yy  = y - (m <= 2)
      era = int((yy >= 0 ? yy : yy - 399) / 400)
      yoe = yy - era * 400
      doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      printf "%.0f\n", (era * 146097 + doe - 719468) * 86400 + t[1]*3600 + t[2]*60 + t[3]
      exit
    }'
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

# detect_timeout() の結果を使って任意のコマンドに制限時間を掛ける。
# timeout が使えない環境ではそのまま実行する (従来の wpa() と同じ挙動)。
tmo() {   # tmo SECS cmd...
  _s=$1 ; shift
  if [ "$TMO" = "-t" ] ; then
    timeout -t $_s "$@"
  elif [ "$TMO" = "plain" ] ; then
    timeout $_s "$@"
  else
    "$@"
  fi
}

wpa() {
  tmo 5 $WPA_CLI -i wlan0 "$@" 2>/dev/null
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

start_dhcp() {   # start_dhcp [iface]
  _sif=${1:-wlan0}
  # udhcpc 自身の標準出力は SD ではなく tmpfs に流す。SD が無くても常に成功する。
  udhcpc -i $_sif -b >> $TMP/log/udhcpc.log 2>&1
}

# インターフェースは省略可能 (既定 wlan0)。USB-Ethernet 機で呼ばれたときに
# 存在しない wlan0 へ udhcpc を生成し続けないよう、呼び出し側が明示できる。
kick_dhcp() {   # kick_dhcp [iface]
  _kif=${1:-wlan0}
  _d=$(udhcpc_pids $_kif)
  if [ -n "$_d" ] ; then
    log "DHCP renew (SIGUSR1) : iface=$_kif pid=$_d"
    kill -USR1 $_d 2>/dev/null
  else
    log "DHCP client restart : iface=$_kif"
    start_dhcp $_kif
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

# 上位レイヤー用のスナップショット。WiFi 層は既知良好なので、時間のかかる
# scan_results と dmesg は載せない。
inet_snapshot() {   # $1 = イベントラベル
  mmc_writable || return 0
  boot_marker
  {
    echo "==== $(date +'%Y/%m/%d %H:%M:%S') up=${UPT}s boot=$(boot_num) event=$1 cause=${INET_STATE:-unknown} ===="
    echo "[layer]    wifi=ok gw=ok icmp=$([ "$ICMP_OK" = "1" ] && echo ok || echo fail) http204=$([ "$HTTP_CODE" = "204" ] && echo ok || echo fail) origin=${ORIGIN_STATE:-skipped}"
    echo "[probe]    icmp_host=${ICMP_HOST_USED:-$INET_PING_HOST} http_url=${HTTP_URL_USED:-$INET_HTTP_URL} http_curl=$HTTP_CURL http_code=$HTTP_CODE origin_curl=$ORIGIN_CURL origin_code=$ORIGIN_CODE"
    echo "[resolv]   $(resolv_summary)"
    echo "[route]"
    ip route 2>/dev/null | sed 's/^/             /'
    echo "[dns]      $(tmo $DNS_CHECK_TIMEOUT nslookup $(origin_host "${HTTP_URL_USED:-$INET_HTTP_URL}") 2>&1 | tr '\n' ' ' | sed 's/  */ /g')"
    echo "[origin]   url=${ORIGIN_URL:-none} mconfig=$([ -f $MCONFIG ] && echo present || echo absent)"
    echo "[clock]    now=$(date +'%Y/%m/%d %H:%M:%S') epoch=$(now_epoch) sane=$(clock_sane && echo yes || echo no) ntpd=$(ntpd_running && pidof ntpd || echo dead)"
    echo "[dhcp]     iface=${IFACE:-none} udhcpc=$(udhcpc_pids ${IFACE:-wlan0})"
    echo "[link]     router=${ROUTER:-none} iface=${IFACE:-none} addr=$(has_addr wlan0 && echo yes || echo no) rssi=$(wifi_rssi)"
    echo "[wpa]      $(wpa status 2>/dev/null | tr '\n' ' ')"
  } >> $DIAGFILE
  sync
}

# ==================================================================
# ブート毎のサマリー (1 ブート 1 行)
# ==================================================================

# 旧実装は正常なブートでは SD に一切書かなかったため、「ログが空」が
# 「正常」なのか「監視が動いていない」のか区別できなかった。全レイヤーの
# 判定結果を 1 行だけ残す。障害時の毎分ログとは別物であることに注意。
#
# 呼び出し元は 2 つある (正常系と異常系) が、単純に「1 ブート 1 回」で latch すると
# 先に到達した方が勝つ。ルーターより先に起動した場合は必ず異常系が先に来るので、
# 「ゲートウェイまで届いていない」という起動直後の暫定判定だけが残り、その後
# ルーターが上がって 5 層すべてを判定しても記録されない = この機能が狙った
# ケースでちょうど役に立たなくなる。
#
# そこで「上位レイヤーの判定が実際に確定したか」($INET_STATE が空でないか) で
# 暫定と確定を区別し、確定は暫定を 1 度だけ上書きできることにする。
# ゲートウェイまで一度も届かないブートでは $INET_STATE が生成されないので、
# 上書きの経路には入らない (1 ブート 1 行のまま)。最大でも 1 ブート 2 行。
write_summary() {
  if [ -n "${INET_STATE:-}" ] ; then
    [ -f $F_SUMMARY_FINAL ] && return 0
  else
    [ -f $F_SUMMARY ] && return 0
  fi
  mmc_writable || return 0
  touch $F_SUMMARY
  [ -n "${INET_STATE:-}" ] && touch $F_SUMMARY_FINAL
  boot_marker

  if has_dev wlan0 ; then
    if [ "$NET_OK" = "1" ] ; then
      _s_wifi="ok(ssid=\"$(wifi_ssid)\" rssi=$(wifi_rssi))"
    else
      _s_wifi="FAIL(state=${WSTATE:-none})"
    fi
  else
    _s_wifi="n/a"        # USB-Ethernet 機。無線の話ではない
  fi

  if [ "$NET_OK" = "1" ] ; then
    _s_gw="ok($ROUTER)"
  else
    _s_gw="FAIL(${CAUSE:-unknown})"
  fi

  _s_inet=skipped ; _s_dns=skipped ; _s_origin=skipped ; _s_cause=""
  case "${INET_STATE:-}" in
    "")                 ;;   # ゲートウェイまでで止まっており上位は見ていない
    OK)                 _s_inet=ok ; _s_dns=ok ; _s_origin=$ORIGIN_STATE ;;
    DNS_FAILED)         _s_inet=$([ "$ICMP_OK" = "1" ] && echo ok || echo FAIL)
                        _s_dns=FAILED ; _s_cause=$INET_STATE ;;
    INET_UNREACHABLE)   _s_inet=FAIL ; _s_cause=$INET_STATE ;;
    INET_HTTP_BLOCKED)  _s_inet="FAIL(http)" ; _s_dns=ok ; _s_cause=$INET_STATE ;;
    CAPTIVE_PORTAL)     _s_inet="FAIL(portal)" ; _s_dns=ok ; _s_cause=$INET_STATE ;;
    ORIGIN_*)           _s_inet=ok ; _s_dns=ok ; _s_origin=$ORIGIN_STATE ; _s_cause=$INET_STATE ;;
  esac
  [ -z "$_s_cause" ] && [ "$NET_OK" != "1" ] && _s_cause=${CAUSE:-unknown}

  log "summary boot=$(boot_num) iface=${IFACE:-none} wifi=$_s_wifi gw=$_s_gw inet=$_s_inet dns=$_s_dns origin=$_s_origin clock=$(clock_sane && echo ok || echo unsynced)${_s_cause:+ cause=$_s_cause}"
}

# ==================================================================
# 疎通プローブ
# ==================================================================

# デフォルトゲートウェイへの ping。
# 1 パケット落ちただけで障害扱いしない (無線では日常的に起きる)。
probe_gw() {
  [ -z "$ROUTER" ] && return 1
  ping -c 1 -W 2 $ROUTER > /dev/null 2>&1 && return 0
  ping -c 2 -W 3 $ROUTER > /dev/null 2>&1
}

# IP 層。名前解決も TLS も使わないので、DNS が壊れていても時計が狂っていても判定できる。
# 1 段目が通れば 2 段目は叩かない。どちらに応答があったかは ICMP_HOST_USED に残す。
probe_icmp() {
  ICMP_HOST_USED=$INET_PING_HOST
  ping -c 1 -W $INET_PING_TIMEOUT $INET_PING_HOST > /dev/null 2>&1 && return 0
  ICMP_HOST_USED=$INET_PING_HOST2
  ping -c 1 -W $INET_PING_TIMEOUT $INET_PING_HOST2 > /dev/null 2>&1
}

# generate_204 を 1 回。結果は HTTP_CODE / HTTP_CURL に残す (呼び出し側が分類に使う)。
http204_once() {   # $1 = URL
  HTTP_CODE=$(curl --ipv4 --connect-timeout $INET_HTTP_CONNECT_TIMEOUT \
    --max-time $INET_HTTP_TIMEOUT --silent --output /dev/null \
    --write-out '%{http_code}' "$1" 2>/dev/null)
  HTTP_CURL=$?
  [ -z "$HTTP_CODE" ] && HTTP_CODE=000
  [ "$HTTP_CURL" = "0" ] && [ "$HTTP_CODE" = "204" ]
}

# DNS + HTTP 層。1 段目が 204 を返さなければ別事業者でもう一度だけ確かめ、
# 両方駄目なときにだけ障害と判定する。分類には 2 段目の結果を使う
# (HTTP_CODE / HTTP_CURL は http204_once が上書きする)。実際に判定に使った
# URL は HTTP_URL_USED に残し、ログにもそちらを出す。
probe_http204() {
  HTTP_URL_USED=$INET_HTTP_URL
  http204_once "$INET_HTTP_URL" && return 0
  HTTP_URL_USED=$INET_HTTP_URL2
  http204_once "$INET_HTTP_URL2"
}

# origin 層。到達性だけを見るので HEAD で足りる。
# 4xx はパス違い、5xx はサーバ側の障害。どちらも「経路は通っている」ので成功扱い。
probe_origin() {
  ORIGIN_CODE=$(curl --ipv4 --head --connect-timeout $ORIGIN_CONNECT_TIMEOUT \
    --max-time $ORIGIN_TIMEOUT --silent --output /dev/null \
    --write-out '%{http_code}' "$ORIGIN_URL" 2>/dev/null)
  ORIGIN_CURL=$?
  [ -z "$ORIGIN_CODE" ] && ORIGIN_CODE=000
  [ "$ORIGIN_CURL" = "0" ]
}

# 名前が引けるかどうかの確認。curl の終了コードだけでは足りない場合にだけ使う。
dns_resolves() {   # $1 = ホスト名
  [ -z "$1" ] && return 1
  tmo $DNS_CHECK_TIMEOUT nslookup "$1" > /dev/null 2>&1
}

# curl の終了コードから原因を決める。
#
# ICMP が通らない = そもそも外へ出られていないので、curl の内訳を問わず
# INET_UNREACHABLE。区別しないと、ルーターの WAN が上がっていないだけの状態
# (SIM ルーターの回線接続待ち等。DNS フォワーダに上流が無いので curl は 6 を返す) を
# DNS_FAILED と誤診し、直るはずのない DHCP RENEW を 6 回打った挙句
# 「name resolution failed」とログに残して次に調べる人を誤導する。
# 代償として、8.8.8.8 と 1.1.1.1 の両方で ICMP が塞がれた環境では本物の DNS 障害を
# INET_UNREACHABLE と呼ぶことになり、dns_recover() が効かなくなる。
#
# 5/6 は「名前解決できなかった」で曖昧さが無い。
#
# 28 (timeout) だけは終了コードから内訳が読めない。resolv.conf に「生きているが
# 応答しないネームサーバ」が載っている状態 (iCamera_app のラッチの一形態や、
# ルーター再起動中の DNS フォワーダ) では 6 ではなく 28 が返る。これを一律
# INET_HTTP_BLOCKED にすると、復旧アクションもリブートも持たない終端状態に落ち、
# DHCP RENEW で解けるはずのラッチが永久に解けない。名前が引けるかを一度だけ
# 別途確かめて振り分ける。
inet_cause_from_curl() {   # $1 = curl の終了コード
  [ "$ICMP_OK" = "1" ] || { echo INET_UNREACHABLE ; return 0 ; }
  case "$1" in
    5|6) echo DNS_FAILED ; return 0 ;;
    28)  dns_resolves "$(origin_host "$HTTP_URL_USED")" || { echo DNS_FAILED ; return 0 ; } ;;
  esac
  echo INET_HTTP_BLOCKED
}

# origin だけが失敗した場合。TLS 系のコードは時計ずれであることが多い。
# ここに来る時点で generate_204 が 204 を返している = 名前解決そのものは生きている。
# したがって 5/6 は「システムの DNS が壊れた」ではなく「origin のホスト名だけが
# 引けなかった」(typo / NXDOMAIN / 社内 DNS 限定のドメイン) を意味する。
# これを DNS_FAILED と呼ぶと INET_STATE に混ざり、直るはずのない DHCP RENEW を
# 6 回打った上で 60 分後にリブートする。必ず ORIGIN_ 接頭辞のまま扱う。
origin_cause_from_curl() {   # $1 = curl の終了コード
  case "$1" in
    5|6) echo ORIGIN_DNS_FAILED ;;
    35|51|53|54|58|59|60|66|77|83) echo ORIGIN_TLS_FAILED ;;
    *)   echo ORIGIN_UNREACHABLE ;;
  esac
}

ntpd_running() {
  [ -n "$(pidof ntpd 2>/dev/null)" ]
}

# 時刻として妥当な範囲か。未同期 (1970) と、明らかに壊れた未来の両方を弾く。
# 外から来た値 (HTTP の Date: ヘッダ等) の検証にも使うので引数を取る。
epoch_sane() {   # $1 = epoch
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge $CLOCK_MIN_EPOCH ] && [ "$1" -le $CLOCK_MAX_EPOCH ]
}

clock_sane() {
  epoch_sane "$(now_epoch)"
}

# ログ1行に収まるように resolv.conf を畳む。中身が空かどうかが最大の情報。
resolv_summary() {
  if [ -s "$RESOLV_CONF" ] ; then
    tr '\n\r\t' '   ' < "$RESOLV_CONF" | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
  else
    echo "<empty>"
  fi
}

wifi_rssi() {
  awk '/wlan0/ {print int($4); exit}' $NET_WIRELESS 2>/dev/null
}

wifi_ssid() {
  wpa status 2>/dev/null | awk -F= '$1=="ssid"{print $2; exit}'
}

# ==================================================================
# 上位レイヤーの判定 (ゲートウェイまで通っている場合のみ実行する)
# ==================================================================

# 判定結果を INET_STATE に入れる。OK か、追加した CAUSE のいずれか。
# public な確認先を必ず先に叩き、origin はその後にしか見ない。
# origin の成否をインターネットの生死判定に使わないのが要点 (要件どおり)。
upper_layers() {
  ICMP_OK=0
  ICMP_HOST_USED=$INET_PING_HOST
  HTTP_URL_USED=$INET_HTTP_URL
  HTTP_CODE=- ; HTTP_CURL=-
  ORIGIN_CODE=- ; ORIGIN_CURL=-
  ORIGIN_STATE=skipped
  # 判定より先に読んでおく。origin 層まで到達しなかった場合でも、どこを見に行く
  # 設定になっているのかは netdiag に残したい。
  # mconfig が無いカメラ (mocula 未設定) では origin 層そのものを判定しない。
  # mocula.sh の既定値へフォールバックすると、無関係なカメラが app.mocula.jp を
  # 叩き続けることになるため。
  ORIGIN_URL=$(origin_url) || ORIGIN_URL=""
  [ -z "$ORIGIN_URL" ] && ORIGIN_STATE=n/a

  probe_icmp && ICMP_OK=1

  if probe_http204 ; then
    INET_STATE=OK
  elif [ "$HTTP_CURL" = "0" ] ; then
    # 接続はできたのに 204 が返らない = 途中の何かが代わりに応答している
    INET_STATE=CAPTIVE_PORTAL
  else
    INET_STATE=$(inet_cause_from_curl "$HTTP_CURL")
  fi

  # --- origin 層 ---
  # インターネットに出られていない時点で origin を叩いても切り分けに寄与しない
  [ "$INET_STATE" = "OK" ] || return 0
  [ -z "$ORIGIN_URL" ] && return 0

  if probe_origin ; then
    ORIGIN_STATE="ok($ORIGIN_CODE)"
  else
    ORIGIN_STATE="FAIL(curl=$ORIGIN_CURL http=$ORIGIN_CODE)"
    INET_STATE=$(origin_cause_from_curl "$ORIGIN_CURL")
  fi
}

# プローブを実行すべきか。正常時に毎分 Google を叩かないための間引き。
# 障害中は間引きを緩め、起動直後 (INET_EARLY_UNTIL 以内) はさらに毎分まで上げる。
inet_due() {
  _at=$(read_int $F_INET_AT)
  [ $_at -eq 0 ] && return 0            # このブートでまだ一度も見ていない
  if [ "$(cat $F_INET 2>/dev/null)" = "OK" ] ; then
    [ $((UPT - _at)) -ge $INET_INTERVAL ]
  elif [ $UPT -lt $INET_EARLY_UNTIL ] ; then
    [ $((UPT - _at)) -ge $INET_FAIL_INTERVAL_EARLY ]
  else
    [ $((UPT - _at)) -ge $INET_FAIL_INTERVAL ]
  fi
}

inet_transition_line() {
  case "$INET_STATE" in
    DNS_FAILED)
      echo "cause=DNS_FAILED : name resolution failed (curl=$HTTP_CURL) : resolv.conf=[$(resolv_summary)] probe=$(origin_host "$HTTP_URL_USED")" ;;
    INET_UNREACHABLE)
      echo "cause=INET_UNREACHABLE : gw=$ROUTER ok but $INET_PING_HOST/$INET_PING_HOST2 both unreachable (router WAN down?) : icmp=fail http_curl=$HTTP_CURL" ;;
    INET_HTTP_BLOCKED)
      echo "cause=INET_HTTP_BLOCKED : $ICMP_HOST_USED reachable, DNS ok, plain HTTP failed on both probes : curl=$HTTP_CURL http=$HTTP_CODE last=$(origin_host "$HTTP_URL_USED")" ;;
    CAPTIVE_PORTAL)
      echo "cause=CAPTIVE_PORTAL : generate_204 returned http=$HTTP_CODE" ;;
    ORIGIN_TLS_FAILED)
      echo "cause=ORIGIN_TLS_FAILED origin=$(origin_host "$ORIGIN_URL") : curl=$ORIGIN_CURL clock=$(date +'%Y/%m/%d %H:%M:%S') (clock suspect)" ;;
    ORIGIN_UNREACHABLE)
      echo "cause=ORIGIN_UNREACHABLE origin=$(origin_host "$ORIGIN_URL") : internet ok (204) but origin curl=$ORIGIN_CURL http=$ORIGIN_CODE" ;;
    ORIGIN_DNS_FAILED)
      echo "cause=ORIGIN_DNS_FAILED origin=$(origin_host "$ORIGIN_URL") : internet ok (204) so system DNS works : this name did not resolve (curl=$ORIGIN_CURL) : resolv.conf=[$(resolv_summary)]" ;;
    *)
      echo "cause=$INET_STATE" ;;
  esac
}

# これまでに打った DHCP RENEW の経緯。ログ行の末尾に付ける。
dns_kick_note() {
  _kn=$(read_int $F_DNSKICK_N)
  if [ $_kn -eq 0 ] ; then
    [ "$INET_STATE" = "DNS_FAILED" ] || echo " (no local action; waiting for upstream)"
    return 0
  fi
  _kcap=""
  [ $_kn -ge $DNS_KICK_MAX ] && _kcap=" capped"
  echo " (dhcp_renew×${_kn}${_kcap}, last=$((UPT - $(read_int $F_DNSKICK)))s ago)"
}

# ==================================================================
# 時刻の復旧
# ==================================================================

# 検証済みの時刻を SD に残す。S42ntpd は起動時に ntp.nict.jp へ届かないと
# /media/mmc/time.ini へフォールバックするが、これまで誰もこのファイルを
# 書いていなかったため死にコードだった。書くようにすると、次のブートで
# ネットワークが上がる前に時計がほぼ正しくなる。
write_time_ini() {
  # 壊れた時計を SD に焼き付けない。clock_from_http() は下限 (CLOCK_MIN_EPOCH) しか
  # 見ていないので、キャプティブポータルが "Date: 2099" を返すとそれが time.ini に
  # 残り、次のブートで S42ntpd が 2099 を復元してしまう。clock_sane は上下限を
  # 両方見るのでここで止まる。
  clock_sane || return 0
  mmc_writable || return 0
  _ti=$(read_int $F_TIMEINI)
  [ $_ti -ne 0 ] && [ $((UPT - _ti)) -lt $TIMEINI_INTERVAL ] && return 0
  echo $UPT > $F_TIMEINI
  echo "utc=$(now_epoch)" > $MMC/time.ini.tmp 2>/dev/null && \
    mv $MMC/time.ini.tmp $MMC/time.ini 2>/dev/null
}

# 平文 HTTP の Date: ヘッダから時刻を取る。TLS を使わないので、時計が狂っていて
# 証明書検証が通らない状態でも必ず取れるのが要点。ntpd で直らない環境
# (UDP 123 が塞がれている等) の最後の手段なので、1 ブートに 1 回だけ。
clock_from_http() {
  [ -f $F_CLOCK_HTTP ] && return 0
  touch $F_CLOCK_HTTP
  # 直前の probe_http204 で実際に 204 を返した方を使う。primary が塞がれている網で
  # わざわざ届かない方から Date: を取りに行っても意味がない。
  _curl_url=${HTTP_URL_USED:-$INET_HTTP_URL}
  _hdr=$(tmo $((INET_HTTP_TIMEOUT + 2)) curl --ipv4 --head --silent \
           --max-time $INET_HTTP_TIMEOUT "$_curl_url" 2>/dev/null |
         awk 'tolower($1) == "date:" { sub(/^[^:]*:[ \t]*/, ""); print; exit }')
  if [ -z "$_hdr" ] ; then
    log "clock: no Date: header from $_curl_url"
    return 1
  fi
  _he=$(echo "$_hdr" | http_date_to_epoch)
  case "$_he" in
    ''|*[!0-9]*) log "clock: unparsable Date: [$_hdr]" ; return 1 ;;
  esac
  # 上限も見る。この Date: はキャプティブポータルや改竄されたプロキシから来ることが
  # あり、下限しか見ないと 2099 のような値をそのまま date -s して、以後この関数は
  # 1 ブート 1 回の制限で二度と走らず、ntpd が届かない環境では復旧手段が尽きる。
  if ! epoch_sane "$_he" ; then
    log "clock: Date: out of range [$_hdr] (epoch=$_he)"
    return 1
  fi
  _before=$(date +'%Y/%m/%d %H:%M:%S')
  if ! set_clock "$_he" ; then
    log "clock: date -s @$_he failed"
    return 1
  fi
  log "clock set from HTTP Date : $_before -> $(date +'%Y/%m/%d %H:%M:%S') (src=$(origin_host "$_curl_url")) : ntpd unusable (UDP123 blocked?)"
  touch $F_CLOCK_OK
  write_time_ini
}

# インターネットに出られることが確認できた直後にだけ呼ぶ。
# busybox 1.24 の ntpd は起動時の名前解決失敗が致命的 (遅延再解決は 1.26 以降) なので、
# DNS が壊れた状態で起動した S42ntpd の常駐 ntpd は死んでいる公算が高い。
# そのため「時計が正しいか」だけでなく「ntpd が生きているか」も見る。
# S42ntpd stop は killall、start は -W 無しの ping と ntpd -qn (時計を設定するまで
# 粘る) なので、同期実行すると数分ブロックしうる。必ず時間制限付きのバックグラウンドで
# 投げ、結果の確認は次の cron 分に回す (スクリプト内で sleep しない -> 設計方針 1)。
ntpd_restart() {
  tmo $NTP_RESTART_TIMEOUT $INITD/S42ntpd restart >> $TMP/log/ntpd.log 2>&1 &
}

clock_recover() {
  # 検証済みでも time.ini の更新だけは続ける。ここで無条件に return していたため
  # TIMEINI_INTERVAL が効かず、time.ini はブートにつき 1 回 (同期した瞬間の値) しか
  # 書かれていなかった。長期稼働すると次のブートで復元される時刻がその分だけ古くなる。
  [ -f $F_CLOCK_OK ] && { write_time_ini ; return 0 ; }

  if clock_sane && ntpd_running ; then
    [ $(read_int $F_NTPN) -gt 0 ] && \
      log "clock synced by ntpd : $(date +'%Y/%m/%d %H:%M:%S') (ntpd pid=$(pidof ntpd))"
    touch $F_CLOCK_OK
    write_time_ini
    return 0
  fi

  _cn=$(read_int $F_NTPN)
  if [ $_cn -lt $NTP_MAX_TRIES ] ; then
    _cl=$(read_int $F_NTPACT)
    [ $_cl -ne 0 ] && [ $((UPT - _cl)) -lt $NTP_RETRY_INTERVAL ] && return 0
    echo $UPT > $F_NTPACT
    echo $((_cn + 1)) > $F_NTPN
    log "cause=CLOCK_UNSYNCED : now=$(date +'%Y/%m/%d %H:%M:%S') epoch=$(now_epoch) ntpd=$(ntpd_running && pidof ntpd || echo dead) : restarting S42ntpd (try $((_cn + 1)))"
    ntpd_restart
    return 0
  fi

  # ntpd では直らない。平文 HTTP の Date: に切り替える
  clock_from_http
}

# ==================================================================
# 上位レイヤーの復旧アクション
# ==================================================================

# DNS だけが壊れている場合の復旧。
# iCamera_app が /tmp/resolv.conf を潰した後、S76mocula のワンショット RENEW が
# 競合に負けると、DHCP のリース更新 (12〜24時間後) まで名前解決が死んだままになる。
# RENEW を打ち直すと resolv.conf が書き直されてラッチが解ける。
# 経路そのものが無い場合 (INET_UNREACHABLE 等) に打っても意味がないので呼ばない。
dns_recover() {
  _n=$(read_int $F_DNSKICK_N)
  # 30 分打って直らないならラッチ以外の原因。続けても他人のルーターへの
  # DHCP ストームにしかならないので打ち止めにする (状況はログに残る)。
  [ $_n -ge $DNS_KICK_MAX ] && return 0
  _last=$(read_int $F_DNSKICK)
  [ $_last -ne 0 ] && [ $((UPT - _last)) -lt $DNS_KICK_INTERVAL ] && return 0
  echo $UPT > $F_DNSKICK
  echo $((_n + 1)) > $F_DNSKICK_N
  kick_dhcp "${IFACE:-wlan0}"
}

# ゲートウェイまでは通っているのにインターネットへ出られない状態が長引いたとき、
# 最後の手段としてリブートする。原因はカメラの外側 (ルーターの WAN) であることが
# 多くリブートでは直らないが、このカメラは SD への録画も LAN 経由の操作も持たない
# ため、リブートを繰り返すことで失うものが無い。回数や経過時間による打ち止めは
# 設けず、繋がるまで再試行し続ける (打ち止め機構そのものが複雑さの元だった)。
#
# $F_INET_SINCE は tmpfs なのでリブートで消える。次のブートでも繋がらなければ
# 障害の開始時刻が引き直され、また $INET_REBOOT 後に落ちる = 約 62 分周期。
inet_reboot_check() {
  case "$INET_STATE" in
    INET_UNREACHABLE|DNS_FAILED) ;;     # リブートで状況が変わりうるのはこの2つだけ
    *) return 0 ;;
  esac
  _since=$(read_int $F_INET_SINCE)
  [ $_since -eq 0 ] && return 0
  _down=$((UPT - _since))
  [ $_down -lt $INET_REBOOT ] && return 0
  [ "$MONITORING_REBOOT" = "off" ] && return 0
  [ -f $MMC/atom-debug ] && return 0

  # tmpfs のログは再起動で消えるので、直前の状態を必ず SD に残してから落とす
  inet_snapshot reboot
  log "cause=$INET_STATE down ${_down}s -> reboot"
  do_reboot
}

# 状態が変わったときと、障害が長引いているときだけ SD に書く。
# 毎分書くと 1 日 1440 行になり、logrotate の 256K を数日で使い切る。
inet_state_machine() {
  _prev=$(cat $F_INET 2>/dev/null)

  if [ "$INET_STATE" != "$_prev" ] ; then
    if [ "$INET_STATE" = "OK" ] ; then
      if [ -n "$_prev" ] && [ "$_prev" != "OK" ] ; then
        _rn=$(read_int $F_DNSKICK_N) ; _rnote=""
        [ $_rn -gt 0 ] && _rnote=" (dhcp_renew×$_rn)"
        # ORIGIN_* は generate_204 が通っていた = インターネットは最初から生きていて
        # origin だけが落ちていた状態。これを "internet recovered" と書くと、
        # ログだけを見た人がルーターや回線を疑って時間を溶かす。原因の切り分けに
        # 効く情報も違う (DNS 系なら resolv.conf、TLS 系なら時計)。
        case "$_prev" in
          ORIGIN_*) _rhead="origin recovered"
                    _rtail="clock=$(date +'%Y/%m/%d %H:%M:%S')" ;;
          *)        _rhead="internet recovered"
                    _rtail="resolv.conf=[$(resolv_summary)]" ;;
        esac
        log "$_rhead : cause=$_prev lasted=$((UPT - $(read_int $F_INET_SINCE)))s$_rnote : $_rtail"
      fi
      rm -f $F_INET_SINCE $F_INET_BEAT $F_DNSKICK $F_DNSKICK_N
    else
      echo $UPT > $F_INET_SINCE
      echo $UPT > $F_INET_BEAT
      # 別の障害へ変わったなら、新しいエピソードとして RENEW の回数をやり直す
      [ -n "$_prev" ] && [ "$_prev" != "OK" ] && rm -f $F_DNSKICK $F_DNSKICK_N
      log "$(inet_transition_line)"
      inet_snapshot inet
    fi
    echo "$INET_STATE" > $F_INET
  elif [ "$INET_STATE" != "OK" ] ; then
    if [ $((UPT - $(read_int $F_INET_BEAT))) -ge $INET_HEARTBEAT ] ; then
      log "cause=$INET_STATE still down : $((UPT - $(read_int $F_INET_SINCE)))s$(dns_kick_note)"
      inet_snapshot inet
      echo $UPT > $F_INET_BEAT
    fi
  fi

  echo $UPT > $F_INET_AT

  # --- 復旧アクション (ログの後。リブートは最後) ---
  # ORIGIN_* は generate_204 が通っている = インターネットには出られている状態。
  # ORIGIN_TLS_FAILED の大半は時計ずれなので、ここで時刻の修復を試みる。
  case "$INET_STATE" in
    OK|ORIGIN_*) clock_recover ;;
  esac
  [ "$INET_STATE" = "DNS_FAILED" ] && dns_recover
  inet_reboot_check
}

# ==================================================================
# リブート
# ==================================================================

# 録画を止めてから落とす (iCamera_app への SIGUSR2 は録画ファイルを閉じさせるため)。
# 呼び出し元へは戻らない。
do_reboot() {
  $SCRIPTS/cmd timelapse stop
  sleep 3
  killall -SIGUSR2 iCamera_app 2>/dev/null
  sync
  release_lock
  reboot
  exit 0
}

# ==================================================================
# 本体
# ==================================================================

main() {

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
probe_gw && NET_OK=1

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

  # --- 上位レイヤー -------------------------------------------------
  # ゲートウェイまでは通っている。その先 (インターネット / 名前解決 / origin) は
  # ここでしか判定しない。下の異常系ブロックとは同一実行で決して同居しないので、
  # エスカレーション用の状態ファイル ($F_DOWN $F_ACT $F_WEDGE $F_HIST) には
  # 一切触らないこと。
  if [ "$MONITORING_NETWORK" != "off" ] && [ -z "$(pidof hostapd)" ] && [ $UPT -ge $BOOT_GRACE ] ; then
    if inet_due ; then
      upper_layers
      inet_state_machine
    fi
    write_summary
  fi
  exit 0
fi

# --- 異常系 ---------------------------------------------------------
# ゲートウェイまで落ちている以上、上位レイヤーのキャッシュは信用できない。
# 復帰した瞬間に取り直させる。
rm -f $F_INET_AT
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

# ゲートウェイまで届いていないブートでも、どの層で止まったかを1行だけ残す
write_summary

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
  do_reboot
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
    kick_dhcp wlan0
    ;;
  *)
    # SCANNING / DISCONNECTED / INACTIVE / 応答なし = 進んでいない
    restart_wifi
    ;;
esac

exit 0

}

main
