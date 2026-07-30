#!/bin/bash
# S3 へ配置済みのファームウェアを mocula-backend へ登録する。
#
# S3 に置くだけではカメラへ配信できない。バックエンドが S3 の実体を読んで
# サイズと sha256 を算出し `firmwares` テーブルに登録して初めて予約可能になる。
# `make firmware-deploy` の後段として呼ばれるが、登録だけを再実行することもできる
# （`make firmware-register CONFIG=<stage>`）。
#
# 必要な環境変数:
#   MOCULA_ADMIN_EMAIL     運営管理者のメールアドレス
#   MOCULA_ADMIN_PASSWORD  同パスワード（未設定なら対話的に入力を求める）
# 任意:
#   MOCULA_API_ORIGIN      API のベースURL。省略時は cdk/config/<stage>.yml の apiOrigin
#                          ローカル開発では http://localhost:3000 を指定する
#   FIRMWARE_NOTE          登録時のメモ

set -euo pipefail

STAGE=${1:-}
if [ -z "$STAGE" ]; then
  echo "usage: $0 <stage>   (dev1 | qa1 | prod1 | prod2)" >&2
  exit 1
fi

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION_FILE="$REPO_ROOT/configs/mocula.ver"
CONFIG_FILE="$REPO_ROOT/cdk/config/$STAGE.yml"

VERSION=$(tr -d ' \t\r\n' < "$VERSION_FILE")
if [ -z "$VERSION" ]; then
  echo "error: $VERSION_FILE is empty" >&2
  exit 1
fi

# apiOrigin は環境変数優先。yml からは値だけを取り出す（行末コメントとクォートを除去）
API_ORIGIN=${MOCULA_API_ORIGIN:-}
if [ -z "$API_ORIGIN" ]; then
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "error: config not found: $CONFIG_FILE" >&2
    exit 1
  fi
  API_ORIGIN=$(sed -n 's/^apiOrigin:[[:space:]]*//p' "$CONFIG_FILE" | sed 's/[[:space:]]*#.*$//; s/^"//; s/"$//' | head -1)
fi
if [ -z "$API_ORIGIN" ]; then
  echo "error: apiOrigin is not set for stage '$STAGE'." >&2
  echo "       Set it in $CONFIG_FILE or pass MOCULA_API_ORIGIN." >&2
  exit 1
fi

ADMIN_EMAIL=${MOCULA_ADMIN_EMAIL:-}
if [ -z "$ADMIN_EMAIL" ]; then
  echo "error: MOCULA_ADMIN_EMAIL is required" >&2
  exit 1
fi

ADMIN_PASSWORD=${MOCULA_ADMIN_PASSWORD:-}
if [ -z "$ADMIN_PASSWORD" ]; then
  if [ -t 0 ]; then
    read -r -s -p "Password for $ADMIN_EMAIL: " ADMIN_PASSWORD
    echo
  else
    echo "error: MOCULA_ADMIN_PASSWORD is required when stdin is not a terminal" >&2
    exit 1
  fi
fi

# Cookie とレスポンスは他ユーザーから読めない場所に置き、終了時に必ず消す
WORK_DIR=$(umask 077 && mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
COOKIE_JAR="$WORK_DIR/cookies"
BODY_FILE="$WORK_DIR/body"

echo "==> registering firmware $VERSION at $API_ORIGIN"

# パスワードを引数に渡すと ps から見えてしまうため、ボディは標準入力から渡す
SIGNIN_CODE=$(
  printf '{"email":%s,"password":%s}' \
    "$(printf '%s' "$ADMIN_EMAIL" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "$(printf '%s' "$ADMIN_PASSWORD" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" |
    curl -sS -o "$BODY_FILE" -w '%{http_code}' \
      -c "$COOKIE_JAR" \
      -X POST -H 'Content-Type: application/json' --data-binary @- \
      "$API_ORIGIN/api/v1/admin/auth/signin"
)
if [ "$SIGNIN_CODE" != "200" ]; then
  echo "error: admin signin failed (HTTP $SIGNIN_CODE)" >&2
  cat "$BODY_FILE" >&2
  echo >&2
  exit 1
fi

NOTE=${FIRMWARE_NOTE:-"deployed by make firmware-deploy ($STAGE)"}
REGISTER_CODE=$(
  python3 -c 'import json,sys; print(json.dumps({"version": sys.argv[1], "note": sys.argv[2]}))' "$VERSION" "$NOTE" |
    curl -sS -o "$BODY_FILE" -w '%{http_code}' \
      -b "$COOKIE_JAR" \
      -X POST -H 'Content-Type: application/json' --data-binary @- \
      "$API_ORIGIN/api/v1/admin/firmwares"
)

case "$REGISTER_CODE" in
  201)
    echo "==> registered:"
    cat "$BODY_FILE"
    echo
    echo "==> next: reserve it for a camera with POST /api/v1/cameras/{id}/firmware-update"
    ;;
  409)
    cat "$BODY_FILE" >&2
    echo >&2
    cat >&2 <<EOF

error: version $VERSION is already registered.

  The S3 object was just overwritten by this deploy, but the stored size and
  sha256 still describe the previous build. Every camera that is offered this
  firmware will fail its integrity check.

  Either bump configs/mocula.ver and deploy again, or delete the existing
  registration (DELETE /api/v1/admin/firmwares/{id}) and re-run
  "make firmware-register CONFIG=$STAGE".
EOF
    exit 1
    ;;
  422)
    cat "$BODY_FILE" >&2
    echo >&2
    echo "error: the firmware object is not in S3. Did the CDK deploy succeed?" >&2
    exit 1
    ;;
  *)
    echo "error: registration failed (HTTP $REGISTER_CODE)" >&2
    cat "$BODY_FILE" >&2
    echo >&2
    exit 1
    ;;
esac
