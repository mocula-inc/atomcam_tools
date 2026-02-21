# CLAUDE.md - atomcam_tools 開発ガイド

## プロジェクト概要

ATOM Cam（ATOMCam2, AtomSwing, WyzeCamV3）のファームウェアを拡張するツールキット。
Ingenic T31 SoC（MIPSEL アーキテクチャ）搭載カメラに WebUI、RTSP ストリーミング、NAS 対応、タイムラプス録画、Webhook 通知などの機能を追加する。

- **バージョン**: 2.5.19（`configs/atomhack.ver`）
- **作者**: Mitsuru Nakada
- **リポジトリ**: https://github.com/mnakada/atomcam_tools
- **ライセンス**: GPL3, LGPL, MIT, The Unlicense（複合）

## ディレクトリ構造

```
atomcam_tools/
├── buildscripts/          # ビルド自動化スクリプト群
├── configs/               # Buildroot, カーネル, BusyBox 設定ファイル
├── custompackages/        # カスタム Buildroot パッケージ（28個）
├── initramfs_skeleton/    # カーネル起動用の初期 RAM ファイルシステム
├── libcallback/           # iCamera_app フック用 C ライブラリ（LD_PRELOAD）
├── overlay_rootfs/        # ルートファイルシステムのオーバーレイ
│   ├── atom_patch/        #   /atom chroot 環境へのパッチ
│   ├── etc/init.d/        #   起動スクリプト（S##* 命名規則）
│   ├── scripts/           #   運用シェルスクリプト（17本）
│   └── var/www/cgi-bin/   #   CGI API エンドポイント
├── patches/               # Buildroot・カーネルパッチ
├── target/                # ビルド成果物（SD カード用）
├── web/                   # WebUI フロントエンド（Vue.js）
│   ├── source/vue/        #   Vue コンポーネント
│   ├── source/js/         #   JavaScript エントリポイント
│   └── frontend/          #   ビルド済み出力（生成物）
├── Dockerfile             # ビルド用 Docker イメージ定義
├── docker-compose.yml     # Docker Compose 設定
└── Makefile               # トップレベルビルド制御
```

## ビルド方法

### 前提条件
- Docker および Docker Compose

### ビルドコマンド

```bash
# フルビルド（Docker イメージ pull + ビルド、約1時間）
make build

# ローカルビルド（イメージ pull なし）
make build-local

# Docker イメージのビルド
make docker-build

# ビルドコンテナへのログイン（デバッグ用）
make login

# macOS Lima 環境
make lima
```

### ビルドプロセス概要

1. Docker コンテナ（Ubuntu 16.04 ベース）内でビルド実行
2. Buildroot 2016.02 でクロスコンパイル環境を構築
3. **glibc ツールチェーン**: メインルートファイルシステム用（`mipsel-ingenic-linux-gnu-`）
4. **uClibc ツールチェーン**: libcallback.so 用（`mipsel-ingenic-linux-uclibc-`）
5. Web フロントエンドを webpack でバンドル
6. カーネル + initramfs + ルートファイルシステムを生成
7. 成果物: `atomcam_tools.zip`（target/ ディレクトリにも個別ファイル出力）

### ビルド成果物（target/）

| ファイル | 説明 |
|---------|------|
| `factory_t31_ZMC6tiIDQN` | U-Boot + カーネル + initramfs |
| `rootfs_hack.squashfs` | 圧縮ルートファイルシステム |
| `rootfs_hack.ext2` | ext2 ルートファイルシステム（代替） |
| `hostname` | デバイスホスト名設定 |
| `authorized_keys` | SSH 公開鍵 |

## アーキテクチャの重要ポイント

### 二重 libc 環境（最重要）

本プロジェクトの最も重要なアーキテクチャ上の特徴:

- **glibc 環境**: メインシステム（Buildroot ベース）が動作
- **uClibc 環境**: オリジナルの iCamera_app が `/atom` chroot 内で動作
- **ブリッジ**: bind mount でファイルシステムを橋渡し
- `libcallback.so` は uClibc 環境でコンパイルする必要がある（iCamera_app と同じ libc）

### LD_PRELOAD フック機構

`libcallback.so` は `LD_PRELOAD` で iCamera_app に注入され、以下をフックする:
- `/system/lib/liblocalsdk.so` — ビデオ・オーディオ・デバイス制御
- `/system/lib/libimp.so` — エンコーダー設定
- `/lib/libc.so.0` — 標準 C ライブラリ関数

**オリジナルバイナリを一切変更せずに機能拡張を実現している。**

### ファイルシステムオーバーレイ

- `overlay_rootfs/` が Buildroot のベースファイルシステム上に重畳される
- `atom_patch/` でオリジナルカメラファイルを選択的に上書き
- bind mount で環境間のファイルアクセスを制御

## 主要コンポーネント詳細

### libcallback（C ライブラリ）

**場所**: `libcallback/`
**約 4,100 行の C コード、28 ソースファイル**

| ファイル | 機能 |
|---------|------|
| `command.c` | ソケットコマンド IF（localhost:4000） |
| `video_control.c` | コーデック設定（ビットレート, FPS, 露出等） |
| `video_callback.c` | H.264/H.265 フレームキャプチャ → v4l2loopback |
| `audio_callback.c` | PCM オーディオ → ALSA loopback |
| `motor.c` | パン/チルトモーター制御（AtomSwing） |
| `curl.c` | HTTP アップロードフィルタリング |
| `timelapse.c` | タイムラプス録画制御 |
| `webhook関連` | opendir.c, remove.c, wait_motion.c |

