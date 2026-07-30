#!/bin/sh
# ファームウェアアップデート後、サーバとの疎通(=camera-syncの成功)が確認できないまま
# 次のいずれかを満たした場合に、SDカードへ退避しておいた旧ファームウェアへロールバックする。
#   - 連続稼働時間が TIMEOUT 秒を超えた（TIMEOUT は mconfig の [firmware] rollbackTimeout、既定600秒）
#   - 更新後の起動回数が MAX_BOOT_COUNT に達した（起動直後に再起動を繰り返すケースの救済。
#     BOOT_COUNT は S76mocula が起動ごとに加算する）
# 壁時計ではなく uptime と BOOT_COUNT を使うのは、カメラのRTCが未同期・巻き戻る可能性があるため。
# 疎通確認は /var/run/mocula.sync_ok の有無で行う（tmpfs なので更新後の起動で必ず消える）。
# cron から毎分呼び出される想定（set_crontab.sh 参照）。

# パスは既定値を持たせつつ上書き可能にしてある（テストハーネスから一時ディレクトリを指すため）。
: "${VERSION_FILE:=/etc/mocula.ver}"
: "${UPDATE_DIR:=/media/mmc/update}"
: "${BACKUP_DIR:=/media/mmc/fwbackup}"
: "${STATE_DIR:=/media/mmc/fwupdate}"
: "${SYNC_OK_FILE:=/var/run/mocula.sync_ok}"
: "${LOGFILE:=/tmp/log/mocula.log}"
# 更新の記録は再起動を跨いで残す必要があるため永続領域にも書く（$LOGFILE は tmpfs 上）
: "${FWLOGFILE:=/media/mmc/atomhack.log}"
: "${FWSTATE_LIB:=/scripts/fwstate.sh}"

# 更新直後に再起動を繰り返しているケースを、この回数の起動で打ち切る
MAX_BOOT_COUNT=3

FWSTATE_DIR=$STATE_DIR
FWSTATE_LOGFILE=$FWLOGFILE
. "$FWSTATE_LIB"

log() {
  echo "$(date +"%Y/%m/%d %H:%M:%S") : fwrollback: $*" >> $LOGFILE
  echo "$(date +"%Y/%m/%d %H:%M:%S") : fwrollback: $*" >> $FWLOGFILE 2>/dev/null
}

load_state || exit 0

[ "$PHASE" = "applied" ] || exit 0

# BOOT_COUNT は S76mocula が実際の起動時にのみ加算する。0 のままなら更新を適用するための
# 再起動がまだ行われていない（write_state 直後、reboot によるシャットダウン処理中など）。
# cron は毎分動くのでこの窓に入りうる。ここで判定を進めると、成功する更新を failed と
# 誤記録した上でロールバック監視まで止めてしまう。
[ "$BOOT_COUNT" -ge 1 ] || exit 0

# initramfs がバージョン不一致等でアップデートを適用できず、旧ファームのまま起動したケース
CURRENT_VERSION=$(cat "$VERSION_FILE" 2>/dev/null)
if [ "$CURRENT_VERSION" != "$TARGET_VERSION" ]; then
  log "version mismatch after reboot (target=$TARGET_VERSION current=$CURRENT_VERSION), marking failed"
  set_state_phase failed version_mismatch_after_reboot
  exit 0
fi

if [ -f "$SYNC_OK_FILE" ]; then
  log "sync confirmed for version $TARGET_VERSION, clearing update state"
  rm -rf "$STATE_DIR"
  exit 0
fi

UPTIME=$(awk '{print int($1)}' /proc/uptime)

if [ "$UPTIME" -le "$TIMEOUT" ] && [ "$BOOT_COUNT" -lt "$MAX_BOOT_COUNT" ]; then
  exit 0
fi

log "rollback triggered (uptime=${UPTIME}s timeout=${TIMEOUT}s bootCount=$BOOT_COUNT)"

# initramfs_skeleton/init が適用前に行うサイズ検証と同じロジック。
# initramfs は意図的に無改造のまま流用しているため（前進アップデートもロールバックも
# /media/mmc/update に置いたファイルを init が拾って適用する）、ここで先に同じ検証を行い、
# 壊れたイメージで再起動してブートループに入るのを防ぐ。
# initramfs_skeleton/init を変更する際は本関数も追随させること。
verify_squashfs() {
  FILE=$1
  [ -f "$FILE" ] || return 1
  FSIZE=$(wc -c < "$FILE" 2>/dev/null)
  # squashfs superblock の bytes_used。%u で符号なしとして読む（2GB超で負値になるのを避ける）
  BSIZE=$(hexdump -s 0x28 -n 4 -e '1/4 "%u\n"' "$FILE" 2>/dev/null)
  case "$FSIZE$BSIZE" in
    '' | *[!0-9]*)
      log "verify: unreadable squashfs superblock in $FILE"
      return 1
      ;;
  esac
  # init と同じく4KiB境界へ切り上げ
  PSIZE=$((($BSIZE + 4095) / 4096 * 4096))
  [ "$FSIZE" -eq "$PSIZE" ]
}

