#!/bin/bash
# S3 へ配置済みのファームウェアを mocula-backend へ登録する。
#
# S3 に置くだけではカメラへ配信できない。バックエンドが S3 の実体を読んで
# サイズと sha256 を算出し `firmwares` テーブルに登録して初めて予約可能になる。
# `make firmware-deploy` の後段として呼ばれるが、登録だけを再実行することもできる
# （`make firmware-register CONFIG=<stage>`）。
#
# 認証は次のどちらか。MOCULA_FIRMWARE_API_KEY があればそちらを使う:
#   MOCULA_FIRMWARE_API_KEY  ファームウェア登録用の API キー（GitHub Actions はこちら）
#   MOCULA_ADMIN_EMAIL       運営管理者のメールアドレス
#   MOCULA_ADMIN_PASSWORD    同パスワード（未設定なら対話的に入力を求める）
#
# `--check` を付けると登録はせず、configs/mocula.ver のバージョンが登録済みかだけを調べて
# `registered` か `unregistered` を標準出力に出す（API キー認証のみ）。
#
# 任意:
#   MOCULA_API_ORIGIN      API のベースURL。省略時は cdk/config/<stage>.yml の apiOrigin
#                          ローカル開発では http://localhost:3000 を指定する
#   FIRMWARE_NOTE          登録時のメモ

set -euo pipefail

STAGE=${1:-}
MODE=${2:-}
if [ -z "$STAGE" ] || { [ -n "$MODE" ] && [ "$MODE" != "--check" ]; }; then
  echo "usage: $0 <stage> [--check]   (dev1 | qa1 | qa2 | prod1 | prod2)" >&2
  exit 1
fi

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION_FILE="$REPO_ROOT/configs/mocula.ver"
CONFIG_FILE="$REPO_ROOT/cdk/config/$STAGE.yml"

VERSION=$(tr -d ' \t\r\n' < "$VERSION_FILE")
# S3 のキーになる値なので、upload_firmware.sh と同じ文字種に限る
case "$VERSION" in
  '' | *[!A-Za-z0-9._-]*)
    echo "error: invalid version in $VERSION_FILE: '$VERSION'" >&2
    exit 1
    ;;
esac

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

API_KEY=${MOCULA_FIRMWARE_API_KEY:-}

# Cookie・API キー・レスポンスは他ユーザーから読めない場所に置き、終了時に必ず消す
WORK_DIR=$(umask 077 && mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
COOKIE_JAR="$WORK_DIR/cookies"
BODY_FILE="$WORK_DIR/body"
HEADER_FILE="$WORK_DIR/headers"

if [ -n "$API_KEY" ]; then
  # キーを引数に渡すと ps から見えてしまうため、ヘッダはファイルから渡す
  printf 'X-Api-Key: %s\n' "$API_KEY" > "$HEADER_FILE"
  AUTH_ARGS=(-H "@$HEADER_FILE")
else
  AUTH_ARGS=(-b "$COOKIE_JAR")
fi
FIRMWARES_URL="$API_ORIGIN/api/v1/admin/firmwares"
# 応答が返らないまま CI のジョブを時間切れまで占有しないよう、上限を付ける
CURL_ARGS=(-sS --connect-timeout 10 --max-time 120)

if [ "$MODE" = "--check" ]; then
  if [ -z "$API_KEY" ]; then
    echo "error: --check requires MOCULA_FIRMWARE_API_KEY" >&2
    exit 1
  fi
  # 一覧をページ送りで最後まで見る。応答がこの API のものと確かめられないときは、呼び出し側が
  # 「未登録」と読んで登録済みの S3 オブジェクトを上書きしないよう、必ず失敗させる
  PAGE=1
  while :; do
    # 読み取りだけなので、一時的な 5xx やタイムアウトはやり直す
    CHECK_CODE=$(curl "${CURL_ARGS[@]}" --retry 3 -o "$BODY_FILE" -w '%{http_code}' "${AUTH_ARGS[@]}" "$FIRMWARES_URL?_limit=100&_page=$PAGE")
    if [ "$CHECK_CODE" != "200" ]; then
      echo "error: could not list firmwares at $API_ORIGIN (HTTP $CHECK_CODE)" >&2
      cat "$BODY_FILE" >&2
      echo >&2
      exit 1
    fi
    # found: このページにある / more: 続きがある / end: 最後まで見たが無い
    PAGE_RESULT=$(
      python3 -c '
import json, sys
body = json.load(sys.stdin)
version, page = sys.argv[1], int(sys.argv[2])
if body["success"] is not True:
    raise ValueError("unexpected response")
if any(item["version"] == version for item in body["data"]):
    print("found")
elif body["data"] and page * 100 < body["totalCount"]:
    print("more")
else:
    print("end")
' "$VERSION" "$PAGE" < "$BODY_FILE" 2>/dev/null
    ) || {
      echo "error: unexpected response from $FIRMWARES_URL" >&2
      exit 1
    }
    case "$PAGE_RESULT" in
      found)
        echo "registered"
        break
        ;;
      end)
        echo "unregistered"
        break
        ;;
    esac
    PAGE=$((PAGE + 1))
  done
  exit 0
