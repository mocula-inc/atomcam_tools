#!/bin/busybox ash
#
# S42ntpd のテスト
#
# 実行: busybox ash tests/test_s42ntpd.sh
#
# 方式:
#   S42ntpd は読み込むと即 case が走る init スクリプトなので、
#   test_health_check.sh のように関数定義だけを切り出すことができない。
#   代わりに絶対パス (/proc/uptime, /media/mmc/time.ini, /tmp/*) を作業ディレクトリ
#   配下へ sed で寄せた複製を作り、スタブを定義したランナーから source する。
#
#   busybox ash は applet を内部解決するため PATH にスタブを置いても
#   ping/date/logger/killall には効かない。シェル関数定義は applet より優先されるので、
#   スタブは全て関数オーバーライドで統一する (test_health_check.sh と同じ方針)。
#   関数名に / を含められないため、/usr/sbin/ntpd だけは stub_ntpd へ置換する。
#
#   疎通の可否は $WORK/ping_ok (ping が成功するまでの残り失敗回数)、
#   時計は $WORK/clock (epoch)、uptime は $WORK/proc_uptime で制御する。

SCRIPT=$(dirname "$0")/../overlay_rootfs/etc/init.d/S42ntpd
PASS=0
FAIL=0

check() { # desc expected actual
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); echo "  ok   $1"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $1: expected [$2] got [$3]"
  fi
}

# --- 時計フィクスチャ ---
# ★ S42ntpd の CLOCK_MIN_EPOCH より必ず後ろの時刻にすること。
#    下回ると clock_sane() / restore_time_ini() が常に「未同期」側に倒れ、
#    time.ini 系のテストが落ちるか、誤った理由で通ってしまう。
#    あちらを更新したらここも同じだけ動かす (tests/test_health_check.sh も同様)。
CLOCK_EPOCH=1788266096          # 2026/09/01 12:34:56 UTC = 正常な時計
CLOCK_EPOCH_LATE=1788268800     # 2026/09/01 13:20:00 UTC = それより後の時計

WORK=""

setup() {
  [ -n "$WORK" ] && rm -rf "$WORK"
  WORK=$(mktemp -d)
  export WORK
  mkdir -p "$WORK/log"
  echo 0 > "$WORK/ping_ok"      # 既定は「最初から疎通している」
  echo 5 > "$WORK/proc_uptime"  # 既定は起動直後
  echo 100 > "$WORK/clock"      # 1970 相当 = 未同期
  : > "$WORK/events"

  sed -e "s#/usr/sbin/ntpd#stub_ntpd#g" \
      -e "s#/proc/uptime#$WORK/proc_uptime#g" \
      -e "s#^TIMEINI=.*#TIMEINI=$WORK/time.ini#" \
      -e "s#^LOOPPID=.*#LOOPPID=$WORK/ntpd_boot.pid#" \
      -e "s#^LOG=.*#LOG=$WORK/log/ntpd.log#" \
      -e "s#^NTP_WAIT_INTERVAL=.*#NTP_WAIT_INTERVAL=1#" \
      -e "s#mkdir -p /tmp/log#mkdir -p $WORK/log#" \
      "$SCRIPT" > "$WORK/S42ntpd"

  cat > "$WORK/runner" <<'EOF'
#!/bin/busybox ash
# applet より優先される関数でスタブする
stub_ntpd() {
  echo "ntpd $*" >> $WORK/events
  case "$1" in
    -qn) echo 1786550000 > $WORK/clock ;;             # -qn は時計を合わせて終了する
    *)   sleep 30 & echo $! > $WORK/resident.pid ;;   # 常駐 ntpd の代役
  esac
}
ping() {
  _n=$(cat $WORK/ping_ok)
  echo "ping" >> $WORK/events
  [ "$_n" -gt 0 ] && { echo $((_n - 1)) > $WORK/ping_ok ; return 1 ; }
  return 0
}
logger() { shift 2> /dev/null ; echo "logger $*" >> $WORK/events ; }
killall() {
  echo "killall $*" >> $WORK/events
  [ -f $WORK/resident.pid ] && kill "$(cat $WORK/resident.pid)" 2> /dev/null
  rm -f $WORK/resident.pid
  return 0
}
# date +%s / date -s @N / date +FORMAT を偽の時計で再現する
date() {
  case "$1" in
    -s)  echo "${2#@}" > $WORK/clock ;;
    +%s) cat $WORK/clock ;;
    *)   busybox date -u -d "@$(cat $WORK/clock)" "$1" ;;
  esac
  return 0
}
. $WORK/S42ntpd
EOF
}

run()   { busybox ash "$WORK/runner" "$1" > /dev/null 2>&1 ; }
count() { grep -c "$1" "$WORK/events" 2> /dev/null ; true ; }
exists() { [ -f "$1" ] && echo yes || echo no ; }

# boot_sync は pidfile を消して終わる。消えるまで最大 10 秒待つ。
wait_loop_done() {
  _i=0
  while [ -f "$WORK/ntpd_boot.pid" ] && [ $_i -lt 100 ] ; do sleep 0.1 ; _i=$((_i + 1)) ; done
}

