#!/bin/busybox ash
#
# health_check.sh のテスト
#
# 実行: busybox ash tests/test_health_check.sh
#
# 方式:
#   health_check.sh は末尾の `main` 呼び出しより前が全て関数定義とパス定義なので、
#   そこだけを awk で切り出して source し、外部コマンドをシェル関数で差し替えてから
#   main を実行する。busybox ash は applet を内部解決するため PATH にスタブを置いても
#   ping/ip/ifconfig/ps/pidof/dmesg には効かない。シェル関数定義は applet より
#   優先されるので、スタブは全て関数オーバーライドで統一する。
#
#   ファイルパスは HC_ROOT で作業ディレクトリ配下へ寄せる (source より前に設定する)。
#   経過時間は HC_UPTIME が指すファイルで制御する。

SCRIPT=$(dirname "$0")/../overlay_rootfs/scripts/health_check.sh
PASS=0
FAIL=0

check() { # desc expected actual
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); echo "  ok   $1"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $1: expected [$2] got [$3]"
  fi
}

FUNCTIONS_FILE=$(mktemp)
awk '/^main$/{exit} {print}' "$SCRIPT" > "$FUNCTIONS_FILE"

# ------------------------------------------------------------------
# 作業ディレクトリ
# ------------------------------------------------------------------

WORK=""

setup() {
  [ -n "$WORK" ] && rm -rf "$WORK"
  WORK=$(mktemp -d)
  mkdir -p "$WORK/proc" "$WORK/tmp/log" "$WORK/media/mmc" "$WORK/configs/etc" \
           "$WORK/scripts" "$WORK/etc/init.d" "$WORK/atom/configs" "$WORK/rec"
  mkdir -p "$WORK/proc/net"
  # 既定は「WiFi は繋がっているが SSID 設定済み」の健全な状態
  printf 'network={\n  ssid="TestAP"\n}\n' > "$WORK/configs/etc/wpa_supplicant.conf"
  printf 'Inter-| sta-|   Quality\n face | link | level\n wlan0: 0000   52.  -52.\n' \
    > "$WORK/proc/net/wireless"
  printf '[global]\ntenantKey=t\ncameraKey=c\norigin=https://app.mocula.jp\n' \
    > "$WORK/media/mmc/mconfig"
  printf 'nameserver 192.168.1.1\n' > "$WORK/tmp/resolv.conf"
  # スタブの挙動を切り替えるフラグ
  STUB_PING_GW=fail          # ok | fail
  STUB_PING_INET=ok          # ok | fail  (8.8.8.8)
  STUB_PING_INET2=""         # 予備 (1.1.1.1)。空なら 8.8.8.8 と同じ挙動
  STUB_HTTP204_CODE=204
  STUB_HTTP204_CURL=0
  STUB_HTTP204_CODE2=""      # 予備 (cp.cloudflare.com)。空なら primary と同じ挙動
  STUB_HTTP204_CURL2=""
  STUB_NSLOOKUP=ok           # ok | fail  (curl 28 の内訳判定に使う)
  STUB_ORIGIN_CODE=200
  STUB_ORIGIN_CURL=0
  # --- 時計フィクスチャ ---
  # ★ health_check.sh と etc/init.d/S42ntpd の CLOCK_MIN_EPOCH より必ず後ろの時刻にすること。
  #    下回ると clock_sane() が常に false になり、時刻系のテストがまとめて落ちる。
  #    あちらを更新したら、ここと tests/test_s42ntpd.sh の CLOCK_EPOCH も同じだけ動かす。
  #    CLOCK_EPOCH_LATE は CLOCK_EPOCH + 2704 秒 (time.ini の書き直しを見るための別値)。
  CLOCK_EPOCH=1788266096          # 2026/09/01 12:34:56 UTC = 正常な時計
  CLOCK_EPOCH_LATE=1788268800     # 2026/09/01 13:20:00 UTC
  CLOCK_HTTP_DATE="Tue, 01 Sep 2026 12:34:56 GMT"   # CLOCK_EPOCH と同じ時刻
  STUB_EPOCH=$CLOCK_EPOCH
  STUB_HTTP_DATE="$CLOCK_HTTP_DATE"
  STUB_NTPD=1421
  STUB_SSID=TestAP           # scan_results に載せる SSID
  STUB_WPA_STATE=COMPLETED
  STUB_SUPPLICANT=111        # pidof wpa_supplicant の戻り値 (空にすると NO_SUPPLICANT)
  STUB_HOSTAPD=""
  STUB_ROUTE="default via 192.168.1.1 dev wlan0"
  STUB_LINK="1: lo
2: wlan0"
  STUB_ADDR="inet addr:192.168.1.50  Mask:255.255.255.0"
}

set_uptime() {
  echo "$1 0.00" > "$WORK/proc/uptime"
}

logfile() { echo "$WORK/media/mmc/healthcheck.log"; }
diagfile() { echo "$WORK/media/mmc/netdiag.log"; }

count_lines() { # file
  [ -f "$1" ] || { echo 0; return; }
  awk 'END{print NR+0}' "$1"
}

count_match() { # file pattern
  # grep -c は不一致でも 0 を出力して 1 を返すので、戻り値だけ握り潰す
  [ -f "$1" ] || { echo 0; return 0; }
  grep -c "$2" "$1" 2>/dev/null
  return 0
}

# ------------------------------------------------------------------
# 実行本体。サブシェルで main を回す (main は exit するため)
# ------------------------------------------------------------------