fi

echo "==> registering firmware $VERSION at $API_ORIGIN"

if [ -z "$API_KEY" ]; then
  ADMIN_EMAIL=${MOCULA_ADMIN_EMAIL:-}
  if [ -z "$ADMIN_EMAIL" ]; then
    echo "error: MOCULA_FIRMWARE_API_KEY or MOCULA_ADMIN_EMAIL is required" >&2
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

  # パスワードを引数に渡すと ps から見えてしまうため、ボディは標準入力から渡す
  SIGNIN_CODE=$(
    printf '{"email":%s,"password":%s}' \
      "$(printf '%s' "$ADMIN_EMAIL" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
      "$(printf '%s' "$ADMIN_PASSWORD" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" |
      curl "${CURL_ARGS[@]}" -o "$BODY_FILE" -w '%{http_code}' \
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
fi

NOTE=${FIRMWARE_NOTE:-"deployed by make firmware-deploy ($STAGE)"}
REGISTER_CODE=$(
  python3 -c 'import json,sys; print(json.dumps({"version": sys.argv[1], "note": sys.argv[2]}))' "$VERSION" "$NOTE" |
    curl "${CURL_ARGS[@]}" -o "$BODY_FILE" -w '%{http_code}' \
      "${AUTH_ARGS[@]}" \
      -X POST -H 'Content-Type: application/json' --data-binary @- \
      "$FIRMWARES_URL"
)

case "$REGISTER_CODE" in
  201)
    echo "==> registered:"
    cat "$BODY_FILE"
    echo
    # サーバは S3 の実体から sha256 を算出する。手元の zip と一致しなければ、
    # 転送が欠けたか、アップロード後に zip を作り直している
    ZIP_FILE="$REPO_ROOT/atomcam_tools.zip"
    if [ -f "$ZIP_FILE" ]; then
      LOCAL_SHA=$(sha256sum "$ZIP_FILE" | awk '{print $1}')
      REMOTE_SHA=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["checksum"])' < "$BODY_FILE")
      if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
        echo >&2
        echo "error: the registered checksum does not match the local atomcam_tools.zip." >&2
        echo "       registered: $REMOTE_SHA" >&2
        echo "       local:      $LOCAL_SHA" >&2
        echo "       The object in S3 is not this build. Delete the registration and redeploy." >&2
        exit 1
      fi
      echo "==> checksum matches the local build"
    fi
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
    echo "error: the firmware object is not in S3. Did the upload succeed?" >&2
    exit 1
    ;;
  *)
    echo "error: registration failed (HTTP $REGISTER_CODE)" >&2
    cat "$BODY_FILE" >&2
    echo >&2
    exit 1
    ;;
esac