# ------------------------------------------------------------------
# シナリオ 1: 疎通あり
# ------------------------------------------------------------------
echo "1. 疎通あり: 1 回で同期して常駐 ntpd を起動する"
setup
run start
wait_loop_done
check "1-1 ping は 1 回だけ"          1 "$(count '^ping$')"
check "1-2 ntpd -qn で時計を合わせた" 1 "$(count 'ntpd -qn')"
check "1-3 常駐 ntpd を起動した"      1 "$(count 'ntpd -p')"
check "1-4 時計が同期済み"            1786550000 "$(cat "$WORK/clock")"
check "1-5 pidfile を後始末した"      no "$(exists "$WORK/ntpd_boot.pid")"

# ------------------------------------------------------------------
# シナリオ 2: 疎通が遅れる (本題。カメラがルーターより先に起動した場合)
# ------------------------------------------------------------------
echo "2. 疎通が遅れる: 繋がるまで待ってから同期する"
setup
echo 2 > "$WORK/ping_ok"                # 最初の 2 回は失敗
run start
wait_loop_done
check "2-1 ping を 3 回試した"        3 "$(count '^ping$')"
check "2-2 同期できた"                1 "$(count 'ntpd -qn')"
check "2-3 時計が同期済み"            1786550000 "$(cat "$WORK/clock")"

# ------------------------------------------------------------------
# シナリオ 3: 期限切れ (BOOT_GRACE 後は health_check.sh に任せる)
# ------------------------------------------------------------------
echo "3. 期限切れ: 待たずに常駐 ntpd だけ起動する"
setup
echo 99 > "$WORK/ping_ok"               # ずっと失敗
echo 200 > "$WORK/proc_uptime"          # NTP_BOOT_DEADLINE を過ぎている
run start
wait_loop_done
check "3-1 ping は 1 回で打ち切り"    1 "$(count '^ping$')"
check "3-2 同期はしていない"          0 "$(count 'ntpd -qn')"
check "3-3 常駐 ntpd は起動する"      1 "$(count 'ntpd -p')"

# ------------------------------------------------------------------
# シナリオ 4: time.ini
# ------------------------------------------------------------------
echo "4. time.ini: ネットワークを待たずに時計を寄せる"
setup
echo 99 > "$WORK/ping_ok"
echo 200 > "$WORK/proc_uptime"
echo "utc=$CLOCK_EPOCH" > "$WORK/time.ini"
run start
wait_loop_done
check "4-1 time.ini で時計を設定した" $CLOCK_EPOCH "$(cat "$WORK/clock")"
check "4-2 その旨をログした"          1 "$(count 'clock preset')"

echo "5. 時計が既に正常なら古い time.ini で狂わせない"
setup
echo 99 > "$WORK/ping_ok"
echo 200 > "$WORK/proc_uptime"
# 時計は必ず CLOCK_MIN_EPOCH より後ろにする。下回ると clock_sane() が false になり、
# 「同期済みだから上書きしない」ではなく「time.ini 側が下限割れで棄却された」という
# 別の理由でこのテストが通ってしまう。
echo $CLOCK_EPOCH_LATE > "$WORK/clock"  # 同期済み
echo "utc=$CLOCK_EPOCH" > "$WORK/time.ini"
run start
wait_loop_done
check "5-1 時計を上書きしない"        $CLOCK_EPOCH_LATE "$(cat "$WORK/clock")"
check "5-2 preset ログを出さない"     0 "$(count 'clock preset')"

echo "6. time.ini が壊れていても無視して先へ進む"
setup
echo 99 > "$WORK/ping_ok"
echo 200 > "$WORK/proc_uptime"
echo "utc=garbage" > "$WORK/time.ini"
run start
wait_loop_done
check "6-1 時計を触らない"            100 "$(cat "$WORK/clock")"
check "6-2 常駐 ntpd までは進む"      1 "$(count 'ntpd -p')"

# ------------------------------------------------------------------
# シナリオ 7-8: 多重起動と stop
# health_check.sh の ntpd_restart() が stop/start を打ち込んでくるため、
# 待機中のループが増殖したり、stop した後に勝手に ntpd が上がったりしないこと。
# ------------------------------------------------------------------
echo "7. 二重 start で待機ループを増やさない"
setup
echo 99 > "$WORK/ping_ok"               # ループが待機し続ける状態にする
run start
sleep 0.3
run start
check "7-1 2 回目は素通り"            1 "$(count 'already pending')"
check "7-2 ループは 1 本だけ"         yes "$(exists "$WORK/ntpd_boot.pid")"
run stop

echo "8. stop が待機中のループを止める"
setup
echo 99 > "$WORK/ping_ok"
run start
sleep 0.3
LOOP_PID=$(cat "$WORK/ntpd_boot.pid")
run stop
sleep 0.3
check "8-1 ループを kill した"        dead "$(kill -0 "$LOOP_PID" 2> /dev/null && echo alive || echo dead)"
check "8-2 pidfile を消した"          no "$(exists "$WORK/ntpd_boot.pid")"
sleep 1.5
check "8-3 stop 後に ntpd を上げない" 0 "$(count 'ntpd -p')"

rm -rf "$WORK"
echo
echo "pass=$PASS fail=$FAIL"
[ $FAIL -eq 0 ]