run_hc() {
  ( HC_ROOT=$WORK
    HC_UPTIME=$WORK/proc/uptime
    . "$FUNCTIONS_FILE"

    # timeout を挟むとオーバーライドしたシェル関数を呼べなくなるので無効化する
    detect_timeout() { TMO=""; }

    ip() {
      case "$1" in
        route) echo "$STUB_ROUTE" ;;
        link)  echo "$STUB_LINK" ;;
      esac
    }

    ifconfig() {
      case "$2" in
        ''|*) [ "$1" = "wlan0" ] && echo "$STUB_ADDR" ;;
      esac
      return 0
    }

    ping() {
      echo "ping $*" >> $WORK/rec/ping
      case "$*" in
        *8.8.8.8*) [ "$STUB_PING_INET" = "ok" ] ;;
        *1.1.1.1*) [ "${STUB_PING_INET2:-$STUB_PING_INET}" = "ok" ] ;;
        *)         [ "$STUB_PING_GW" = "ok" ] ;;
      esac
    }

    # http_code を標準出力に、終了コードを戻り値にする本物と同じ形にする。
    # 時刻取得 (clock_from_http) だけは --head でヘッダを読むので別扱い。
    curl() {
      echo "curl $*" >> $WORK/rec/curl
      case "$*" in
        *generate_204*--head*|*--head*generate_204*)
          printf 'HTTP/1.1 204 No Content\r\nDate: %s\r\n' "$STUB_HTTP_DATE"
          return 0 ;;
        *cp.cloudflare.com*)
          echo "probe" >> $WORK/rec/http204_2
          echo "${STUB_HTTP204_CODE2:-$STUB_HTTP204_CODE}"
          return ${STUB_HTTP204_CURL2:-$STUB_HTTP204_CURL} ;;
        *connectivitycheck.gstatic.com*)
          echo "probe" >> $WORK/rec/http204
          echo "$STUB_HTTP204_CODE" ; return $STUB_HTTP204_CURL ;;
        *)
          echo "probe" >> $WORK/rec/origin
          echo "$STUB_ORIGIN_CODE" ; return $STUB_ORIGIN_CURL ;;
      esac
    }

    nslookup() {
      echo "nslookup $1" >> $WORK/rec/nslookup
      [ "$STUB_NSLOOKUP" = "ok" ] || return 1
      echo "Name: $1"
    }

    now_epoch() { echo "$STUB_EPOCH"; }
    # 本物と同じく、設定したら以後の now_epoch がその値を返すようにする
    set_clock()    { echo "$1" >> $WORK/rec/set_clock; STUB_EPOCH=$1; return 0; }
    ntpd_restart() { echo "restart" >> $WORK/rec/ntpd; }

    pidof() {
      case "$1" in
        wpa_supplicant) [ -n "$STUB_SUPPLICANT" ] && echo "$STUB_SUPPLICANT" ;;
        hostapd)        [ -n "$STUB_HOSTAPD" ] && echo "$STUB_HOSTAPD" ;;
        ntpd)           [ -n "$STUB_NTPD" ] && echo "$STUB_NTPD" ;;
      esac
      return 0
    }

    ps() {
      echo "1122 root     udhcpc -i wlan0 -b"
    }

    wpa() {
      case "$1" in
        status)
          echo "wpa_state=$STUB_WPA_STATE"
          echo "ssid=$STUB_SSID"
          ;;
        scan_results)
          echo "bssid / frequency / signal level / flags / ssid"
          [ -n "$STUB_SSID" ] && \
            printf '00:11:22:33:44:55\t2412\t-50\t[WPA2-PSK-CCMP][ESS]\t%s\n' "$STUB_SSID"
          ;;
      esac
      return 0
    }

    dmesg() { return 0; }
    sync() { return 0; }

    # 副作用のある復旧アクションは全て記録だけして実行しない
    do_reboot()    { echo "reboot" >> $WORK/rec/reboot; exit 0; }
    restart_wifi() { echo "restart_wifi" >> $WORK/rec/restart_wifi; }
    start_wpa()    { echo "start_wpa" >> $WORK/rec/start_wpa; }
    start_dhcp()   { echo "start_dhcp ${1:-wlan0}" >> $WORK/rec/start_dhcp; }
    kick_dhcp()    { echo "kick_dhcp ${1:-wlan0}" >> $WORK/rec/kick_dhcp; }

    main )
}

# ==================================================================
# シナリオ 1: ゲートウェイ断 / cold / 20 分でリブート
# ==================================================================

echo "1. cold mode reboot (COLD_REBOOT=1200s)"
setup
set_uptime 200
run_hc                                  # 障害の起点を記録するだけ
check "1-1 まだリブートしない" 0 "$(count_lines $WORK/rec/reboot)"
check "1-2 cause の詳細行" 1 "$(count_match "$(logfile)" 'cause=GW_UNREACHABLE state=')"
check "1-3 サマリーも1行出る" 1 "$(count_match "$(logfile)" 'summary boot=.*gw=FAIL')"

set_uptime 1500                         # FAILED=1300 >= 1200
run_hc
check "1-4 リブートが1回" 1 "$(count_lines $WORK/rec/reboot)"
check "1-5 リブート直前のログ" 1 "$(count_match "$(logfile)" 'retry error -> reboot')"
check "1-6 netdiag に reboot イベント" 1 "$(count_match "$(diagfile)" 'event=reboot')"
check "1-7 サマリーは増えない" 1 "$(count_match "$(logfile)" 'summary boot=')"

# ==================================================================
# シナリオ 2: 一度疎通した後の切断 / lost / 6 分でリブート
# ==================================================================

echo "2. lost mode reboot (LOST_REBOOT=360s)"
setup
touch "$WORK/tmp/health_check.up"       # 起動後に一度疎通した印
set_uptime 200
run_hc
check "2-1 まだリブートしない" 0 "$(count_lines $WORK/rec/reboot)"

set_uptime 600                          # FAILED=400 >= 360
run_hc
check "2-2 リブートが1回" 1 "$(count_lines $WORK/rec/reboot)"

# cold の閾値 (1200s) より早く落ちていること = lost モードが効いている
setup
set_uptime 200
run_hc
set_uptime 600
run_hc
check "2-3 cold では 600s ではまだ落ちない" 0 "$(count_lines $WORK/rec/reboot)"

# ==================================================================
# シナリオ 3: SSID 未設定はブートにつき 1 行だけ
# ==================================================================

echo "3. SSID_UNCONFIGURED is logged once per boot"
setup
: > "$WORK/configs/etc/wpa_supplicant.conf"   # ssid 行が無い
set_uptime 200
run_hc
set_uptime 260
run_hc
set_uptime 320
run_hc
check "3-1 SSID 未設定ログは1行だけ" 1 "$(count_match "$(logfile)" 'SSID not configured')"
check "3-2 リブートしない" 0 "$(count_lines $WORK/rec/reboot)"
check "3-3 復旧アクションを打たない" 0 "$(count_lines $WORK/rec/restart_wifi)"

# ==================================================================
# シナリオ 4: ロック保持中は何もせず抜ける
# ==================================================================

echo "4. lock held by a live process"
setup
mkdir -p "$WORK/tmp/health_check.lock"
echo $$ > "$WORK/tmp/health_check.lock/pid"   # このテストプロセス = 生きている
set_uptime 1500
echo 1500 > "$WORK/tmp/health_check.lock/at"
run_hc
check "4-1 ログを書かない" 0 "$(count_lines "$(logfile)")"
check "4-2 リブートしない" 0 "$(count_lines $WORK/rec/reboot)"

# 古いロック (age >= 300s) は乗っ取る
setup
mkdir -p "$WORK/tmp/health_check.lock"
echo 999999 > "$WORK/tmp/health_check.lock/pid"   # 存在しない PID
echo 100 > "$WORK/tmp/health_check.lock/at"
set_uptime 1500
run_hc
check "4-3 stale lock を乗っ取る" 1 "$(count_match "$(logfile)" 'stale lock')"

# ==================================================================
# シナリオ 5: BOOT_GRACE 中は SD に一切書かない
# ==================================================================

echo "5. no SD writes during BOOT_GRACE"
setup
set_uptime 60                           # < BOOT_GRACE(120)
run_hc
check "5-1 healthcheck.log が無い" 0 "$(count_lines "$(logfile)")"
check "5-2 netdiag.log が無い" 0 "$(count_lines "$(diagfile)")"
check "5-3 ブート通番を進めない" 0 "$(count_lines $WORK/media/mmc/.health_boot)"

check "5-4 F_UP は作られない" 0 "$([ -f $WORK/tmp/health_check.up ] && echo 1 || echo 0)"

# ==================================================================
# シナリオ 6: origin_url() / origin_host() 単体
# ==================================================================

echo "6. origin_url() / origin_host()"
setup

# 純粋関数なのでサブシェルで直接呼ぶ
origin_of() { # mconfig の中身を stdin から受け取り、origin_url の結果を返す
  cat > "$WORK/media/mmc/mconfig"
  ( HC_ROOT=$WORK ; . "$FUNCTIONS_FILE" ; origin_url || echo "<invalid>" )
}

