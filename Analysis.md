# Analysis.md - atomcam_tools 完全解析レポート

## 目次

1. [プロジェクト全体像](#1-プロジェクト全体像)
2. [ディレクトリ構造と全ファイルの役割](#2-ディレクトリ構造と全ファイルの役割)
3. [データフローアーキテクチャ](#3-データフローアーキテクチャ)
4. [機能拡張ガイド](#4-機能拡張ガイド)

---

## 1. プロジェクト全体像

### 1.1 概要

ATOM Cam（Ingenic T31 SoC / MIPSEL）向けファームウェア拡張ツールキット。
オリジナルのカメラアプリケーション（iCamera_app）を**一切改変せず**、LD_PRELOAD による動的フックと chroot 環境の分離により機能拡張を実現している。

### 1.2 二重 libc アーキテクチャ（最重要）

```
┌──────────────────────────────────────────────────────────┐
│  メインシステム（glibc 環境 / Buildroot）                │
│  ├─ lighttpd (WebUI)                                     │
│  ├─ v4l2rtspserver / go2rtc (ストリーミング)             │
│  ├─ sshd, crond, smbd 等のシステムサービス               │
│  └─ scripts/ 配下の運用スクリプト群                      │
├──────────────────────────────────────────────────────────┤
│  /atom chroot 環境（uClibc 環境 / オリジナルファームウェア）│
│  ├─ iCamera_app（カメラ制御の本体）                      │
│  ├─ libcallback.so（LD_PRELOAD で注入されるフックライブラリ）│
│  ├─ assis, hl_client（補助サービス）                     │
│  └─ カーネルモジュール（ISP, オーディオ, モーター等）     │
├──────────────────────────────────────────────────────────┤
│  橋渡し                                                  │
│  ├─ bind mount でファイルシステムを接続                   │
│  ├─ TCP ソケット localhost:4000 でコマンド通信            │
│  └─ 名前付きパイプ /var/run/atomapp でイベント通知       │
└──────────────────────────────────────────────────────────┘
```

### 1.3 ビルドパイプライン概要

```
make build
  → Docker コンテナ起動（Ubuntu 16.04）
    → buildscripts/build_all
      → Buildroot make（glibc ツールチェーン）
        → カーネルビルド（initramfs 組み込み）
        → パッケージビルド（28 カスタムパッケージ）
        → post_fakeroot.sh
          → libcallback.so ビルド（uClibc ツールチェーン）
          → webpack ビルド（Vue.js WebUI）
        → rootfs squashfs 生成
      → local_build.sh
        → atomcam_tools.zip 生成
```

---

## 2. ディレクトリ構造と全ファイルの役割

### 2.1 トップレベル

| ファイル/ディレクトリ | 役割 |
|---|---|
| `Makefile` | ビルドエントリポイント。`make build`（フルビルド）、`make build-local`（ローカル）、`make docker-build`（イメージ構築）、`make login`（コンテナログイン） |
| `Dockerfile` | ビルド環境定義。Ubuntu 16.04 + Buildroot 2016.02 + クロスコンパイラ + Node.js v16 + Go 1.22 |
| `docker-compose.yml` | `atomtools/atomtools:Ver.2.5.5` イメージでコンテナを起動。プロジェクトルートを `/src` にマウント |
| `lima-docker.yml` | macOS 用 Lima VM 設定（8CPU, 12GB RAM, 80GB disk） |
| `README.md` | プロジェクト全体のドキュメント（33KB、日本語）。機能一覧、使い方、WebUI 説明 |
| `build.md` | ビルド手順書（日本語） |
| `LICENSE` | GPL3, LGPL, MIT, The Unlicense の複合ライセンス |
| `.gitignore` | ビルド成果物（`*.log`, `atomcam_tools.zip`, `factory_t31_*`, `rootfs_hack.*`）を除外 |

### 2.2 configs/ — 設定ファイル

| ファイル | 行数 | 役割 |
|---|---|---|
| `atomhack.ver` | 1 | バージョン番号（現在 `2.5.19`） |
| `atomcam_defconfig` | 2288 | Buildroot メイン設定。アーキテクチャ（MIPSEL）、パッケージ選択、ツールチェーン設定 |
| `kernel.config` | 2163 | Linux 3.10.14 カーネル設定。T31 SoC、ファイルシステム（squashfs/ext2/exFAT/CIFS）、V4L2、ALSA |
| `busybox.config` | 1069 | メインルートファイルシステム用 BusyBox 設定 |
| `busybox-init.config` | 32584 | initramfs 用最小限 BusyBox 設定 |
| `crosstools_config` | 847 | uClibc クロスコンパイラ設定（crosstool-ng 1.26.0）。GCC 4.9.4 + uClibc-ng 1.0.43 |

### 2.3 buildscripts/ — ビルド自動化

| ファイル | 行数 | 役割 | 呼び出し元 |
|---|---|---|---|
| `build_all` | ~30 | メインビルドスクリプト。defconfig ロード → カスタムパッケージ同期（差分検知で変更分のみ再ビルド）→ `make` 実行 | Makefile |
| `setup_buildroot.sh` | ~100 | 初回セットアップ。パッチ適用 → Buildroot 設定 → uClibc ツールチェーン構築 → Node.js/Go インストール → 初回ビルド | Dockerfile |
| `linux_prebuild_hook.sh` | 3 | カーネルビルド前フック。`make_initramfs.sh` を呼び出し | Buildroot（パッチで追加されたフック） |
| `make_initramfs.sh` | ~50 | initramfs 構築。busybox-init/dosfstools-init/exfatprogs-init をコピー → cpio アーカイブ生成（2MB 上限） | linux_prebuild_hook.sh |
| `post_fakeroot.sh` | ~60 | rootfs 後処理。**libcallback.so の uClibc ビルド** → **webpack フロントエンドビルド** → 成果物をターゲットにコピー | Buildroot（ROOTFS_POST_FAKEROOT_HOOKS） |
| `post_image.sh` | ~10 | イメージ後処理。`local_build.sh` 呼び出し + バージョンファイルコピー | Buildroot（ROOTFS_POST_IMAGE_HOOKS） |
| `local_build.sh` | ~30 | 最終パッケージング。uImage.lzma → factory_t31_ZMC6tiIDQN、rootfs.squashfs → rootfs_hack.squashfs、ZIP 作成 | post_image.sh |

### 2.4 patches/ — パッチ

| ファイル | サイズ | 対象 | 目的 |
|---|---|---|---|
| `add_fp_no_fused_madd.patch` | 1.2KB | Buildroot ツールチェーンラッパー | `-ffp-contract=off` を追加。MIPS FPU 互換性確保 |
| `linux_makefile.patch` | 0.5KB | Buildroot の linux.mk | カーネルビルド前フック（initramfs 再生成）を追加 |
| `linux_uclibc_hevc.patch` | 0.7KB | uClibc sysroot の videodev2.h | HEVC (H.265) ピクセルフォーマット定義を追加 |
| `kernel/linux-drivers-mmc-host-jzmmc_v12.patch` | 2.9KB | カーネル MMC ドライバー | Ingenic T31 SD カードコントローラーサポート |
| `kernel/linux-drivers-net-wireless-bcmdhd_1_141_66.patch` | 280KB | カーネル WiFi ドライバー | Broadcom WiFi ドライバー追加 |
| `kernel/linux-fs-cifs.patch` | 3.7KB | カーネル FS | CIFS/SMB ファイルシステムサポート |
| `kernel/linux-fs-exfat.patch` | 393KB | カーネル FS | exFAT ファイルシステムサポート |
| `kernel/linux-sound-drivers-aloop.patch` | 0.8KB | カーネルサウンド | ALSA ループバックデバイス（アプリ間オーディオルーティング） |
| `kernel/linux-v4l2-hevc.patch` | 0.8KB | カーネル V4L2 | H.265 コーデック列挙サポート |

### 2.5 initramfs_skeleton/ — カーネル起動用初期ファイルシステム

| ファイル | 行数 | 役割 |
|---|---|---|
| `init` | 83 | **ブートストラップスクリプト**。SD カード検出（FAT/exFAT 判定）→ ファームウェア更新チェック → rootfs マウント（squashfs or ext2）→ `switch_root` でメインシステムに移行 |
| `bin/` | — | ビルド時に busybox-init, fsck.fat, fsck.exfat がコピーされる |
| `README.md` | — | ビルド手順説明 |

**ブートシーケンス:**
1. devtmpfs/proc/sysfs マウント
2. SD カードパーティション検出・マウント
3. `/rootfs/update/atomcam_tools.zip` があれば展開・検証・インストール
4. rootfs_hack.squashfs（or ext2）を `/newroot` にマウント
5. `switch_root /newroot /sbin/init` でメインシステムに制御移行

### 2.6 overlay_rootfs/ — ルートファイルシステムオーバーレイ

#### 2.6.1 etc/init.d/ — 起動スクリプト（実行順）

| スクリプト | 行数 | 役割 | 依存関係 |
|---|---|---|---|
| `rcS` | 33 | マスター起動スクリプト。`/etc/environment` を読み込み、S??* を番号順に実行 | — |
| `S13gpio` | 26 | GPIO77 初期化（カメラ関連ピン設定） | — |
| `S15swap` | 30 | `/media/mmc/swap` に 128MB スワップファイル作成・有効化 | SD カードマウント済み |
| `S16fwupdate` | 75 | MTD7 の FWGRADEUP フラグを読み、ステージング済み更新をフラッシュに書き込み | — |
| `S17hackini` | 24 | `hack_ini_reconfig.sh` で設定バージョン移行 → `/tmp/hack.ini` 作成 | SD カード |
| `S20mountfs` | 108 | **最重要**: squashfs `/atom` マウント → `/dev/mtdblock3` → configs 展開 → bind mount 群セットアップ | S17hackini |
| `S21rootkeys` | 26 | `/media/mmc/authorized_keys` → `/root/.ssh/authorized_keys` コピー | S20mountfs |
| `S40hostname` | 26 | ホスト名設定。`/media/mmc/hostname` を `/etc/hostname` に bind mount | S20mountfs |
| `S41network` | 22 | `network_init.sh` に委譲。WiFi モジュール検出・ドライバーロード・wpa_supplicant 起動・DHCP 取得 | S40hostname |
| `S42ntpd` | 32 | NTP 同期（ntp.nict.jp）。失敗時は `/media/mmc/time.ini` のタイムスタンプを使用 | S41network |
| `S43timezone.env` | 34 | `/media/mmc/TZ` からタイムゾーン設定。`.user_config` に UTC オフセット書き込み | S42ntpd |
| `S53crond` | 35 | cron デーモン起動（ログレベル 8） | S43timezone |
| `S55sshd` | 50 | SSH サーバー起動。ホスト鍵がなければ自動生成。`authorized_keys` 必須 | S21rootkeys |
| `S60webhook` | 24 | `/var/run/atomapp` 名前付きパイプ作成 → `webhook.sh` をバックグラウンド起動 | — |
| `S61atomcam` | 116 | **最重要**: atom_patch の bind mount → v4l2loopback カーネルモジュールロード → `chroot /atom` で iCamera_app 起動（LD_PRELOAD=libcallback.so）→ 起動確認（20回リトライ）→ `set_icamera_config.sh` で設定適用 | S20mountfs, S60webhook |
| `S62webcontrol` | 26 | `webcmd.sh`（コマンドディスパッチャ）+ `cruise.sh`（PTZ 巡回制御）をバックグラウンド起動 | S61atomcam |
| `S70lighttpd` | 23 | `lighttpd.sh on` で Web サーバー起動（ポート 80） | S62webcontrol |
| `S75rtspserver` | 23 | `rtspserver.sh` をバックグラウンド起動（RTSP/RTMP/WebRTC） | S61atomcam |
| `S91smb` | 27 | `samba.sh` で smbd/nmbd 起動（hack.ini の設定に依存） | S20mountfs |
| `S99bootlog` | 18 | ブートタイムスタンプとルーターアドレスをログに記録 | 全スクリプト |

#### 2.6.2 scripts/ — 運用スクリプト

| スクリプト | 行数 | 役割 | 呼び出し元 |
|---|---|---|---|
| `cmd` | 2 | `echo "$*" \| nc localhost 4000` — libcallback へのコマンド送信ラッパー | 各スクリプトから |
| `webcmd.sh` | 199 | **コマンドディスパッチャ**。`/var/run/webcmd` FIFO からコマンド読み取り → 処理 → `/var/run/webres` FIFO にレスポンス書き込み。対応コマンド: `reboot`, `setCron`, `setwebhook`, `hostname`, `mp4write`, `framerate`, `bitrate`, `alarm`, `curl`, `skipRecJpeg`, `flip`, `rtspserver`, `cruise`, `lighttpd`, `samba`, `sderase`, `update_status`, `update`, `posrec`, `moveinit` | S62webcontrol, cmd.cgi |
| `webhook.sh` | 101 | iCamera_app の stdout（`/var/run/atomapp`）を監視し、イベント（alarmEvent, recognitionNotify, timelapseEvent 等）を検出 → WEBHOOK_URL に JSON POST 送信 | S60webhook |
| `rtspserver.sh` | 182 | RTSP/RTMP/WebRTC ストリーミング管理。v4l2rtspserver 起動（ポート 8554/8080）+ go2rtc 起動（RTMP, HomeKit, WebRTC）。RTMP_RESTART 設定による定期再起動対応 | S75rtspserver, webcmd.sh |
| `cruise.sh` | 66 | PTZ カメラ巡回制御。CRUISE_LIST をセミコロン区切りで解析し、`move`/`detect`/`follow`/`sleep` コマンドをループ実行。ATOM_CAKP1JZJP モデル専用 | S62webcontrol |
| `lighttpd.sh` | 34 | lighttpd ライフサイクル管理（`on`/`off`/`restart`/`watchdog`）。hack.ini の DIGEST 設定で認証設定 | S70lighttpd, webcmd.sh, cron |
| `network_init.sh` | 106 | ネットワーク初期化。USB Ethernet 検出（r8152, asix 等）→ WiFi モジュール検出（ベンダーID: 0x024c=RTL8189, 0x007a=ATBM603X, 0x5653=SSV6x5x, 0x424c=Broadcom）→ wpa_supplicant 設定 → DHCP 取得 | S41network |
| `set_icamera_config.sh` | 52 | hack.ini と video_isp.conf の設定を libcallback コマンドに変換して適用。ビデオ（ビットレート, FPS）、オーディオ、MP4 書き込みモード、アラーム周期等 | S61atomcam |
| `timelapse.sh` | 62 | タイムラプス管理。開始: `cmd timelapse <file> <interval> <count> <fps>`。完了時: CIFS コピー、SD 保存、Webhook 通知。`timelapse_hook.sh` による拡張ポイントあり | cron, webhook.sh |
| `hack_ini_reconfig.sh` | 187 | hack.ini のバージョン移行（1.0.0→1.0.1→1.0.2）。設定キー名変更、フォーマット変換、video_isp.conf の移行 | S17hackini |
| `set_crontab.sh` | 34 | hack.ini から動的に crontab 生成。システムジョブ（ログローテーション 15分毎、クリーンアップ 1時間毎）+ REBOOT_SCHEDULE + TIMELAPSE_SCHEDULE | webcmd.sh |
| `health_check.sh` | 63 | ネットワーク監視。ルーターへの ping → 失敗時 MONITORING_NETWORK=on ならネットワーク再起動、MONITORING_REBOOT=on なら 3 回失敗後にリブート。HEALTHCHECK_PING_URL への生存通知 | cron（毎分） |
| `samba.sh` | 22 | Samba 制御（`on`/`off`）。STORAGE_SDCARD_PUBLISH=on で smbd/nmbd 起動。共有: record, time_lapse, alarm_record, update | S91smb, webcmd.sh |
| `motor_init` | 40 | PTZ モーター初期化。`.user_config` から slide_x/slide_y 読み取り → horSwitch/verSwitch 考慮 → デフォルト位置に移動 | webhook.sh（モーターリセット時）, webcmd.sh |
| `remove_old.sh` | 51 | 古い録画ファイルの自動削除。PERIODICREC/ALARMREC/TIMELAPSE ごとに SD カードと CIFS 個別に保持日数設定。`*._mp4`, `*.stsz` の 3 日超テンポラリも削除 | cron（1時間毎） |
| `memory_check.sh` | 6 | 空きメモリと /tmp 容量をログ出力 | cron（10分毎） |
| `reboot.sh` | 14 | スケジュールリブート。タイムラプス停止 → iCamera_app 終了（SIGUSR2）→ sync → reboot | cron |

#### 2.6.3 var/www/cgi-bin/ — Web API エンドポイント

| CGI | 行数 | メソッド | 役割 |
|---|---|---|---|
| `hack_ini.cgi` | 45 | **GET**: hack.ini の全設定 + appver, PRODUCT_MODEL, HOSTNAME, KERNELVER, ATOMHACKVER, HWADDR を返却。**POST**: JSON を受け取り `/media/mmc/hack.ini`（永続）と `/tmp/hack.ini`（実行時）に書き込み | 設定の読み書きの中核 |
| `cmd.cgi` | 86 | **GET**: `name=status` で TIMELAPSE/TIMESTAMP/CENTER/FLIP/MEDIASIZE/MOTORPOS を返却。`name=latest-ver` で GitHub 最新バージョン問い合わせ。**POST**: `{"exec":"コマンド"}` を受け取り、`port=socket` なら localhost:4000 に直接送信、それ以外は `/var/run/webcmd` FIFO 経由で `webcmd.sh` に委譲 | コマンド実行 |
| `get_jpeg.cgi` | 4 | **GET**: `echo jpeg \| nc localhost 4000` で libcallback から JPEG フレームを取得して返却 | ライブ画像取得 |
| `video_isp.cgi` | 25 | **GET**: `/media/mmc/video_isp.conf` の内容を返却。**POST**: JSON ISP パラメータを受け取り video_isp.conf に書き込み + キャッシュドロップ | ISP パラメータ調整 |
| `watermark.cgi` | 14 | **GET**: `/media/mmc/watermark.bgra` のバイナリデータ返却。**POST**: BGRA 画像を受け取り保存 → `watermark update` コマンドで反映 | ロゴ/透かし管理 |
| `hello.cgi` | 24 | **GET**: `/var/www/SDPath/<path>` のディレクトリ一覧を返却 | SD カードファイルブラウザ（レガシー） |

#### 2.6.4 atom_patch/ — オリジナルファームウェアのパッチ

| パス | 役割 |
|---|---|
| `system_bin/atom_init.sh`（36行） | AtomCam モデル用初期化。カーネルモジュールロード（tx-isp-t31, audio, avpu, motor 等）→ assis/hl_client/iCamera_app 起動。**`LD_PRELOAD=/lib/modules/libcallback.so` で iCamera_app にフック注入** |
| `system_bin/wyze_init.sh`（50行） | WyzeCam モデル用初期化。異なるオーディオモード、avpu クロック設定、syslogd/sinker サービス追加 |
| `system_bin/mount_cifs.sh`（40行） | CIFS マウント。SMB 3.0 → 2.1 → 2.0 フォールバック付きリトライ |
| `bin/null.sh`（3行） | ヌルスタブ。boa（元の Web サーバー）や restart_wlan0.sh を無効化 |
| `bin/busybox, cp, mv, rm, killall, wpa_cli, hostapd` | パッチ済み/置換バイナリ |
| `sbin/flash_erase` | フラッシュプログラミングツール置換 |
| `etc/passwd, group, nsswitch.conf` | 最小ユーザーDB（root のみ） |
| `etc/profile` | 拡張 PATH + LD_LIBRARY_PATH + TZ 設定 |
| `etc/sysctl.conf`（28行） | TCP チューニング（FIN タイムアウト 2s、TIME-WAIT 再利用、バックログ増加等）。ストリーミング最適化 |
| `etc/fstab, etc/inittab` | chroot 環境用マウント設定 |

#### 2.6.5 etc/ — システム設定

| ファイル | 役割 |
|---|---|
| `lighttpd/lighttpd.conf` | Web サーバー設定。ポート 80、CGI（.cgi = sh）、Digest 認証、gzip 圧縮、`/sdcard/` → `/media/mmc/record` マッピング |
| `samba/smb.conf` | Samba 設定。SMB2+、ゲストアクセス。共有: record, time_lapse, alarm_record, update |
| `environment` | `TZ=JST-9`（デフォルトタイムゾーン） |
| `fstab` | proc, devpts, tmpfs, sysfs マウント |
| `watermark.bgra` | デフォルトのロゴ画像（BGRA フォーマット） |
| `logrotate.conf` + `logrotate.d/` | atomhack.conf, lighttpd.conf, messages.conf のログローテーション設定 |
| `ssl/certs/` | ルート CA 証明書群（100+ ファイル） |

### 2.7 libcallback/ — iCamera_app フックライブラリ

**コンパイル**: uClibc ツールチェーン（`mipsel-ingenic-linux-uclibc-gcc -fPIC -std=gnu99 -shared -ldl -ltinyalsa -lm`）

#### フック機構

`dlsym(dlopen("/path/to/lib.so", RTLD_LAZY), "function_name")` でオリジナル関数のアドレスを取得し、同名の関数を `libcallback.so` 内に定義して置き換える。オリジナル関数は保存されたポインタ経由で呼び出し可能。

#### ソースファイル一覧

| ファイル | 行数 | フック対象 | 機能 |
|---|---|---|---|
| **command.c** | ~200 | なし | **コマンドディスパッチャ**。TCP ソケット localhost:4000 で待受。17 コマンド（video, audio, jpeg, move, waitMotion, night, aplay, curl, timelapse, mp4write, alarm, config, alarmConfig, center, property, watermark, skipRecJpeg）をハンドラに振り分け |
| **video_callback.c** | ~250 | `local_sdk_video_set_encode_frame_callback()` | H.264/H.265 エンコード済みフレームを傍受し v4l2loopback デバイス（/dev/video0-2）に書き込み。AtomCam: 3ch（1080p H264, 360p HEVC, 1080p HEVC）、WyzeCam: 2ch（1080p H264, 320p H264） |
| **video_control.c** | ~300 | `local_sdk_video_set_kbps()`, `IMP_Encoder_CreateChn()` | ビットレート/FPS/GOP 設定の上書き。ISP パラメータ（コントラスト、明度、彩度、シャープネス、2D-NR、3D-NR、DPC、DRC、ハイライト、ゲイン、露出）制御 |
| **audio_callback.c** | ~150 | `local_sdk_audio_set_pcm_frame_callback()` | PCM オーディオフレームを ALSA ループバックに書き込み。AtomCam: 8kHz/3ch、WyzeCam: 16kHz/2ch |
| **audio_control.c** | ~120 | `IMP_AI_Enable*()` | オーディオ設定（HPF, AGC, ノイズ抑制, AEC, ボリューム, ゲイン, ALC ゲイン） |
| **motor.c** | ~180 | `local_sdk_motor_*()` | パン/チルト制御。範囲: パン 0-355°、チルト 0-180°、速度 1-9。hflip/vflip 考慮。移動完了コールバック待ち |
| **curl.c** | ~200 | `curl_easy_perform()` | HTTP アップロード制御。アラーム動画のアップロードレート制限（30-300 秒）、アップロード無効化。AtomCam/WyzeCam でセッション構造体のオフセットが異なる |
| **timelapse.c** | ~350 | なし | タイムラプス録画ステートマシン（Ready → Recording → ConvertToMP4 → Ready）。STSZ ヘッダー管理、MP4 ヘッダー生成（1920x1080 H264 固定） |
| **jpeg.c** | ~150 | `IMP_Encoder_*()` | JPEG スナップショット。タスクキュー（最大 8）+ 専用スレッド。HTTP ヘッダー付き/なし対応 |
| **property.c** | ~250 | `ProtocolSetProperty()` | P2P プロトコル経由のデバイスプロパティ設定。nightVision, motionDet, motionLevel, soundDet, recordType, indicator, rotate, audioRec, timestamp, watermark, motionArea 等 18 種 |
| **user_config.c** | ~150 | `strncmp()` | iCamera_app 内部の設定テーブルをメモリから抽出（"indicator" キー比較時にアドレス取得）。設定の読み書き（RAM 上のみ） |
| **alarm_interval.c** | ~30 | なし | グローバルアラーム周期設定（30-300 秒、デフォルト 300） |
| **alarm_config.c** | ~100 | `memset()` | アラームタイプ別設定。memset フック時にレジスタ検査（`asm volatile`）でテーブルアドレス取得。15 タイプ × 個別間隔 |
| **mp4write.c** | ~100 | `mp4write_start_handler()`, `snprintf()` | MP4 テンポラリファイルを RAM (/tmp) から SD カード (/media/mmc/tmp) にリダイレクト。RAM 枯渇防止 |
| **wait_motion.c** | ~150 | `local_sdk_video_osd_update_rect()` | モーション検出矩形の傍受。矩形位置からパン/チルトオフセット計算。`pthread_cond_timedwait` によるタイムアウト付き待機 |
| **night_light.c** | ~50 | `local_sdk_*_night_light()` | ナイトビジョン制御（on/off/auto） |
| **watermark.c** | ~80 | `IMP_OSD_SetRgnAttr()` | ウォーターマーク（ロゴ）オーバーレイ。BGRA 画像のロード・更新 |
| **center.c** | ~50 | `IMP_OSD_*()` | センターマーク（十字線）OSD 表示切替 |
| **audio_play.c** | ~80 | なし | WAV ファイル再生（PCM 出力） |
| **opendir.c** | ~30 | `opendir()` | タイムラプスイベント検出。特定パスの opendir を監視し `[webhook] time_lapse_event` を stdout に出力 |
| **remove.c** | ~30 | `remove()` | タイムラプス完了検出。特定パスの remove を監視し `[webhook] time_lapse_finish` を stdout に出力 |
| **gmtime_r.c** | ~30 | `gmtime_r()` | モーター移動中に無効な曜日（8）を返すことで AI モーション検出を無効化 |
| **mmc_mount.c** | ~20 | `local_sdk_device_open()` | SD カードの二重マウント防止。ダミーマウントパスを返す |
| **mmc_format.c** | ~10 | `local_sdk_device_mmc_format()` | SD カードフォーマット防止（何もせず 0 を返す） |
| **get_jpeg.c** | ~20 | `local_sdk_video_get_jpeg()` | 連続録画時の JPEG 記録スキップ |
| **freopen.c** | ~15 | `freopen()` | stdout リダイレクト防止（ログ出力維持） |
| **setlinebuf.c** | ~5 | コンストラクタで `setvbuf()` | stdout を行バッファリングに設定（イベント検出のため） |
| **usb_power.c** | ~10 | `local_sdk_usb_power_on/off()` | USB 電源制御の無効化（no-op） |
| **Makefile** | ~20 | — | ビルド定義。`CROSS_COMPILE` 環境変数使用 |
| **libcallback_hook.md** | — | — | 全フックの日本語ドキュメント |

### 2.8 web/ — WebUI フロントエンド

#### ビルド設定

| ファイル | 役割 |
|---|---|
| `package.json` | 依存関係: vue 2.7.9, vue-i18n 8.27.2, element-ui 2.15.7, axios 0.27.2, qrcode.vue 1.7.0, js-md5 0.7.3。ビルド: webpack 5.74.0, vue-loader 15.10.0, eslint |
| `webpack.config.js` | エントリ: `source/js/index.js`, `source/css/dirindex.css`, `source/webrtc.html`。出力: `frontend/` に `[name]_[chunkhash].js`。gzip 圧縮プラグイン有効。ESLint プラグイン（セミコロン必須、トレイリングカンマ等） |

#### Vue コンポーネント

| ファイル | 行数 | 役割 |
|---|---|---|
| `source/js/index.js` | 50 | エントリポイント。Vue + VueI18n + Element UI 初期化。ロケール日本語デフォルト |
| **`source/vue/Setting.vue`** | **1774** | **メインコンポーネント（最大・最重要）**。11 タブ構成の SPA。config オブジェクト（130+ プロパティ）管理。API 通信、設定保存（Submit）、カメラ制御 |
| `source/vue/SettingSwitch.vue` | ~80 | トグルスイッチ。on/off またはカスタムラベル対応 |
| `source/vue/SettingSelect.vue` | ~60 | ラジオボタン群。i18n キーからラベル自動取得 |
| `source/vue/SettingInput.vue` | ~70 | テキスト/パスワード/読み取り専用入力 |
| `source/vue/SettingInputNumber.vue` | ~90 | 数値入力 + on/off トグル。単位表示対応 |
| `source/vue/SettingButton.vue` | ~50 | アクションボタン。スロット対応 |
| `source/vue/SettingDangerButton.vue` | ~60 | 危険操作ボタン。ロックスイッチ付き（明示的に有効化が必要） |
| `source/vue/SettingComment.vue` | ~40 | 情報表示コンポーネント |
| `source/vue/SettingSchedule.vue` | ~150 | スケジュールエディタ。曜日選択 + 時間範囲 or タイムラプス（開始時刻+間隔+回数）。終了時刻自動計算 |
| `source/vue/SettingCruise.vue` | ~120 | PTZ 巡回ウェイポイント編集。パン/チルト、速度、待機時間、検出/追従モード |
| `source/vue/SettingProgress.vue` | ~40 | プログレスバー |
| `source/vue/SettingSlider.vue` | ~70 | スライダー。min/max/default マーカー + リセットボタン |
| `source/vue/i18n-ja.yaml` | ~350 | 日本語ローカライゼーション |
| `source/vue/i18n-en.yaml` | ~340 | 英語ローカライゼーション |

#### Setting.vue のタブ構成

| # | タブ名 | 主要機能 |
|---|---|---|
| 1 | カメラ画像 | JPEG ライブビュー（500ms 更新）、パン/チルトスライダー、ナイトビジョン切替 |
| 2 | カメラ設定 | ナイトビジョン、モーション/サウンド検出、録画タイプ、LED 表示、ISP 詳細設定（コントラスト等 16 パラメータ）、モーション検出エリア編集（SVG ドラッグ） |
| 3 | SD カード | iframe で `/sdcard` ディレクトリ表示、容量表示 |
| 4 | 録画設定 | 定期録画（SD/NAS パス、自動削除、保持日数、スケジュール）、アラーム録画（同様） |
| 5 | タイムラプス | SD/NAS 録画設定、スケジュール（開始時刻+間隔+回数）、進捗バー、中止ボタン |
| 6 | メディア設定 | SD カード（SMB 共有、ダイレクト書き込み、消去）、NAS（サーバーパス、アカウント） |
| 7 | ストリーミング | RTSP Main/Sub/HEVC（オーディオ形式選択）、HomeKit（QR コード、ペアリング管理）、RTMP（URL 設定、定期再起動）、WebRTC |
| 8 | イベント通知 | Webhook URL、10+ イベントタイプの個別トグル |
| 9 | 巡回設定 | 初期位置キャリブレーション、巡回リスト編集（ウェイポイント追加/削除）。AtomSwing 専用 |
| 10 | システム設定 | デバイス名、認証、センサー周期、AWS アップロード、FPS、ビットレート（AVC/HEVC/Sub）、ウォーターマーク PNG アップロード |
| 11 | メンテナンス | ネットワーク監視、ヘルスチェック、更新（GitHub/カスタム ZIP）、定期リブート |

#### HTML テンプレート

| ファイル | 役割 |
|---|---|
| `source/index.html` | SPA コンテナ。`<div id="app">` にマウント |
| `source/webrtc.html` | WebRTC ストリーミングビューア。go2rtc の WebSocket API を使用 |

#### CSS

| ファイル | 役割 |
|---|---|
| `source/css/localStyle.css` | メインスタイル。Element UI カスタマイズ、固定レイアウト（100vh）、モバイルレスポンシブ |
| `source/css/dirindex.css` | SD カードディレクトリ一覧用スタイル |

### 2.9 custompackages/ — Buildroot カスタムパッケージ

各パッケージは `Config.in`（メニュー定義）と `<package>.mk`（ビルドルール）で構成。

| パッケージ | バージョン/ソース | 役割 |
|---|---|---|
| **go2rtc** | Git コミット指定 | Go 製 RTSP/RTMP/WebRTC/HomeKit サーバー。4 つのパッチ適用（HomeKit ペアリング API、アナウンス、QR コード、WebRTC 切替）。upx 圧縮 |
| **ffmpeg** | 7.0.1 | 音声/映像変換・ストリーミング。MIPS 最適化設定付き |
| **v4l2rtspserver** | Git | V4L2 デバイス用 RTSP サーバー |
| **v4l2loopback** | Git | 仮想ビデオループバックデバイス（カーネルモジュール） |
| **v4l2cpp** | Git | V4L2 C++ ラッパー |
| **lighttpd** | 1.4.39 | 軽量 Web サーバー（OpenSSL + WebDAV 対応） |
| **atbm_wifi** | — | ATBM6xxx WiFi ドライバー |
| **libcurl** | — | HTTP クライアントライブラリ |
| **libtinyalsa** | — | 軽量 ALSA オーディオライブラリ |
| **h264bitstream** | — | H.264 ビットストリームパーサー |
| **fdk-aac** | — | Fraunhofer AAC エンコーダー |
| **opus** | — | Opus オーディオコーデック |
| **ingenic_videocap** | — | Ingenic SDK ビデオキャプチャ |
| **ingenic_samples** | — | Ingenic SDK サンプルコード・ヘッダー |
| **collections_c** | — | C データ構造ライブラリ |
| **log4cpp** | — | C++ ロギング |
| **logconv** | — | ログ変換ユーティリティ |
| **micropython** / **micropython-lib** | — | MicroPython ランタイム + 標準ライブラリ |
| **mjpg-streamer** | — | MJPEG ストリーミング |
| **busybox-init** | — | initramfs 用最小 BusyBox |
| **dosfstools-init** | — | initramfs 用 FAT ツール |
| **exfatprogs-init** | — | initramfs 用 exFAT ツール |
| **ncurses** | — | ターミナル制御ライブラリ |
| **oss** | — | Open Sound System |
| **live555** | — | RTSP/RTP サーバーライブラリ |

### 2.10 target/ — ビルド成果物

| ファイル | 役割 |
|---|---|
| `factory_t31_ZMC6tiIDQN` | U-Boot + Linux カーネル + 組み込み initramfs。SD カードの先頭パーティションに配置 |
| `rootfs_hack.squashfs` | 圧縮ルートファイルシステム（メイン）。SD カードに配置 |
| `rootfs_hack.ext2` | ext2 ルートファイルシステム（代替、書き込み可能） |
| `hostname` | デバイスホスト名（デフォルト "atomcam"） |
| `authorized_keys` | SSH 公開鍵ファイル |

---

## 3. データフローアーキテクチャ

### 3.1 設定変更の伝搬フロー

```
  ユーザー操作（WebUI）
       │
       ▼
  Setting.vue の Submit()
  ├─ config オブジェクトと oldConfig の差分を検出
  ├─ POST ./cgi-bin/hack_ini.cgi  ← 永続設定保存
  │       │
  │       ▼
  │   /media/mmc/hack.ini（永続）
  │   /tmp/hack.ini（実行時コピー）
  │
  └─ POST ./cgi-bin/cmd.cgi  ← コマンド実行
          │
          ├─ port=socket の場合
          │       │
          │       ▼
          │   TCP localhost:4000
          │       │
          │       ▼
          │   libcallback command.c
          │       │
          │       ▼
          │   各ハンドラ → IMP/LocalSDK API → ハードウェア
          │
          └─ port 未指定の場合
                  │
                  ▼
              /var/run/webcmd FIFO
                  │
                  ▼
              webcmd.sh（コマンドディスパッチャ）
                  │
                  ├─ /scripts/cmd → localhost:4000
                  ├─ サービス再起動（lighttpd, rtspserver 等）
                  ├─ crontab 再生成
                  └─ システム操作（reboot, update 等）
```

### 3.2 映像ストリーミングフロー

```
  カメラセンサー（Ingenic T31 ISP）
       │
       ▼
  iCamera_app（H.264/H.265 エンコード）
       │
       ├─ libcallback video_callback.c が傍受
       │       │
       │       ▼
       │   v4l2loopback（/dev/video0, /dev/video1, /dev/video2）
       │       │
       │       ├─ v4l2rtspserver → RTSP (8554) / HTTP (8080)
       │       │
       │       └─ go2rtc
       │           ├─ RTMP（外部サーバーに配信）
       │           ├─ HomeKit（8555）
       │           └─ WebRTC（8555）
       │
       └─ オリジナルコールバック → 録画/クラウドアップロード
```

### 3.3 イベント通知フロー

```
  iCamera_app stdout
       │
       ▼
  /var/run/atomapp（名前付きパイプ）
       │
       ▼
  webhook.sh（awk でイベント解析）
       │
       ├─ alarmEvent → curl POST WEBHOOK_URL（JSON）
       ├─ recognitionNotify → curl POST WEBHOOK_URL（JSON）
       ├─ timelapseEvent → timelapse.sh 呼び出し
       └─ motor reset → motor_init 呼び出し
```

### 3.4 PTZ 巡回制御フロー

```
  hack.ini CRUISE_LIST
       │
       ▼
  cruise.sh（セミコロン区切り解析・無限ループ）
       │
       ├─ move <pan> <tilt> [speed]
       │       → /scripts/cmd move ... → localhost:4000 → motor.c
       │
       ├─ detect <wait> <timeout>
       │       → /scripts/cmd waitMotion ... → wait_motion.c
       │       → モーション検出時: 検出座標を返却
       │
       ├─ follow <wait> <timeout> [speed]
       │       → 検出座標に追従移動
       │
       └─ sleep <seconds>
```

---

## 4. 機能拡張ガイド

### 4.1 新しい設定項目を WebUI に追加する

**変更が必要なファイル:** 4 箇所

#### ステップ 1: config キーを追加（Setting.vue）

`web/source/vue/Setting.vue` の `data()` 内 `config` オブジェクトにデフォルト値を追加:

```javascript
data() {
  return {
    config: {
      MY_NEW_SETTING: 'off',  // ← 追加
      // ...既存の設定
    }
  }
}
```

#### ステップ 2: i18n 翻訳を追加

`web/source/vue/i18n-ja.yaml`:
```yaml
myNewSetting:
  title: 新しい設定
  tooltip: この設定の説明文
```

`web/source/vue/i18n-en.yaml`:
```yaml
myNewSetting:
  title: New Setting
  tooltip: Description of this setting
```

#### ステップ 3: UI コンポーネントを追加（Setting.vue テンプレート）

適切なタブ内に追加:
```vue
<!-- トグルスイッチの場合 -->
<SettingSwitch i18n="myNewSetting" v-model="config.MY_NEW_SETTING" />

<!-- 数値入力の場合 -->
<SettingInputNumber i18n="myNumber" v-model="config.MY_NUMBER"
  :min="1" :max="100" :span="3" />

<!-- セレクトの場合 -->
<SettingSelect i18n="mySelect" v-model="config.MY_SELECT"
  :label="['option1', 'option2', 'option3']" />

<!-- テキスト入力の場合 -->
<SettingInput i18n="myInput" v-model="config.MY_INPUT" :span="8" />
```

#### ステップ 4: Submit() にコマンド実行を追加（Setting.vue）

`Submit()` メソッド内に差分検出とコマンド実行を追加:
```javascript
if(this.config.MY_NEW_SETTING !== this.oldConfig.MY_NEW_SETTING) {
  execCmds.push(`mycommand ${this.config.MY_NEW_SETTING}`);
}
```

**注意:** `hack_ini.cgi` は config オブジェクトの全キーを自動的に hack.ini に保存するため、永続化のための追加コードは不要。コマンド実行が不要な設定（他のスクリプトが hack.ini を直接読む場合）は Submit() への追加も不要。

### 4.2 新しい WebUI タブを追加する

#### ステップ 1: コンポーネント作成（任意）

`web/source/vue/MyNewTab.vue` を作成（複雑な場合）。シンプルなら Setting.vue 内に直接記述可能。

#### ステップ 2: Setting.vue に登録

```javascript
// import（別コンポーネントの場合）
import MyNewTab from './MyNewTab.vue';

// components に登録
components: { MyNewTab, /* ...既存 */ },
```

```vue
<!-- テンプレートに ElTabPane 追加 -->
<ElTabPane name="myNewTab" class="well-transparent container"
  :label="$t('myNewTab.tab')">
  <!-- コンテンツ -->
</ElTabPane>
```

#### ステップ 3: 条件付き表示（必要な場合）

```vue
<!-- AtomSwing のみ表示 -->
<ElTabPane v-if="isSwing && posValid" ...>

<!-- ATOM ブランドのみ -->
<ElTabPane v-if="distributor === 'ATOM'" ...>

<!-- 特定の設定が有効な場合のみ -->
<ElTabPane v-if="config.SOME_FEATURE === 'on'" ...>
```

### 4.3 新しい libcallback コマンドを追加する

**変更が必要なファイル:** 2-3 箇所

#### ステップ 1: コマンドハンドラを作成

`libcallback/my_feature.c` を新規作成:

```c
#include <stdio.h>
#include <string.h>

// 外部参照（command.c で定義）
extern char *CommandResBuf;

// コマンドハンドラ
// 引数: tokenize 済みの残りの文字列（strtok_r のコンテキスト）
// 戻り値: レスポンス文字列（CommandResBuf に書き込み）
char *MyFeature(int fd, char *tokenPtr) {
  char *p = strtok_r(NULL, " \t\r\n", &tokenPtr);

  if(!p) {
    // 引数なし: 状態を返す
    sprintf(CommandResBuf, "current_state");
    return CommandResBuf;
  }

  // 引数あり: 設定を変更
  // ... 処理 ...

  sprintf(CommandResBuf, "ok");
  return CommandResBuf;
}
```

#### ステップ 2: コマンドテーブルに登録（command.c）

```c
extern char *MyFeature(int, char *);

struct CommandTableSt CommandTable[] = {
  // ...既存のエントリ
  { "myfeature", &MyFeature },  // ← 追加
};
```

#### ステップ 3: Makefile に追加

`libcallback/Makefile` の `SRCS` に追加:
```makefile
SRCS = command.c video_callback.c ... my_feature.c
```

### 4.4 新しいフック（関数傍受）を追加する

#### パターン A: 共有ライブラリの関数をフック

```c
#include <dlfcn.h>

// オリジナル関数のポインタ
static int (*original_func)(int arg1, char *arg2) = NULL;

// コンストラクタで初期化（LD_PRELOAD 時に自動実行）
static void __attribute__((constructor)) my_hook_init() {
  original_func = dlsym(
    dlopen("/system/lib/liblocalsdk.so", RTLD_LAZY),
    "target_function_name"
  );
}

// 同名の関数で置換（エクスポートされる）
int target_function_name(int arg1, char *arg2) {
  // カスタム処理
  printf("[hook] target_function_name called: %d, %s\n", arg1, arg2);

  // オリジナル関数を呼び出し
  if(original_func) {
    return original_func(arg1, arg2);
  }
  return -1;
}
```

#### パターン B: libc 関数をフック（RTLD_NEXT）

```c
#include <dlfcn.h>

// オリジナル関数を特定ライブラリから取得
static void *(*original_opendir)(const char *) = NULL;

static void __attribute__((constructor)) init() {
  original_opendir = dlsym(
    dlopen("/lib/libc.so.0", RTLD_LAZY),
    "opendir"
  );
}

// libc の opendir を置換
void *opendir(const char *name) {
  // カスタム処理（例: 特定パスの監視）
  if(strstr(name, "/my/watched/path")) {
    printf("[webhook] my_custom_event %s\n", name);
  }
  return original_opendir(name);
}
```

**重要な注意点:**
- `dlsym` の第一引数は必ずフック対象のライブラリを `dlopen` で指定する
- `RTLD_NEXT` は使用しない（このプロジェクトのパターン）
- フック関数は `static` にしない（エクスポートが必要）
- コンストラクタ (`__attribute__((constructor))`) で初期化する

### 4.5 新しいシェルスクリプトコマンドを追加する

`webcmd.sh` で処理される新しいコマンド（WebUI の cmd.cgi 経由で呼ばれるもの）を追加する場合:

#### ステップ 1: webcmd.sh にコマンドハンドラ追加

`overlay_rootfs/scripts/webcmd.sh` の case 文に追加:

```sh
mycommand)
  # 引数を取得
  ARG1=$(echo "$LINE" | awk '{print $2}')

  # hack.ini から設定を読み込み（必要な場合）
  . /tmp/hack.ini

  # 処理実行
  if [ "$ARG1" = "on" ]; then
    # 有効化処理
    /scripts/cmd myfeature on  # libcallback へ送信
  else
    # 無効化処理
    /scripts/cmd myfeature off
  fi

  echo "ok" > /var/run/webres  # レスポンス返却
  ;;
```

#### ステップ 2: 起動時の設定適用（必要な場合）

`overlay_rootfs/scripts/set_icamera_config.sh` にブート時の初期化処理を追加:

```sh
# hack.ini から読み込み
. /tmp/hack.ini

# libcallback に設定送信
if [ "$MY_NEW_SETTING" = "on" ]; then
  /scripts/cmd myfeature on
fi
```

### 4.6 新しい起動サービスを追加する

`overlay_rootfs/etc/init.d/` に新しいスクリプトを作成:

```sh
#!/bin/sh
# overlay_rootfs/etc/init.d/S72myservice

. /tmp/hack.ini

case "$1" in
  start)
    [ "$MY_SERVICE" != "on" ] && exit 0
    echo "Starting my service..."
    /scripts/my_service.sh &
    ;;
  stop)
    echo "Stopping my service..."
    killall my_service.sh 2>/dev/null
    ;;
  *)
    echo "Usage: $0 {start|stop}"
    exit 1
    ;;
esac
```

**命名規則:** `S[番号][名前]` — 番号は実行順序（既存スクリプトとの依存関係に注意）

**注意:**
- BusyBox ash 互換で記述（bash 固有機能不可）
- `source` ではなく `.` を使用
- hack.ini は `. /tmp/hack.ini` で変数として読み込み可能
- libcallback へのコマンド送信は `/scripts/cmd <command>` を使用

### 4.7 新しい CGI エンドポイントを追加する

`overlay_rootfs/var/www/cgi-bin/my_api.cgi`:

```sh
#!/bin/sh

# Content-Type は必ず最初に出力
if [ "$REQUEST_METHOD" = "GET" ]; then
  echo "Content-type: application/json"
  echo ""

  # hack.ini から設定読み込み
  . /tmp/hack.ini
  echo "{\"my_setting\": \"$MY_SETTING\"}"

elif [ "$REQUEST_METHOD" = "POST" ]; then
  echo "Content-type: application/json"
  echo ""

  # POST データ読み込み
  read -r POST_DATA
  # JSON パース（jq がない環境なので awk/sed で処理）
  VALUE=$(echo "$POST_DATA" | sed 's/.*"value":"\([^"]*\)".*/\1/')

  # 処理実行
  echo "$VALUE" | /scripts/cmd myfeature

  echo "{\"result\": \"ok\"}"
fi
```

**lighttpd.conf への追加は不要** — `.cgi` 拡張子はすべて自動的にシェルスクリプトとして実行される。

### 4.8 新しい Webhook イベントを追加する

#### ステップ 1: libcallback でイベントを stdout に出力

```c
// opendir.c や remove.c のパターンに倣う
printf("[webhook] my_custom_event %s\n", event_data);
```

#### ステップ 2: webhook.sh でイベント解析を追加

`overlay_rootfs/scripts/webhook.sh` の awk パターンに追加:

```awk
/\[webhook\] my_custom_event/ {
  if(MY_CUSTOM_EVENT == "on") {
    cmd = sprintf("curl -X POST -d '{\"event\":\"my_custom\",\"data\":\"%s\"}' %s", $3, WEBHOOK_URL)
    system(cmd)
  }
}
```

#### ステップ 3: WebUI に設定トグル追加

hack.ini キー `WEBHOOK_MY_CUSTOM_EVENT` を追加し、Setting.vue のイベント通知タブに SettingSwitch を追加。

### 4.9 新しいカスタムパッケージを追加する

#### ステップ 1: パッケージディレクトリ作成

```
custompackages/package/mypackage/
├── Config.in
└── mypackage.mk
```

#### ステップ 2: Config.in

```
config BR2_PACKAGE_MYPACKAGE
	bool "mypackage"
	help
	  My custom package description.
```

#### ステップ 3: mypackage.mk

```makefile
MYPACKAGE_VERSION = 1.0.0
MYPACKAGE_SITE = https://example.com/releases
MYPACKAGE_SOURCE = mypackage-$(MYPACKAGE_VERSION).tar.gz

define MYPACKAGE_BUILD_CMDS
	$(MAKE) CC="$(TARGET_CC)" -C $(@D)
endef

define MYPACKAGE_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/mypackage $(TARGET_DIR)/usr/bin/mypackage
endef

$(eval $(generic-package))
```

#### ステップ 4: メインの Config.in に登録

`custompackages/package/Config.in` に追加:
```
source "package/mypackage/Config.in"
```

#### ステップ 5: defconfig に追加

`configs/atomcam_defconfig` に追加:
```
BR2_PACKAGE_MYPACKAGE=y
```

### 4.10 カーネルにパッチを追加する

`patches/kernel/` に新しいパッチファイルを配置。

`buildscripts/setup_buildroot.sh` の `linux_prebuild_hook` またはカーネルのパッチ適用処理に追加が必要な場合がある。

**重要:** カーネルは Linux 3.10.14（非常に古い）であり、新しいカーネル機能は利用できない可能性がある。

### 4.11 拡張のための主要接点まとめ

| やりたいこと | 変更するファイル |
|---|---|
| **WebUI に設定項目追加** | `Setting.vue`（data + template + Submit）、`i18n-ja.yaml`、`i18n-en.yaml` |
| **WebUI に新タブ追加** | 上記 + 必要に応じて新 Vue コンポーネント |
| **カメラハードウェア制御追加** | `libcallback/` に新 .c ファイル + `command.c` のテーブル + `Makefile` |
| **既存関数のフック追加** | `libcallback/` に新 .c ファイル + `Makefile` |
| **新シェルコマンド追加** | `webcmd.sh` の case 文 |
| **起動時の初期化追加** | `set_icamera_config.sh` or 新規 init.d スクリプト |
| **新サービス追加** | `etc/init.d/S??myservice` + `scripts/my_service.sh` |
| **新 API エンドポイント追加** | `var/www/cgi-bin/my_api.cgi` |
| **新 Webhook イベント追加** | libcallback stdout 出力 + `webhook.sh` + WebUI トグル |
| **新パッケージ追加** | `custompackages/package/` + `atomcam_defconfig` |
| **録画パス/方式変更** | `webcmd.sh` + `set_icamera_config.sh` + `remove_old.sh` |
| **ネットワーク設定変更** | `network_init.sh` |
| **cron ジョブ追加** | `set_crontab.sh` |
| **ブートシーケンス変更** | `initramfs_skeleton/init`（慎重に） |
| **カーネル機能追加** | `patches/kernel/` + `configs/kernel.config` |

### 4.12 よくある拡張パターン

#### パターン A: 「新しいカメラ設定を WebUI から変更できるようにする」

1. `Setting.vue` に UI 追加
2. `i18n-*.yaml` に翻訳追加
3. → hack_ini.cgi が自動保存
4. `webcmd.sh` にコマンド追加（または Submit() で直接 socket コマンド実行）
5. `set_icamera_config.sh` にブート時適用処理追加

#### パターン B: 「iCamera_app の新しい内部関数をフックする」

1. `libcallback/` に新 .c ファイル作成（dlsym + フック関数）
2. `command.c` にコマンド登録（WebUI からの制御が必要な場合）
3. `Makefile` の SRCS に追加
4. 必要に応じて WebUI + webcmd.sh を追加

#### パターン C: 「新しい外部サービスと連携する」

1. 必要なバイナリを `custompackages/` に追加
2. `etc/init.d/S??service` で起動制御
3. `scripts/service.sh` でライフサイクル管理
4. `webcmd.sh` に制御コマンド追加
5. Setting.vue に設定 UI 追加

#### パターン D: 「録画データの新しい転送先を追加する」

1. `webcmd.sh` にマウント/転送コマンド追加
2. `remove_old.sh` にクリーンアップ処理追加
3. `set_crontab.sh` に定期実行追加（必要な場合）
4. Setting.vue に設定 UI 追加
5. `timelapse.sh` / `webhook.sh` に転送処理追加

---

## 付録: 通信ポート一覧

| ポート | プロトコル | サービス | 設定場所 |
|---|---|---|---|
| 22 | TCP | SSH（sshd） | S55sshd |
| 80 | TCP | WebUI（lighttpd） | lighttpd.conf |
| 137, 138, 139, 445 | TCP/UDP | Samba/CIFS | smb.conf |
| 4000 | TCP（localhost のみ） | libcallback コマンドソケット | command.c |
| 5353 | UDP | mDNS/avahi | avahi 自動 |
| 8080 | TCP | RTSP over HTTP | rtspserver.sh |
| 8554 | TCP | RTSP | rtspserver.sh |
| 8555 | TCP | HomeKit / WebRTC | go2rtc |

## 付録: 主要設定ファイルの関係

```
/media/mmc/hack.ini      ← WebUI が読み書きする永続設定（全設定の中核）
/tmp/hack.ini             ← hack.ini の実行時コピー（スクリプトが参照）
/media/mmc/video_isp.conf ← ISP パラメータ（video_isp.cgi が読み書き）
/media/mmc/hostname       ← デバイス名（S40hostname が bind mount）
/media/mmc/authorized_keys ← SSH 公開鍵（S21rootkeys がコピー）
/media/mmc/TZ             ← タイムゾーン（S43timezone.env が参照）
/media/mmc/watermark.bgra ← ロゴ画像（watermark.cgi が読み書き）
/atom/configs/.user_config ← iCamera_app 内部設定（webcmd.sh が一部変更）
/atom/configs/.product_config ← デバイスモデル判定（読み取り専用）
```