**コンパイル**: uClibc ツールチェーンで `-fPIC -shared` としてビルド

### Web UI（フロントエンド）

**場所**: `web/`
**技術スタック**: Vue.js 2.7.9 + Element UI 2.15.7 + Webpack 5

| ファイル | 説明 |
|---------|------|
| `web/source/vue/Setting.vue` | メイン設定ページ（82KB、最大のコンポーネント） |
| `web/source/vue/i18n-ja.yaml` | 日本語ローカライゼーション |
| `web/source/vue/i18n-en.yaml` | 英語ローカライゼーション |
| `web/source/index.html` | SPA コンテナ |
| `web/source/webrtc.html` | WebRTC ストリーミング IF |
| `web/webpack.config.js` | Webpack ビルド設定 |

**バックエンド**: lighttpd + CGI スクリプト（`overlay_rootfs/var/www/cgi-bin/`）

### 起動スクリプト（init.d）

**場所**: `overlay_rootfs/etc/init.d/`
**実行順序**:

1. `S15swap` → スワップファイル初期化
2. `S16fwupdate` → ファームウェア更新処理
3. `S17hackini` → カスタム設定ファイル読込
4. `S20mountfs` → bind mount セットアップ
5. `S41network` → ネットワーク初期化
6. `S55sshd` → SSH サーバー起動
7. `S61atomcam` → iCamera_app 起動（LD_PRELOAD + chroot）
8. `S70lighttpd` → Web サーバー起動
9. `S75rtspserver` → RTSP サーバー起動
10. `S91smb` → Samba サーバー起動

### カスタムパッケージ（主要なもの）

| パッケージ | 用途 |
|-----------|------|
| `go2rtc` | RTSP/WebRTC サーバー（Go 言語） |
| `v4l2rtspserver` | V4L2 デバイス用 RTSP サーバー |
| `ffmpeg` | 音声/映像変換・ストリーミング |
| `lighttpd` | 軽量 Web サーバー |
| `atbm_wifi` | WiFi ドライバー（ATBM6xxx） |
| `libcurl` | HTTP クライアント |
| `libtinyalsa` | ALSA オーディオライブラリ |

## 通信ポート

| ポート | プロトコル | サービス |
|-------|-----------|---------|
| 22 | TCP | SSH |
| 80 | TCP | WebUI（lighttpd） |
| 137,138,139,445 | TCP/UDP | Samba/CIFS |
| 4000 | TCP（localhost） | libcallback コマンドソケット |
| 5353 | UDP | mDNS/avahi |
| 8554, 8080 | TCP | RTSP |
| 8555 | TCP | HomeKit / WebRTC |

## 対応デバイスとファームウェア

| デバイス | ファームウェアバージョン |
|---------|----------------------|
| ATOMCam | 4.33.3.68, 4.33.3.73 |
| ATOMCam2 | 4.58.0.139, 4.58.0.154, 4.58.0.160 |
| AtomSwing | 4.37.1.152, 4.37.1.162, 4.37.1.166 |
| WyzeCamV3 | 4.36.9.139（実験的） |

## ターゲットハードウェア

- **SoC**: Ingenic T31
- **アーキテクチャ**: MIPS32R5（MIPSEL = リトルエンディアン）
- **カーネル**: Linux 3.10.14
- **ブートメディア**: MicroSD カード

## 設定ファイル

- **hack.ini**: SD カード上の永続設定ファイル（全ユーザー設定を保持）
- **atomhack.ver**: ツールのバージョン番号（`configs/atomhack.ver`）
- **デバイス判定**: `/atom/configs/.product_config` からモデル名を取得
  - `ATOM_CAKP1JZJP` = AtomSwing（パン/チルト対応）
  - `WYZE_CAKP2JFUS` = WyzeCamV3（機能制限あり）

## コーディング規約・注意事項

### シェルスクリプト
- BusyBox ash 互換で記述すること（bash 固有機能は使用不可）
- 起動スクリプトは `S[番号][名前]` の命名規則に従う
- `source` ではなく `.` を使用

### C コード（libcallback）
- C99 標準（`-std=gnu99`）
- uClibc ツールチェーンでコンパイル必須
- 共有ライブラリとしてビルド（`-fPIC -shared`）
- フック関数は `dlsym(RTLD_NEXT, ...)` でオリジナル関数を呼び出す

### Web フロントエンド
- Vue.js 2 のオプション API を使用
- Element UI コンポーネントライブラリ
- 日本語・英語の i18n 対応（yaml ファイル）
- ESLint によるコード品質チェック

### CGI スクリプト
- シェルスクリプトベース（BusyBox ash）
- `Content-Type` ヘッダーを必ず出力
- `hack_ini.cgi` が設定の読み書きの中心

## よく使うパス

| パス | 説明 |
|-----|------|
| `configs/atomhack.ver` | バージョン番号 |
| `web/source/vue/Setting.vue` | メイン WebUI コンポーネント |
| `web/source/vue/i18n-ja.yaml` | 日本語翻訳 |
| `libcallback/Makefile` | libcallback ビルド設定 |
| `libcallback/command.c` | コマンドソケット IF |
| `overlay_rootfs/etc/init.d/` | 起動スクリプト群 |
| `overlay_rootfs/scripts/` | 運用スクリプト群 |
| `overlay_rootfs/var/www/cgi-bin/` | Web API（CGI） |
| `buildscripts/build_all` | メインビルドスクリプト |