check "6-1 通常" "https://qa1.mocula-dev.com" "$(printf '[global]\ntenantKey=t\norigin=https://qa1.mocula-dev.com\n' | origin_of)"
check "6-2 origin 未設定なら既定値" "https://app.mocula.jp" "$(printf '[global]\ntenantKey=t\n' | origin_of)"
check "6-3 [global] が無ければ既定値" "https://app.mocula.jp" "$(printf 'origin=https://evil.example\n' | origin_of)"
check "6-4 別セクションの origin は拾わない" "https://app.mocula.jp" "$(printf '[global]\nt=1\n[firmware]\norigin=https://evil.example\n' | origin_of)"
check "6-5 前後の空白と CR を落とす" "https://app.mocula.jp" "$(printf '[global]\r\norigin =  https://app.mocula.jp  \r\n' | origin_of)"
check "6-6 ポートとパス" "https://x.example:8443/base" "$(printf '[global]\norigin=https://x.example:8443/base\n' | origin_of)"
# origin は camera-sync の URL の前半として使うだけなのでクエリ文字は許可しない。
# 値そのものは最初の = より後ろを全部拾えている (弾いているのは文字種検査)。
check "6-6b = を含む値は弾く" "<invalid>" "$(printf '[global]\norigin=https://x.example/a=b\n' | origin_of)"
check "6-7 コマンド置換は弾く" "<invalid>" "$(printf '[global]\norigin=https://x`touch %s/PWNED`\n' "$WORK" | origin_of)"
check "6-8 セミコロンは弾く" "<invalid>" "$(printf '[global]\norigin=https://x;touch %s/PWNED\n' "$WORK" | origin_of)"
check "6-9 空白入りは弾く" "<invalid>" "$(printf '[global]\norigin=https://x y\n' | origin_of)"
check "6-10 PWNED が作られていない" 0 "$([ -f "$WORK/PWNED" ] && echo 1 || echo 0)"

rm -f "$WORK/media/mmc/mconfig"
check "6-11 mconfig 無しは失敗" "<invalid>" "$( ( HC_ROOT=$WORK ; . "$FUNCTIONS_FILE" ; origin_url || echo '<invalid>' ) )"

host_of() { ( HC_ROOT=$WORK ; . "$FUNCTIONS_FILE" ; origin_host "$1" ); }
check "6-12 host: https" "app.mocula.jp" "$(host_of https://app.mocula.jp)"
check "6-13 host: パス付き" "app.mocula.jp" "$(host_of https://app.mocula.jp/api/v1)"
check "6-14 host: ポート付き" "x.example:8443" "$(host_of https://x.example:8443/a)"
check "6-15 host: スキーム無し" "app.mocula.jp" "$(host_of app.mocula.jp)"

# ==================================================================
# シナリオ 7: http_date_to_epoch() 単体
# ==================================================================

echo "7. http_date_to_epoch()"

epoch_of() { ( HC_ROOT=$WORK ; . "$FUNCTIONS_FILE" ; printf '%s' "$1" | http_date_to_epoch ); }

# 7-1 と 7-6 はフィクスチャの組を使う。CLOCK_EPOCH と CLOCK_HTTP_DATE が
# 同じ時刻を指しているかの検算も兼ねている (片方だけ更新するとここで落ちる)。
check "7-1 通常"           "$CLOCK_EPOCH" "$(epoch_of "$CLOCK_HTTP_DATE")"
check "7-2 epoch 0"        "0"          "$(epoch_of 'Thu, 01 Jan 1970 00:00:00 GMT')"
check "7-3 閏日"           "1709251199" "$(epoch_of 'Thu, 29 Feb 2024 23:59:59 GMT')"
check "7-4 年末"           "1767225599" "$(epoch_of 'Wed, 31 Dec 2025 23:59:59 GMT')"
check "7-5 1桁の日"        "1767916800" "$(epoch_of 'Fri, 09 Jan 2026 00:00:00 GMT')"
check "7-6 末尾 CR"        "$CLOCK_EPOCH" "$(epoch_of "$CLOCK_HTTP_DATE
")"
check "7-7 空入力"         ""           "$(epoch_of '')"
check "7-8 フィールド不足" ""           "$(epoch_of 'Sun, 10 Aug')"
check "7-9 月名が不正"     ""           "$(epoch_of 'Sun, 10 Xxx 2026 12:34:56 GMT')"
check "7-10 時刻が不正"    ""           "$(epoch_of 'Sun, 10 Aug 2026 99:34:56 GMT')"
check "7-11 年が範囲外"    ""           "$(epoch_of 'Sun, 10 Aug 1900 12:34:56 GMT')"
check "7-12 ゴミ"          ""           "$(epoch_of 'not a date at all here')"

# ==================================================================
# シナリオ 8: 全レイヤー正常なブート
# ==================================================================

echo "8. healthy boot writes exactly one summary line"
setup
STUB_PING_GW=ok
set_uptime 130
run_hc
check "8-1 ログはちょうど1行" 1 "$(count_lines "$(logfile)")"
check "8-2 全レイヤー ok" 1 "$(count_match "$(logfile)" 'summary boot=1 iface=wlan0 wifi=ok(ssid="TestAP" rssi=-52) gw=ok(192.168.1.1) inet=ok dns=ok origin=ok(200) clock=ok')"
check "8-3 ブート通番が1" 1 "$(cat $WORK/media/mmc/.health_boot)"
check "8-4 public プローブを1回" 1 "$(count_lines $WORK/rec/http204)"
check "8-5 origin プローブを1回" 1 "$(count_lines $WORK/rec/origin)"

# 間隔 (600s) 以内は叩き直さない
set_uptime 400
run_hc
check "8-6 間隔内は再プローブしない" 1 "$(count_lines $WORK/rec/http204)"
check "8-7 ログは増えない" 1 "$(count_lines "$(logfile)")"

set_uptime 800                          # 130 + 600 <= 800
run_hc
check "8-8 間隔を過ぎたら再プローブ" 2 "$(count_lines $WORK/rec/http204)"
check "8-9 正常が続く限りログは増えない" 1 "$(count_lines "$(logfile)")"

# mconfig が無いカメラは origin 層を判定しない
setup
STUB_PING_GW=ok
rm -f "$WORK/media/mmc/mconfig"
set_uptime 130
run_hc
check "8-10 origin は n/a" 1 "$(count_match "$(logfile)" 'inet=ok dns=ok origin=n/a')"
check "8-11 origin を叩かない" 0 "$(count_lines $WORK/rec/origin)"
check "8-12 ログはちょうど1行" 1 "$(count_lines "$(logfile)")"

