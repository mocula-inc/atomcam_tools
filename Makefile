# Makefile
.SILENT:

DOCKER_IMAGE=$(shell sed -ne 's/^.*image:[ \t]*//p' docker-compose.yml)
DOCKER_ARCH=-$(subst x86_64,amd64,$(subst aarch64,arm64,$(shell uname -m)))

build:
	-docker pull ${DOCKER_IMAGE} | awk '{ print } /Downloaded newer image/ { system("docker-compose down"); }'
	docker-compose ls | grep atomcam_tools > /dev/null || docker-compose up -d
	docker-compose exec builder /src/buildscripts/build_all | tee rebuild_`date +"%Y%m%d_%H%M%S"`.log

build-local:
	docker-compose ls | grep atomcam_tools > /dev/null || docker-compose up -d
	docker-compose exec builder /src/buildscripts/build_all | tee rebuild_`date +"%Y%m%d_%H%M%S"`.log

docker-build:
	# build container
	docker build -t ${DOCKER_IMAGE}${DOCKER_ARCH} . | tee docker-build_`date +"%Y%m%d_%H%M%S"`.log

login:
	docker-compose ls | grep atomcam_tools > /dev/null || docker-compose up -d
	docker-compose exec builder bash

lima:
	[ "`uname -s`" = "Darwin" ] || exit 0
	[ -d ~/.lima/lima-docker ] || ( limactl start --tty=false lima-docker.yml && exit 0 )
	[ "`limactl list | awk '/lima-docker/ { print $2 }'`" = "Running" ] || limactl start lima-docker

# ビルド済み atomcam_tools.zip (configs/mocula.ver のバージョン) を
# mocula-backend の imageBucket の firmware/ota/{version}/ へ配置し、
# 続けてバックエンドへ登録する（登録まで済まないとカメラへ予約できない）。
#
# 前提: 先に make build を実行し、configs/mocula.ver がその zip のバージョンと
#       一致していること（両者の一致は検証していないので手動で確認する）。
#       同じバージョンで再デプロイすると S3 の実体だけが差し替わり、登録済みの
#       size/sha256 とずれて全カメラが検証失敗するため、必ずバージョンを上げる。
# 環境変数: MOCULA_ADMIN_EMAIL / MOCULA_ADMIN_PASSWORD が必要
#           (MOCULA_ADMIN_PASSWORD 未設定なら対話的に入力を求める)
# 使い方: make firmware-deploy CONFIG=dev1
firmware-deploy: firmware-upload firmware-register

# S3 への配置のみ
firmware-upload:
	cd cdk && npm install && npx cdk deploy --context config=$(CONFIG) --require-approval never

# バックエンドへの登録のみ（配置済みのものを登録し直す場合に使う）
firmware-register:
	./buildscripts/register_firmware.sh $(CONFIG)
