#!/bin/busybox ash
# fwrollback.sh の分岐を検証する。reboot / cp などをスタブ化し、パスを一時ディレクトリへ向ける。
REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$REPO/overlay_rootfs/scripts/fwrollback.sh
LIB=$REPO/overlay_rootfs/scripts/fwstate.sh

PASS=0
FAIL=0
check() { # desc expected actual
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    echo "  ok   $1"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL $1: expected [$2] got [$3]"
  fi
}

# 有効な squashfs / uImage を模造する（サイズ検証を通す最小構成）
make_squashfs() { # path
  # bytes_used(0x28)=4096 -> ファイルサイズも4096
  dd if=/dev/zero of="$1" bs=4096 count=1 2>/dev/null
  printf '\000\020\000\000' | dd of="$1" bs=1 seek=40 conv=notrunc 2>/dev/null
}
make_uimage() { # path
  # ヘッダ(0x0c)のイメージ長=64 -> ファイルサイズ=64+64=128
  dd if=/dev/zero of="$1" bs=128 count=1 2>/dev/null
  printf '\000\000\000\100' | dd of="$1" bs=1 seek=12 conv=notrunc 2>/dev/null
}

setup() { # phase bootcount uptime_ignored
  WORK=$(mktemp -d)
  export STATE_DIR=$WORK/fwupdate UPDATE_DIR=$WORK/update BACKUP_DIR=$WORK/fwbackup
  export VERSION_FILE=$WORK/mocula.ver SYNC_OK_FILE=$WORK/sync_ok
  export LOGFILE=$WORK/mocula.log FWLOGFILE=$WORK/atomhack.log FWSTATE_LIB=$LIB
  export STUBDIR=$WORK/bin
  mkdir -p "$UPDATE_DIR" "$BACKUP_DIR" "$STUBDIR"
  echo "0.2.0" > "$VERSION_FILE"
  # reboot をスタブ化して呼ばれたことだけ記録する
  cat > "$STUBDIR/reboot" <<EOF
#!/bin/sh
echo called >> $WORK/reboot_called
EOF
  chmod +x "$STUBDIR/reboot"
  make_uimage "$BACKUP_DIR/factory_t31_ZMC6tiIDQN"
  make_squashfs "$BACKUP_DIR/rootfs_hack.squashfs"
  FWSTATE_DIR=$STATE_DIR . "$LIB"
  write_state 0.2.0 0.1.0 "$1" 0 "$2" ""
}

run_script() { PATH="$STUBDIR:$PATH" busybox ash "$SCRIPT"; }
state_get() { awk -F= -v k="$1" '$1==k{print $2}' "$STATE_DIR/state" 2>/dev/null; }
phase_now() { state_get PHASE; }
# busybox ash は reboot を内部applet として解決するため PATH のスタブを迂回する。
# reboot 直前に必ず出るログ行を観測点にする。
reboot_count() {
  COUNT=$(grep -c 'rebooting' "$LOGFILE" 2>/dev/null)
  case "$COUNT" in
    '' | *[!0-9]*) echo 0 ;;
    *) echo "$COUNT" ;;
  esac
}
rebooted() { [ "$(reboot_count)" -ge 1 ] && echo yes || echo no; }

echo "== 1. BOOT_COUNT=0 (update reboot not happened yet) must not act =="
setup applied 0
run_script
check "phase stays applied" "applied" "$(phase_now)"
check "no reboot" "no" "$(rebooted)"

echo "== 2. sync confirmed -> state cleared =="
setup applied 1
touch "$SYNC_OK_FILE"
run_script
check "state dir removed" "no" "$([ -d "$STATE_DIR" ] && echo yes || echo no)"
check "no reboot" "no" "$(rebooted)"

echo "== 3. version mismatch after reboot -> failed =="
setup applied 1
echo "0.1.0" > "$VERSION_FILE"
run_script
check "phase failed" "failed" "$(phase_now)"
check "target preserved" "0.2.0" "$(state_get TARGET_VERSION)"
check "no reboot" "no" "$(rebooted)"

echo "== 4. timeout exceeded, backup good -> rolled_back + reboot =="
setup applied 1
run_script
check "phase rolled_back" "rolled_back" "$(phase_now)"
check "rebooted" "yes" "$(rebooted)"
check "kernel staged" "yes" "$([ -f "$UPDATE_DIR/factory_t31_ZMC6tiIDQN" ] && echo yes || echo no)"
check "rootfs staged" "yes" "$([ -f "$UPDATE_DIR/rootfs_hack.squashfs" ] && echo yes || echo no)"

echo "== 5. rerun after rollback must not loop =="
run_script
check "still rolled_back" "rolled_back" "$(phase_now)"
check "reboot attempted only once" "1" "$(reboot_count)"

echo "== 6. corrupt backup -> rollback_failed, no reboot =="
setup applied 1
echo "garbage" > "$BACKUP_DIR/rootfs_hack.squashfs"
run_script
check "phase rollback_failed" "rollback_failed" "$(phase_now)"
check "no reboot" "no" "$(rebooted)"

echo "== 7. stale zip in update dir is cleared before staging =="
setup applied 1
echo "stale" > "$UPDATE_DIR/atomcam_tools.zip"
run_script
check "stale zip removed" "no" "$([ -f "$UPDATE_DIR/atomcam_tools.zip" ] && echo yes || echo no)"
check "rebooted" "yes" "$(rebooted)"

echo "== 8. BOOT_COUNT reaching max triggers rollback even below timeout =="
setup applied 3
write_state 0.2.0 0.1.0 applied 999999 3 ""
run_script
check "phase rolled_back" "rolled_back" "$(phase_now)"
check "rebooted" "yes" "$(rebooted)"

echo "== 9. corrupt state file is discarded and does not kill the caller =="
setup applied 1
printf 'TARGET_VERSION=0.2.0\nPHASE=app' > "$STATE_DIR/state"
printf 'x;touch %s/PWNED\n' "$WORK" >> "$STATE_DIR/state"
run_script
check "caller survived (exit ok)" "0" "$?"
check "no injected file" "no" "$([ -f "$WORK/PWNED" ] && echo yes || echo no)"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