# ルーターより先に起動したケース。異常系が先にサマリーを書くが、その後
# ルーターが上がって 5 層を判定できたら 1 度だけ上書きする (最大 2 行)。
setup
set_uptime 130 ; run_hc                 # gw 断。暫定サマリー
check "8-13 暫定は inet=skipped" 1 "$(count_match "$(logfile)" 'summary .* inet=skipped')"
STUB_PING_GW=ok
set_uptime 200 ; run_hc                 # ルーターが上がった
check "8-14 確定サマリーで上書き" 1 "$(count_match "$(logfile)" 'summary .* inet=ok dns=ok origin=ok(200)')"
check "8-15 サマリーは2行まで" 2 "$(count_match "$(logfile)" 'summary boot=')"
set_uptime 900 ; run_hc                 # 再プローブの間隔を跨いでも増やさない
set_uptime 1600 ; run_hc
check "8-16 確定後は増えない" 2 "$(count_match "$(logfile)" 'summary boot=')"
check "8-17 ブート通番は加算しない" 1 "$(cat $WORK/media/mmc/.health_boot)"

# ゲートウェイに一度も届かないブートでは上書きの経路に入らない (1行のまま)
setup
set_uptime 130 ; run_hc
set_uptime 200 ; run_hc
set_uptime 400 ; run_hc
check "8-18 gw 断が続けばサマリーは1行" 1 "$(count_match "$(logfile)" 'summary boot=')"

# ==================================================================
# シナリオ 9: ゲートウェイ OK / DNS 断 (今回のバグ)
# ==================================================================

echo "9. gateway ok but DNS broken"
setup
STUB_PING_GW=ok
STUB_HTTP204_CURL=6                     # couldn't resolve host
STUB_HTTP204_CODE=000
STUB_ORIGIN_CURL=6
STUB_ORIGIN_CODE=000
: > "$WORK/tmp/resolv.conf"             # iCamera_app に潰された状態
set_uptime 130
run_hc
check "9-1 DNS_FAILED を記録" 1 "$(count_match "$(logfile)" 'cause=DNS_FAILED : name resolution failed (curl=6)')"
check "9-2 resolv.conf の中身を残す" 1 "$(count_match "$(logfile)" 'resolv.conf=\[<empty>\]')"
check "9-3 netdiag に inet イベント" 1 "$(count_match "$(diagfile)" 'event=inet cause=DNS_FAILED')"
check "9-4 サマリーは dns=FAILED" 1 "$(count_match "$(logfile)" 'inet=ok dns=FAILED origin=skipped')"
check "9-5 origin は叩かない" 0 "$(count_lines $WORK/rec/origin)"
check "9-6 リブートしない" 0 "$(count_lines $WORK/rec/reboot)"

# 同じ状態が続いている間は書き足さない
_before=$(count_lines "$(logfile)")
set_uptime 300
run_hc
set_uptime 500
run_hc
check "9-7 状態が変わらなければ書かない" "$_before" "$(count_lines "$(logfile)")"

# ハートビート (1800s)
set_uptime 2000
run_hc
check "9-8 ハートビートを1行" 1 "$(count_match "$(logfile)" 'cause=DNS_FAILED still down')"

# 復旧
STUB_HTTP204_CURL=0 ; STUB_HTTP204_CODE=204
STUB_ORIGIN_CURL=0 ; STUB_ORIGIN_CODE=200
printf 'nameserver 192.168.1.1\n' > "$WORK/tmp/resolv.conf"
set_uptime 2200
run_hc
check "9-9 復旧を記録" 1 "$(count_match "$(logfile)" 'internet recovered : cause=DNS_FAILED lasted=2070s')"
check "9-10 復旧後は静か" 0 "$(count_match "$(logfile)" 'still down : 2')"

# ==================================================================
# シナリオ 10: 各 cause の分類
# ==================================================================

echo "10. cause classification"

probe_case() { # ping_inet http_curl http_code origin_curl origin_code -> cause
  setup
  STUB_PING_GW=ok
  STUB_PING_INET=$1
  STUB_HTTP204_CURL=$2 ; STUB_HTTP204_CODE=$3
  STUB_ORIGIN_CURL=$4  ; STUB_ORIGIN_CODE=$5
  set_uptime 130
  run_hc
  sed -n 's/.*cause=\([A-Z_]*\).*/\1/p' "$(logfile)" | head -1
}

check "10-1 ルータ WAN 断"      "INET_UNREACHABLE"   "$(probe_case fail 7 000 7 000)"
check "10-2 ICMP 遮断 + HTTP 断" "INET_HTTP_BLOCKED" "$(probe_case ok 28 000 28 000)"
check "10-3 DNS 断"             "DNS_FAILED"         "$(probe_case ok 6 000 6 000)"
check "10-4 キャプティブポータル" "CAPTIVE_PORTAL"    "$(probe_case ok 0 302 0 200)"
check "10-5 origin 到達不能"     "ORIGIN_UNREACHABLE" "$(probe_case ok 0 204 7 000)"
check "10-6 origin TLS 失敗"     "ORIGIN_TLS_FAILED"  "$(probe_case ok 0 204 60 000)"
# origin のホスト名だけが引けない。204 が通っている以上システムの DNS は生きている
check "10-7 origin 名前解決失敗" "ORIGIN_DNS_FAILED"  "$(probe_case ok 0 204 6 000)"

# ICMP が落ちていても HTTP 204 が通ればインターネットは OK
setup
STUB_PING_GW=ok ; STUB_PING_INET=fail
set_uptime 130
run_hc
check "10-8 ICMP 遮断環境でも OK" 1 "$(count_match "$(logfile)" 'inet=ok dns=ok origin=ok(200)')"

# origin の 5xx は「経路は通っている」ので障害にしない
setup
STUB_PING_GW=ok ; STUB_ORIGIN_CODE=503
set_uptime 130
run_hc
check "10-9 origin 5xx は OK 扱い" 1 "$(count_match "$(logfile)" 'origin=ok(503)')"
check "10-10 5xx で cause を出さない" 0 "$(count_match "$(logfile)" 'cause=')"

# ==================================================================
# シナリオ 11: ゲート (hostapd / MONITORING_NETWORK / BOOT_GRACE)
# ==================================================================

echo "11. gates"
setup
STUB_PING_GW=ok ; STUB_HOSTAPD=222      # ペアリング中
set_uptime 130
run_hc
check "11-1 hostapd 中はプローブしない" 0 "$(count_lines $WORK/rec/http204)"
check "11-2 hostapd 中は SD に書かない" 0 "$(count_lines "$(logfile)")"

setup
STUB_PING_GW=ok
echo "MONITORING_NETWORK=off" > "$WORK/tmp/hack.ini"
set_uptime 130
run_hc
check "11-3 監視 off でプローブしない" 0 "$(count_lines $WORK/rec/http204)"
check "11-4 監視 off で SD に書かない" 0 "$(count_lines "$(logfile)")"

setup
STUB_PING_GW=ok
set_uptime 60                           # BOOT_GRACE 中
run_hc
check "11-5 BOOT_GRACE 中はプローブしない" 0 "$(count_lines $WORK/rec/http204)"
check "11-6 BOOT_GRACE 中は SD に書かない" 0 "$(count_lines "$(logfile)")"

# SD が無くてもプローブ自体は走る (自己修復は効くが報告できないだけ)
setup
STUB_PING_GW=ok ; STUB_HTTP204_CURL=6
rm -rf "$WORK/media/mmc"
set_uptime 130
run_hc
check "11-7 SD 無しでもプローブする" 1 "$(count_lines $WORK/rec/http204)"

# ==================================================================
# シナリオ 12: USB-Ethernet 機
# ==================================================================

