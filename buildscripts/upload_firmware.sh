#!/bin/bash
# ビルド済み atomcam_tools.zip を mocula-backend の imageBucket へ配置する。
#
# 配置先は `firmware/ota/{version}/atomcam_tools.zip`。
# バックエンドはこのキーの実体からサイズと sha256 を算出して登録するため、
# 一度登録したバージョンのオブジェクトを差し替えてはいけない（登録済みの値とずれ、
# そのファームウェアを予約した全カメラが完全性検証で失敗する）。
# そのため既にオブジェクトがある場合は既定で拒否する。
#
# 任意の環境変数:
#   MOCULA_IMAGE_BUCKET  配置先バケット。省略時は cdk/config/<stage>.yml の imageBucketName
#   AWS_ENDPOINT_URL     S3 エンドポイント。ローカル開発(floci)では http://localhost:4566
#   FIRMWARE_FORCE       1 を指定すると既存オブジェクトを上書きする（危険。上記を理解した上で）

set -euo pipefail

STAGE=${1:-}
if [ -z "$STAGE" ]; then
  echo "usage: $0 <stage>   (dev1 | qa1 | prod1 | prod2)" >&2
  exit 1
fi

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
ZIP_FILE="$REPO_ROOT/atomcam_tools.zip"
VERSION_FILE="$REPO_ROOT/configs/mocula.ver"
CONFIG_FILE="$REPO_ROOT/cdk/config/$STAGE.yml"

if [ ! -f "$ZIP_FILE" ]; then
  echo "error: $ZIP_FILE not found. Run \"make build\" first." >&2
  exit 1
fi

VERSION=$(tr -d ' \t\r\n' < "$VERSION_FILE")
case "$VERSION" in
  '' | *[!A-Za-z0-9._-]*)
    echo "error: invalid version in $VERSION_FILE: '$VERSION'" >&2
    exit 1
    ;;
esac

BUCKET=${MOCULA_IMAGE_BUCKET:-}
if [ -z "$BUCKET" ]; then
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "error: config not found: $CONFIG_FILE" >&2
    exit 1
  fi
  BUCKET=$(sed -n 's/^imageBucketName:[[:space:]]*//p' "$CONFIG_FILE" | sed 's/[[:space:]]*#.*$//; s/^"//; s/"$//' | head -1)
fi
if [ -z "$BUCKET" ]; then
  echo "error: imageBucketName is not set for stage '$STAGE'" >&2
  exit 1
fi

S3_KEY="firmware/ota/$VERSION/atomcam_tools.zip"
S3_URI="s3://$BUCKET/$S3_KEY"

AWS_ARGS=()
if [ -n "${AWS_ENDPOINT_URL:-}" ]; then
  AWS_ARGS+=(--endpoint-url "$AWS_ENDPOINT_URL")
fi

LOCAL_SIZE=$(wc -c < "$ZIP_FILE" | tr -d ' ')

echo "==> uploading $VERSION to $S3_URI (${LOCAL_SIZE} bytes)"

# 既存オブジェクトの差し替えは、登録済みの size/sha256 との不整合を生むため既定で拒否する
if aws "${AWS_ARGS[@]}" s3api head-object --bucket "$BUCKET" --key "$S3_KEY" >/dev/null 2>&1; then
  if [ "${FIRMWARE_FORCE:-}" != "1" ]; then
    cat >&2 <<EOF
error: $S3_URI already exists.

  Replacing it would leave any existing registration describing the previous
  build, and every camera offered this firmware would fail its integrity check.

  Bump configs/mocula.ver and deploy that instead. If you really must replace
  this object, delete the backend registration first
  (DELETE /api/v1/admin/firmwares/{id}) and re-run with FIRMWARE_FORCE=1.
EOF
    exit 1
  fi
  echo "warning: overwriting an existing object because FIRMWARE_FORCE=1" >&2
fi

aws "${AWS_ARGS[@]}" s3 cp "$ZIP_FILE" "$S3_URI" --only-show-errors

# 転送欠落を早期に検出する。内容の一致は登録時に sha256 で照合される
REMOTE_SIZE=$(aws "${AWS_ARGS[@]}" s3api head-object --bucket "$BUCKET" --key "$S3_KEY" --query ContentLength --output text)
if [ "$REMOTE_SIZE" != "$LOCAL_SIZE" ]; then
  echo "error: size mismatch after upload (local=$LOCAL_SIZE remote=$REMOTE_SIZE)" >&2
  exit 1
fi

echo "==> uploaded $S3_URI"
