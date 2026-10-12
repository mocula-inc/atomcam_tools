#!/bin/bash
# ファームウェアに入るファイルの変更と configs/mocula.ver の更新が揃っているかを確かめる。
#
# main へ入ると GitHub Actions が configs/mocula.ver のバージョンを各環境へ登録する
# （.github/workflows/deploy.yml）。登録済みのバージョンは二度と配置されないため、
#   - 中身を変えたのにバージョンが同じ  → 変更が配られない
#   - 中身が同じなのにバージョンだけ違う → 同じ内容がもう一度配られる
# のどちらもここで止める。
#
# 使い方: check_firmware_version.sh <base-ref>   （例: origin/main）

set -euo pipefail

BASE_REF=${1:-}
if [ -z "$BASE_REF" ]; then
  echo "usage: $0 <base-ref>   (e.g. origin/main)" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

VERSION_FILE=configs/mocula.ver

# ビルド結果に影響するパス。ここに無いもの（ドキュメント、テスト、配置用スクリプトなど）は
# バージョンを上げずに変更できる。Dockerfile が無いのは、ビルドには docker-compose.yml が
# 指す公開済みイメージを使い、Dockerfile からは作らないため
# （.github/workflows/deploy.yml の on.push.paths と揃えること）
FIRMWARE_PATHS=(
  docker-compose.yml
  buildscripts
  configs
  custompackages
  initramfs_skeleton
  libcallback
  overlay_rootfs
  patches
  web
)
NOT_FIRMWARE_PATHS=(
  ":(exclude)$VERSION_FILE"
  ':(exclude)buildscripts/check_firmware_version.sh'
  ':(exclude)buildscripts/register_firmware.sh'
  ':(exclude)buildscripts/upload_firmware.sh'
  ':(exclude)libcallback/*.md'
)

MERGE_BASE=$(git merge-base "$BASE_REF" HEAD)

FIRMWARE_CHANGES=$(git diff --name-only "$MERGE_BASE" HEAD -- "${FIRMWARE_PATHS[@]}" "${NOT_FIRMWARE_PATHS[@]}")
BASE_VERSION=$(git show "$MERGE_BASE:$VERSION_FILE" 2>/dev/null | tr -d ' \t\r\n' || true)
HEAD_VERSION=$(tr -d ' \t\r\n' < "$VERSION_FILE")

if [ -n "$FIRMWARE_CHANGES" ] && [ "$BASE_VERSION" = "$HEAD_VERSION" ]; then
  cat >&2 <<EOF
error: the firmware changes but $VERSION_FILE is still $HEAD_VERSION.

  A version that is already registered is never deployed again, so these
  changes would not reach any camera. Bump $VERSION_FILE.

changed files:
$FIRMWARE_CHANGES
EOF
  exit 1
fi

if [ -z "$FIRMWARE_CHANGES" ] && [ "$BASE_VERSION" != "$HEAD_VERSION" ]; then
  cat >&2 <<EOF
error: $VERSION_FILE changes ($BASE_VERSION -> $HEAD_VERSION) but the firmware does not.

  This would deploy a new version with the same contents. Revert $VERSION_FILE.
EOF
  exit 1
fi

if [ -n "$FIRMWARE_CHANGES" ]; then
  echo "ok: firmware changes, version $BASE_VERSION -> $HEAD_VERSION"
else
  echo "ok: no firmware changes, version stays $HEAD_VERSION"
fi