echo "12. USB-Ethernet camera"
setup
STUB_PING_GW=ok
STUB_ROUTE="default via 192.168.1.1 dev eth0"
STUB_LINK="1: lo
2: eth0"
set_uptime 130
run_hc
check "12-1 wifi は n/a" 1 "$(count_match "$(logfile)" 'iface=eth0 wifi=n/a')"
check "12-2 上位レイヤーは通常どおり" 1 "$(count_match "$(logfile)" 'inet=ok dns=ok origin=ok(200)')"

# ==================================================================
# シナリオ 13: ゲートウェイ障害を挟んだ復帰
# ==================================================================

echo "13. re-probe immediately after a gateway outage"
setup
STUB_PING_GW=ok
set_uptime 130
run_hc
check "13-1 初回プローブ" 1 "$(count_lines $WORK/rec/http204)"

STUB_PING_GW=fail                       # ゲートウェイ断
set_uptime 200
run_hc
STUB_PING_GW=ok                         # すぐ復帰 (INET_INTERVAL には遠く及ばない)
set_uptime 260
run_hc
check "13-2 復帰直後に取り直す" 2 "$(count_lines $WORK/rec/http204)"

# ==================================================================
# シナリオ 14: DNS 断からの復旧 (DHCP RENEW)
# ==================================================================

echo "14. DNS latch recovery via DHCP renew"
setup
STUB_PING_GW=ok
STUB_HTTP204_CURL=6 ; STUB_HTTP204_CODE=000
: > "$WORK/tmp/resolv.conf"
set_uptime 130
run_hc
check "14-1 RENEW を1回打つ" 1 "$(count_lines $WORK/rec/kick_dhcp)"
check "14-2 対象は default route の iface" "kick_dhcp wlan0" "$(head -1 $WORK/rec/kick_dhcp)"

set_uptime 300                          # 300s 未満の間隔
run_hc
check "14-3 間隔内は打ち直さない" 1 "$(count_lines $WORK/rec/kick_dhcp)"

set_uptime 440                          # 130 + 300 <= 440
run_hc
check "14-4 間隔を過ぎたら2回目" 2 "$(count_lines $WORK/rec/kick_dhcp)"

# 上限 (6回) まで打ったら止まる
set_uptime 750  ; run_hc
set_uptime 1060 ; run_hc
set_uptime 1370 ; run_hc
set_uptime 1680 ; run_hc
check "14-5 上限は6回" 6 "$(count_lines $WORK/rec/kick_dhcp)"
set_uptime 2000 ; run_hc
check "14-6 上限後は打たない" 6 "$(count_lines $WORK/rec/kick_dhcp)"
check "14-7 ハートビートに capped" 1 "$(count_match "$(logfile)" 'dhcp_renew×6 capped')"

# 復旧するとカウンタがリセットされる
STUB_HTTP204_CURL=0 ; STUB_HTTP204_CODE=204
printf 'nameserver 192.168.1.1\n' > "$WORK/tmp/resolv.conf"
set_uptime 2200 ; run_hc
check "14-8 復旧ログに RENEW 回数" 1 "$(count_match "$(logfile)" 'internet recovered : cause=DNS_FAILED lasted=2070s (dhcp_renew×6)')"
check "14-9 カウンタが消える" 0 "$([ -f $WORK/tmp/health_check.dnskick_n ] && echo 1 || echo 0)"

# DNS 以外では RENEW を打たない
setup
STUB_PING_GW=ok ; STUB_PING_INET=fail
STUB_HTTP204_CURL=7 ; STUB_HTTP204_CODE=000
set_uptime 130 ; run_hc
check "14-10 INET_UNREACHABLE では打たない" 0 "$(count_lines $WORK/rec/kick_dhcp)"

# USB-Ethernet 機では eth0 に打つ (存在しない wlan0 に udhcpc を生やさない)
setup
STUB_PING_GW=ok
STUB_ROUTE="default via 192.168.1.1 dev eth0"
STUB_LINK="1: lo
2: eth0"
STUB_HTTP204_CURL=6 ; STUB_HTTP204_CODE=000
set_uptime 130 ; run_hc
check "14-11 eth0 に RENEW" "kick_dhcp eth0" "$(head -1 $WORK/rec/kick_dhcp)"

# ==================================================================
# シナリオ 15: 上位レイヤー起因のリブートとループ防止
# ==================================================================

echo "15. upper-layer reboot and loop guard"

inet_down_until() { # uptime まで INET_UNREACHABLE を継続させる
  setup
  STUB_PING_GW=ok ; STUB_PING_INET=fail
  STUB_HTTP204_CURL=7 ; STUB_HTTP204_CODE=000
  set_uptime 130 ; run_hc
}

inet_down_until
set_uptime 3700                         # down=3570s < 3600
run_hc
check "15-1 60分未満ではリブートしない" 0 "$(count_lines $WORK/rec/reboot)"

# 障害中の再確認は 120s 間隔なので、閾値超過の次の確認タイミングで落ちる
set_uptime 3830                         # down=3700s >= 3600、前回確認から 130s
run_hc
check "15-2 60分でリブート" 1 "$(count_lines $WORK/rec/reboot)"
check "15-3 リブート行を記録" 1 "$(count_match "$(logfile)" 'cause=INET_UNREACHABLE down 3700s -> reboot')"
check "15-4 netdiag に reboot イベント" 1 "$(count_match "$(diagfile)" 'event=reboot cause=INET_UNREACHABLE')"

# 打ち止めは設けない。繋がるまで何度でも落とす (SD 録画も LAN 操作も無いため)。
# tmpfs を消して再起動を模擬し、同じ条件で再び落ちることを確認する。
simulate_reboot() { rm -f "$WORK"/tmp/health_check.* ; rm -rf "$WORK"/tmp/health_check.lock ; }

_i=0
while [ $_i -lt 5 ] ; do
  simulate_reboot
  set_uptime 130 ; run_hc
  set_uptime 3830 ; run_hc
  _i=$((_i + 1))
done
check "15-5 再起動を跨いで毎回落とす" 6 "$(count_lines $WORK/rec/reboot)"
check "15-6 打ち止めのログは出ない" 0 "$(count_match "$(logfile)" 'suppressed')"

# 抑止スイッチ
inet_down_until
echo "MONITORING_REBOOT=off" > "$WORK/tmp/hack.ini"
set_uptime 3800 ; run_hc
check "15-9 MONITORING_REBOOT=off で抑止" 0 "$(count_lines $WORK/rec/reboot)"

inet_down_until
touch "$WORK/media/mmc/atom-debug"
set_uptime 3800 ; run_hc
check "15-10 atom-debug で抑止" 0 "$(count_lines $WORK/rec/reboot)"

# SD が無くてもリブートはする。以前は「連続回数を数えられない = ループを検出
# できない」ため抑止していたが、打ち止め自体を廃止したので理由が消えた。
# ログが残らないだけで、復旧を試みる動作は SD の有無に依存させない
# (wifi 層のリブートも同じく SD を要求していない)。
inet_down_until
rm -rf "$WORK/media/mmc"
set_uptime 3830 ; run_hc
check "15-11 SD 無しでもリブートする" 1 "$(count_lines $WORK/rec/reboot)"