verify_uimage() {
  FILE=$1
  [ -f "$FILE" ] || return 1
  FSIZE=$(wc -c < "$FILE" 2>/dev/null)
  HSIZE=$(hexdump -s 0x0c -n 4 -e '"0x" 4/1 "%02x" "\n"' "$FILE" 2>/dev/null)
  case "$FSIZE" in
    '' | *[!0-9]*)
      log "verify: unreadable size for $FILE"
      return 1
      ;;
  esac
  [ -n "$HSIZE" ] || {
    log "verify: unreadable uImage header in $FILE"
    return 1
  }
  # uImageヘッダ(0x0c)のイメージ長 + 64バイトヘッダ
  TSIZE=$(($HSIZE + 64))
  [ "$FSIZE" -eq "$TSIZE" ]
}

if ! verify_uimage "$BACKUP_DIR/factory_t31_ZMC6tiIDQN" || ! verify_squashfs "$BACKUP_DIR/rootfs_hack.squashfs"; then
  # ロールバックできない。無限リトライを避けるため終端させるが、rolled_back とは区別する:
  # 実機は新ファームウェアのまま動作しており、復旧手段を失っている（物理的な介入が必要）。
  log "backup verification failed, cannot roll back; reporting rollback_failed"
  set_state_phase rollback_failed backup_unusable
  exit 1
fi

# 旧ファームを /media/mmc/update へ置くだけ。実際の書き戻しは次回起動時に initramfs が行う
# （init が update/ 配下の factory_t31_ZMC6tiIDQN と rootfs_hack.squashfs を検証して適用する）。
# ファイル名は init 側の期待値と一致させる必要がある。
if ! mkdir -p "$UPDATE_DIR"; then
  log "rollback aborted: cannot create $UPDATE_DIR"
  exit 1
fi

# init は先に atomcam_tools.zip を展開するため、残っていると復元対象を上書きしてしまう
rm -f "$UPDATE_DIR/atomcam_tools.zip" "$UPDATE_DIR/atomcam_tools.zip.tmp"
rm -f "$UPDATE_DIR/factory_t31_ZMC6tiIDQN" "$UPDATE_DIR/rootfs_hack.squashfs"

# 退避元が検証済みでも、コピー先が容量不足で切り詰められれば同じく起動不能になる。
# カーネルだけ復元されて rootfs が壊れる組み合わせが最悪なので、両方を検証してから遷移する。
if ! cp "$BACKUP_DIR/factory_t31_ZMC6tiIDQN" "$UPDATE_DIR/factory_t31_ZMC6tiIDQN" \
  || ! cp "$BACKUP_DIR/rootfs_hack.squashfs" "$UPDATE_DIR/rootfs_hack.squashfs" \
  || ! cmp -s "$BACKUP_DIR/factory_t31_ZMC6tiIDQN" "$UPDATE_DIR/factory_t31_ZMC6tiIDQN" \
  || ! cmp -s "$BACKUP_DIR/rootfs_hack.squashfs" "$UPDATE_DIR/rootfs_hack.squashfs"; then
  # PHASE は applied のままにしておき、次回起動で再試行させる（容量が空けば成功しうる）
  log "rollback aborted: staging copy failed or did not verify; will retry on next boot"
  rm -f "$UPDATE_DIR/factory_t31_ZMC6tiIDQN" "$UPDATE_DIR/rootfs_hack.squashfs"
  exit 1
fi

# 再起動前にロールバック済みへ遷移させておくことで、復旧後に再度ロールバックが発火しないようにする
if ! set_state_phase rolled_back ""; then
  log "rollback aborted: cannot persist state; refusing to reboot into a possible rollback loop"
  rm -f "$UPDATE_DIR/factory_t31_ZMC6tiIDQN" "$UPDATE_DIR/rootfs_hack.squashfs"
  exit 1
fi

sync
log "rolling back from $TARGET_VERSION to $PREV_VERSION, rebooting"
reboot