# インターネット層以外ではリブートしない
setup
STUB_PING_GW=ok ; STUB_ORIGIN_CURL=7 ; STUB_ORIGIN_CODE=000
set_uptime 130 ; run_hc
set_uptime 3800 ; run_hc
check "15-12 ORIGIN_UNREACHABLE では落とさない" 0 "$(count_lines $WORK/rec/reboot)"

setup
STUB_PING_GW=ok ; STUB_HTTP204_CURL=0 ; STUB_HTTP204_CODE=302
set_uptime 130 ; run_hc
set_uptime 3800 ; run_hc
check "15-13 CAPTIVE_PORTAL では落とさない" 0 "$(count_lines $WORK/rec/reboot)"

# origin のホスト名だけが引けない場合。generate_204 が 204 を返している以上
# システムの DNS は生きているので、DHCP RENEW もリブートも打ってはいけない。
setup
STUB_PING_GW=ok ; STUB_ORIGIN_CURL=6 ; STUB_ORIGIN_CODE=000
set_uptime 130 ; run_hc
check "15-14 ORIGIN_DNS_FAILED と分類" 1 "$(count_match "$(logfile)" 'cause=ORIGIN_DNS_FAILED origin=app.mocula.jp')"
check "15-15 DNS_FAILED と誤診しない" 0 "$(count_match "$(logfile)" 'cause=DNS_FAILED')"
check "15-16 DHCP RENEW を打たない" 0 "$(count_lines $WORK/rec/kick_dhcp)"
set_uptime 3800 ; run_hc
check "15-17 60分続いてもリブートしない" 0 "$(count_lines $WORK/rec/reboot)"

# ==================================================================
# シナリオ 16: 時刻同期
# ==================================================================

echo "16. clock recovery"

# 時計が狂っていて ntpd も死んでいる = 起動時に DNS が壊れていた典型
setup
STUB_PING_GW=ok
STUB_EPOCH=133                          # 1970/01/01
STUB_NTPD=""                            # ntpd は起動時に即死している
STUB_ORIGIN_CURL=60 ; STUB_ORIGIN_CODE=000   # 証明書が not yet valid
set_uptime 130 ; run_hc
check "16-1 ORIGIN_TLS_FAILED" 1 "$(count_match "$(logfile)" 'cause=ORIGIN_TLS_FAILED origin=.* : curl=60')"
check "16-2 CLOCK_UNSYNCED を記録" 1 "$(count_match "$(logfile)" 'cause=CLOCK_UNSYNCED.*restarting S42ntpd (try 1)')"
check "16-3 S42ntpd を1回呼ぶ" 1 "$(count_lines $WORK/rec/ntpd)"
check "16-4 サマリーは clock=unsynced" 1 "$(count_match "$(logfile)" 'clock=unsynced')"

# 900s 以内は再試行しない
set_uptime 400 ; run_hc
check "16-5 間隔内は再試行しない" 1 "$(count_lines $WORK/rec/ntpd)"

set_uptime 1100 ; run_hc                # 130 + 900 <= 1100
check "16-6 2回目の再起動" 2 "$(count_lines $WORK/rec/ntpd)"

# 上限に達したら HTTP Date へ落ちる
set_uptime 2100 ; run_hc
check "16-7 S42ntpd は2回まで" 2 "$(count_lines $WORK/rec/ntpd)"
check "16-8 HTTP Date で時刻を設定" "$CLOCK_EPOCH" "$(head -1 $WORK/rec/set_clock)"
check "16-9 ログに残す" 1 "$(count_match "$(logfile)" 'clock set from HTTP Date')"
check "16-10 補正後の時刻で time.ini" "utc=$CLOCK_EPOCH" "$(cat $WORK/media/mmc/time.ini)"

# HTTP Date は1ブート1回だけ
set_uptime 3100 ; run_hc
check "16-11 HTTP Date は1回だけ" 1 "$(count_lines $WORK/rec/set_clock)"

# ntpd が時計を直したケース
setup
STUB_PING_GW=ok
STUB_EPOCH=133 ; STUB_NTPD=""
set_uptime 130 ; run_hc
check "16-12 まず S42ntpd を試す" 1 "$(count_lines $WORK/rec/ntpd)"
STUB_EPOCH=$CLOCK_EPOCH ; STUB_NTPD=1421  # ntpd が復活して時計を直した
set_uptime 1100 ; run_hc
check "16-13 同期を記録" 1 "$(count_match "$(logfile)" 'clock synced by ntpd')"
check "16-14 以降 S42ntpd を呼ばない" 1 "$(count_lines $WORK/rec/ntpd)"
check "16-15 HTTP Date に落ちない" 0 "$(count_lines $WORK/rec/set_clock)"
check "16-16 time.ini を書く" "utc=$CLOCK_EPOCH" "$(cat $WORK/media/mmc/time.ini)"

# 最初から健全なら何もしない
setup
STUB_PING_GW=ok
set_uptime 130 ; run_hc
check "16-17 健全なら S42ntpd を触らない" 0 "$(count_lines $WORK/rec/ntpd)"
check "16-18 同期ログを出さない" 0 "$(count_match "$(logfile)" 'clock synced')"
check "16-19 time.ini は書く" "utc=$CLOCK_EPOCH" "$(cat $WORK/media/mmc/time.ini)"

# インターネットに出られていないなら時計に触らない (Date: も取れない)
setup
STUB_PING_GW=ok ; STUB_PING_INET=fail
STUB_HTTP204_CURL=7 ; STUB_HTTP204_CODE=000
STUB_EPOCH=133 ; STUB_NTPD=""
set_uptime 130 ; run_hc
check "16-20 インターネット断では時計に触らない" 0 "$(count_lines $WORK/rec/ntpd)"

# time.ini は同期した瞬間だけでなく TIMEINI_INTERVAL ごとに更新する。
# (clock_recover が F_CLOCK_OK で無条件 return していた頃はブート 1 回きりだった)
setup
STUB_PING_GW=ok
set_uptime 130 ; run_hc
check "16-21 同期時に time.ini" "utc=$CLOCK_EPOCH" "$(cat $WORK/media/mmc/time.ini)"

STUB_EPOCH=$CLOCK_EPOCH_LATE
set_uptime 3000 ; run_hc                # 130 + 3600 > 3000
check "16-22 間隔内は書き直さない" "utc=$CLOCK_EPOCH" "$(cat $WORK/media/mmc/time.ini)"

set_uptime 3800 ; run_hc                # 130 + 3600 <= 3800
check "16-23 間隔を過ぎたら書き直す" "utc=$CLOCK_EPOCH_LATE" "$(cat $WORK/media/mmc/time.ini)"

# 壊れた時計を SD に焼き付けない (次のブートで S42ntpd が復元してしまうため)
STUB_EPOCH=133                          # 1970。CLOCK_MIN_EPOCH 未満
set_uptime 7500 ; run_hc                # 3800 + 3600 <= 7500
check "16-24 未同期の時計では上書きしない" "utc=$CLOCK_EPOCH_LATE" "$(cat $WORK/media/mmc/time.ini)"

STUB_EPOCH=4090048496                   # 2099。CLOCK_MAX_EPOCH 超過
set_uptime 11500 ; run_hc
check "16-25 未来すぎる時計でも上書きしない" "utc=$CLOCK_EPOCH_LATE" "$(cat $WORK/media/mmc/time.ini)"

# HTTP Date は上下限を見る。キャプティブポータルや改竄されたプロキシが返す
# 壊れた時刻をそのまま date -s すると、1 ブート 1 回の制限で復旧手段が尽きる。
http_date_case() { # Date: ヘッダ -> clock_from_http まで到達させる
  setup
  STUB_PING_GW=ok
  STUB_EPOCH=133 ; STUB_NTPD=""
  STUB_ORIGIN_CURL=60 ; STUB_ORIGIN_CODE=000
  STUB_HTTP_DATE="$1"
  set_uptime 130  ; run_hc              # S42ntpd 再起動 1 回目
  set_uptime 1100 ; run_hc              # 2 回目
  set_uptime 2100 ; run_hc              # 上限に達して HTTP Date へ
}

http_date_case "Sun, 10 Aug 2099 12:34:56 GMT"
check "16-26 未来すぎる Date は適用しない" 0 "$(count_lines $WORK/rec/set_clock)"
check "16-27 範囲外をログに残す" 1 "$(count_match "$(logfile)" 'clock: Date: out of range')"
check "16-28 time.ini を汚さない" 0 "$([ -f $WORK/media/mmc/time.ini ] && echo 1 || echo 0)"

http_date_case "Thu, 01 Jan 1970 00:00:00 GMT"
check "16-29 古すぎる Date も適用しない" 0 "$(count_lines $WORK/rec/set_clock)"

http_date_case "$CLOCK_HTTP_DATE"
check "16-30 範囲内なら従来どおり適用する" 1 "$(count_lines $WORK/rec/set_clock)"

# ==================================================================
# シナリオ 19: origin だけの障害からの復帰
#
# ORIGIN_* は generate_204 が通っていた = インターネットは落ちていない。
# "internet recovered" と書くと、ログだけを見た人が回線を疑うことになる。
# ==================================================================

echo "19. origin-only recovery wording"

setup
STUB_PING_GW=ok
STUB_ORIGIN_CURL=60 ; STUB_ORIGIN_CODE=000
STUB_EPOCH=133 ; STUB_NTPD=""
set_uptime 130 ; run_hc
STUB_ORIGIN_CURL=0 ; STUB_ORIGIN_CODE=200      # 時計が直って TLS が通った
STUB_EPOCH=$CLOCK_EPOCH ; STUB_NTPD=1421
set_uptime 300 ; run_hc
check "19-1 origin recovered と書く" 1 "$(count_match "$(logfile)" 'origin recovered : cause=ORIGIN_TLS_FAILED lasted=170s')"
check "19-2 internet recovered とは書かない" 0 "$(count_match "$(logfile)" 'internet recovered')"
check "19-3 切り分けに効く時計を出す" 1 "$(count_match "$(logfile)" 'origin recovered.*: clock=')"
check "19-4 resolv.conf は出さない" 0 "$(count_match "$(logfile)" 'origin recovered.*resolv.conf')"

# インターネットが本当に落ちていた場合は従来どおり
setup
STUB_PING_GW=ok ; STUB_PING_INET=fail
STUB_HTTP204_CURL=7 ; STUB_HTTP204_CODE=000
set_uptime 130 ; run_hc
STUB_PING_INET=ok ; STUB_HTTP204_CURL=0 ; STUB_HTTP204_CODE=204
set_uptime 300 ; run_hc
check "19-5 internet recovered のまま" 1 "$(count_match "$(logfile)" 'internet recovered : cause=INET_UNREACHABLE lasted=170s')"
check "19-6 resolv.conf を出す" 1 "$(count_match "$(logfile)" 'internet recovered.*resolv.conf=\[nameserver')"

# ==================================================================
# シナリオ 17: WAN 断と DNS 断の切り分け
#
# SIM ルーター等で「WiFi/DHCP は早いが回線接続が遅い」場合、DNS フォワーダに
# 上流が無いため curl は 6 (couldn't resolve host) を返す。これを DNS_FAILED と
# 誤診すると、直るはずのない DHCP RENEW を打ち続けることになる。
# 8.8.8.8 への ICMP (DNS を使わない) が両者を分ける。
# ==================================================================

echo "17. WAN outage vs DNS outage"

setup
STUB_PING_GW=ok ; STUB_PING_INET=fail   # 経路の先が死んでいる
STUB_HTTP204_CURL=6 ; STUB_HTTP204_CODE=000   # 名前も引けない
set_uptime 130 ; run_hc
check "17-1 WAN 断は INET_UNREACHABLE" 1 "$(count_match "$(logfile)" 'cause=INET_UNREACHABLE : gw=')"
check "17-2 DNS_FAILED と誤診しない" 0 "$(count_match "$(logfile)" 'cause=DNS_FAILED')"
check "17-3 無駄な RENEW を打たない" 0 "$(count_lines $WORK/rec/kick_dhcp)"

# ICMP が通るのに名前が引けない = 本物の DNS 断 (resolv.conf のラッチ)
setup
STUB_PING_GW=ok ; STUB_PING_INET=ok
STUB_HTTP204_CURL=6 ; STUB_HTTP204_CODE=000
: > "$WORK/tmp/resolv.conf"
set_uptime 130 ; run_hc
check "17-4 DNS 断は DNS_FAILED のまま" 1 "$(count_match "$(logfile)" 'cause=DNS_FAILED : name resolution failed')"
check "17-5 RENEW は打つ" 1 "$(count_lines $WORK/rec/kick_dhcp)"

# ==================================================================
# シナリオ 18: 起動直後の再確認間隔
#
# 上流が遅れて上がってくる間、障害中は cron の刻みどおり毎分見直す。
# 閾値が 60 だと tick 間の差が 59 に落ちた回に黙ってスキップされるため 30。
# ==================================================================

echo "18. early re-probe cadence"

setup
STUB_PING_GW=ok ; STUB_PING_INET=fail
STUB_HTTP204_CURL=7 ; STUB_HTTP204_CODE=000
set_uptime 130 ; run_hc
check "18-1 初回プローブ" 1 "$(count_lines $WORK/rec/http204)"

# cron の刻みぶんだけ進めば毎回プローブする (INET_EARLY_UNTIL=600 以内)
set_uptime 190 ; run_hc
check "18-2 60 秒後に再プローブ" 2 "$(count_lines $WORK/rec/http204)"

# int() の切り捨てで差が 59 に落ちても取りこぼさない
set_uptime 249 ; run_hc
check "18-3 差が 59 でも再プローブ" 3 "$(count_lines $WORK/rec/http204)"

# 30 秒未満は間引く (手動実行などで多重に叩かない)
set_uptime 269 ; run_hc
check "18-4 30 秒未満は間引く" 3 "$(count_lines $WORK/rec/http204)"

# 起動直後を抜けたら 120 秒間隔へ戻す
setup
STUB_PING_GW=ok ; STUB_PING_INET=fail
STUB_HTTP204_CURL=7 ; STUB_HTTP204_CODE=000
set_uptime 700 ; run_hc
check "18-5 初回プローブ" 1 "$(count_lines $WORK/rec/http204)"
set_uptime 760 ; run_hc
check "18-6 600 秒以降は 60 秒では叩かない" 1 "$(count_lines $WORK/rec/http204)"
set_uptime 830 ; run_hc
check "18-7 120 秒を過ぎたら叩く" 2 "$(count_lines $WORK/rec/http204)"

# 正常時は起動直後でも 600 秒間隔のまま (毎分 Google を叩かない)
setup
STUB_PING_GW=ok
set_uptime 130 ; run_hc
set_uptime 200 ; run_hc
check "18-8 正常時は間引いたまま" 1 "$(count_lines $WORK/rec/http204)"

# 上流の開通を 120 秒待たずに拾う (本題)
setup
STUB_PING_GW=ok ; STUB_PING_INET=fail
STUB_HTTP204_CURL=7 ; STUB_HTTP204_CODE=000
STUB_EPOCH=133 ; STUB_NTPD=""           # 時計は 1970 のまま
set_uptime 130 ; run_hc
check "18-9 開通前は時計に触らない" 0 "$(count_lines $WORK/rec/ntpd)"
STUB_PING_INET=ok                       # up=150 で WAN が開通
STUB_HTTP204_CURL=0 ; STUB_HTTP204_CODE=204
STUB_ORIGIN_CURL=60 ; STUB_ORIGIN_CODE=000    # 時計が 1970 なので TLS は失敗
set_uptime 190 ; run_hc
check "18-10 開通を 190s で検知" 1 "$(count_match "$(logfile)" 'cause=ORIGIN_TLS_FAILED')"
check "18-11 その場で時計を直しにいく" 1 "$(count_lines $WORK/rec/ntpd)"

# ==================================================================
# シナリオ 20: curl 28 の内訳判定 (応答しないネームサーバ)
# ==================================================================

echo "20. curl 28 is split by an explicit DNS check"

# 「生きているが応答しないネームサーバ」は 6 ではなく 28 を返す。
# 一律 INET_HTTP_BLOCKED にすると復旧手段もリブートも無い終端状態に落ちる。
setup
STUB_PING_GW=ok
STUB_HTTP204_CURL=28 ; STUB_HTTP204_CODE=000
STUB_NSLOOKUP=fail
set_uptime 130 ; run_hc
check "20-1 名前が引けなければ DNS_FAILED" 1 "$(count_match "$(logfile)" 'cause=DNS_FAILED :')"
check "20-2 INET_HTTP_BLOCKED にしない" 0 "$(count_match "$(logfile)" 'INET_HTTP_BLOCKED')"
check "20-3 DHCP RENEW を打つ" 1 "$(count_lines $WORK/rec/kick_dhcp)"
set_uptime 3830 ; run_hc
check "20-4 60分継続でリブートする" 1 "$(count_lines $WORK/rec/reboot)"

# 名前は引けるのに 28 = 本当に HTTP の出口が詰まっている。従来どおり。
setup
STUB_PING_GW=ok
STUB_HTTP204_CURL=28 ; STUB_HTTP204_CODE=000
STUB_NSLOOKUP=ok
set_uptime 130 ; run_hc
check "20-5 引けるなら INET_HTTP_BLOCKED" 1 "$(count_match "$(logfile)" 'cause=INET_HTTP_BLOCKED :')"
check "20-6 DHCP RENEW は打たない" 0 "$(count_lines $WORK/rec/kick_dhcp)"

# ICMP も通らないなら内訳を問わず INET_UNREACHABLE (nslookup も引かない)
setup
STUB_PING_GW=ok ; STUB_PING_INET=fail
STUB_HTTP204_CURL=28 ; STUB_HTTP204_CODE=000
STUB_NSLOOKUP=fail
set_uptime 130 ; run_hc
check "20-7 ICMP 断は INET_UNREACHABLE" 1 "$(count_match "$(logfile)" 'cause=INET_UNREACHABLE :')"

# curl 6 は従来どおり nslookup を引かずに DNS_FAILED
setup
STUB_PING_GW=ok
STUB_HTTP204_CURL=6 ; STUB_HTTP204_CODE=000
set_uptime 130 ; run_hc
check "20-8 curl 6 は即 DNS_FAILED" 1 "$(count_match "$(logfile)" 'cause=DNS_FAILED :')"

# ==================================================================
# シナリオ 21: 確認先の二重化 (単一事業者の遮断で誤判定しない)
# ==================================================================

echo "21. probe targets are dual-operator"

# Google だけが塞がれている網。予備が通れば正常と判定すること。
setup
STUB_PING_GW=ok
STUB_PING_INET=fail ; STUB_PING_INET2=ok
STUB_HTTP204_CURL=7 ; STUB_HTTP204_CODE=000
STUB_HTTP204_CURL2=0 ; STUB_HTTP204_CODE2=204
set_uptime 130 ; run_hc
check "21-1 予備で正常と判定" 1 "$(count_match "$(logfile)" 'inet=ok dns=ok origin=ok(200)')"
check "21-2 cause を出さない" 0 "$(count_match "$(logfile)" 'cause=')"
check "21-3 リブートしない" 0 "$(count_lines $WORK/rec/reboot)"
set_uptime 3830 ; run_hc
check "21-4 60分経ってもリブートしない" 0 "$(count_lines $WORK/rec/reboot)"

# 正常時は予備を叩かない (外部への負荷と所要時間を増やさない)
setup
STUB_PING_GW=ok
set_uptime 130 ; run_hc
check "21-5 primary が通れば予備の ping なし" 0 "$(count_match $WORK/rec/ping '1.1.1.1')"
check "21-6 primary が通れば予備の HTTP なし" 0 "$(count_lines $WORK/rec/http204_2)"

# 両方駄目なときだけ障害。ログには両方が駄目だったことを書く。
setup
STUB_PING_GW=ok
STUB_PING_INET=fail ; STUB_PING_INET2=fail
STUB_HTTP204_CURL=7 ; STUB_HTTP204_CODE=000
set_uptime 130 ; run_hc
check "21-7 両方駄目なら INET_UNREACHABLE" 1 "$(count_match "$(logfile)" 'cause=INET_UNREACHABLE :')"
check "21-8 両方の宛先を書く" 1 "$(count_match "$(logfile)" '8.8.8.8/1.1.1.1 both unreachable')"
check "21-9 予備も1回だけ叩く" 1 "$(count_lines $WORK/rec/http204_2)"

# 時刻補正は実際に 204 を返した方から取る
setup
STUB_PING_GW=ok
STUB_HTTP204_CURL=7 ; STUB_HTTP204_CODE=000    # primary は塞がれている
STUB_HTTP204_CURL2=0 ; STUB_HTTP204_CODE2=204
STUB_EPOCH=133 ; STUB_NTPD=""                  # 時計は 1970、ntpd も死んでいる
set_uptime 130 ; run_hc
set_uptime 1100 ; run_hc                       # NTP_RETRY_INTERVAL 経過で 2 回目
set_uptime 2100 ; run_hc                       # 2 回で駄目 -> HTTP Date へ
check "21-10 予備から Date: を取る" 1 "$(count_match "$(logfile)" 'clock set from HTTP Date .* (src=cp.cloudflare.com)')"

rm -rf "$WORK" "$FUNCTIONS_FILE"
echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
