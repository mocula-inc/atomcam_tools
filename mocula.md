# mocula.sh 解説

## 概要

ATOM Cam から定期的に JPEG 画像をキャプチャし、mocula クラウド API と連携して S3 にアップロードするデーモンスクリプト。

画像アップロードに加えて、サーバから配信されたファームウェアアップデートの適用と、
失敗時のロールバックも担う（→ [ファームウェアアップデート（OTA）](#ファームウェアアップデートota)）。

- **スクリプトパス**: `/scripts/mocula.sh`
- **設定ファイル**: `/media/mmc/mconfig`
- **ログファイル**: `/tmp/log/mocula.log`（tmpfs。再起動で消える）
- **PID ファイル**: `/var/run/mocula.pid`
- **起動スクリプト**: `/etc/init.d/S76mocula`

OTA 関連:

- **バージョンファイル**: `/etc/mocula.ver`（ビルド時に `configs/mocula.ver` から焼かれる）
- **共通ライブラリ**: `/scripts/fwstate.sh`（更新state の読み書き）
- **ロールバック監視**: `/scripts/fwrollback.sh`（cron から毎分）
- **永続ログ**: `/media/mmc/atomhack.log`（更新関連のイベントのみ。再起動を跨いで残る）

---

## 設定ファイル（mconfig）

INI 形式。SD カード上の `/media/mmc/mconfig` に配置する。

```ini
[global]
tenantKey=<テナントキー>
cameraKey=<カメラキー>
origin=https://qa1.mocula-dev.com  # 省略時は https://app.mocula.jp

[firmware]
rollbackTimeout=600  # 省略時は 600（秒）
```

| キー              | セクション  | 説明                                                              |
| ----------------- | ----------- | ----------------------------------------------------------------- |
| `tenantKey`       | `global`    | テナント識別子                                                    |
| `cameraKey`       | `global`    | カメラ識別子                                                      |
| `origin`          | `global`    | API ベース URL（省略可。既定 `https://app.mocula.jp`）            |
| `rollbackTimeout` | `firmware`  | 更新後にロールバックを発火させるまでの秒数（省略可。既定 `600`）  |

値の変更はデーモン起動時にしか読まれないため、`/etc/init.d/S76mocula restart` が必要。

---

## 起動コマンド

```sh
/scripts/mocula.sh on       # デーモン起動
/scripts/mocula.sh off      # デーモン停止
/scripts/mocula.sh restart  # 再起動
/scripts/mocula.sh watchdog # プロセス死活監視（cron から毎分呼び出し）
```

`watchdog` は `/etc/crontab` に登録されており、デーモンが落ちていれば自動再起動する。
同じ crontab に `fwrollback.sh` も毎分で登録される（`set_crontab.sh` 参照）。

---

## 動作フロー

```
起動
 └─ mconfig 読み込み（tenantKey / cameraKey / origin / rollbackTimeout）
     └─ メインループ（1秒ごと）
          ├─ [60秒ごと] camera-sync API を呼び出し
          │    ├─ デバイス情報収集（SSID / RSSI / MAC / IP / タイムスタンプ）
          │    ├─ /etc/mocula.ver を読み firmwareVersion として送る
          │    ├─ 更新state が failed / rolled_back / rollback_failed なら
          │    │  firmwareUpdateReport を添える
          │    ├─ POST /api/v1/camera-sync/{tenantKey}/{cameraKey}
          │    └─ レスポンスから isEnabled / checkInterval / uploadUrls /
          │       firmwareUpdate を取得
          │
          ├─ [60秒ごと、camera-sync の直後] ファームウェア適用判定
          │    └─ firmwareUpdate があれば apply_firmware_update
          │       （→ OTA セクション）
          │
          └─ [isEnabled=true かつ checkInterval 秒ごと]
               ├─ uploadUrls キューから URL を 1 件取り出し
               ├─ JPEG キャプチャ（/scripts/cmd jpeg）
               ├─ tar アーカイブ作成（JPEG + contents.json）
               └─ S3 pre-signed URL へ PUT アップロード
```

ファームウェアのダウンロードはこのループ内で同期的に行われるため、
ダウンロード中（最大10分）は sync も画像アップロードも停止する。

---

## API 仕様

### camera-sync

```
POST {apiOrigin}/api/v1/camera-sync/{tenantKey}/{cameraKey}
Content-Type: application/json
```

**リクエストボディ:**
```json
{
  "wifi": { "ssid": "...", "rssi": -57, "mac": "00:11:22:33:44:55" },
  "ip":   { "address": "192.168.x.x", "netmask": "255.255.255.0" },
  "timestamp": 1771545741490,
  "firmwareVersion": "0.3.0",
  "firmwareUpdateReport": {
    "targetVersion": "0.4.0",
    "result": "failed",
    "reason": "checksum_mismatch"
  }
}
```

| フィールド              | 必須 | 説明                                                                       |
| ----------------------- | ---- | -------------------------------------------------------------------------- |
| `wifi.mac`              | ○    | `/sys/class/net/wlan0/address`。サーバ側で必須                             |
| `firmwareVersion`       | −    | `/etc/mocula.ver` の内容。サーバはこれが `targetVersion` と一致したら完了と判定 |
| `firmwareUpdateReport`  | −    | 失敗・ロールバック時のみ送る。成功時は送らない（`firmwareVersion` が兼ねる）  |

**レスポンス:**
```json
{
  "success": true,
  "data": {
    "isEnabled": true,
    "checkInterval": 10,
    "uploadUrls": ["https://s3.amazonaws.com/..."],
    "firmwareUpdate": {
      "version": "0.4.0",
      "url": "https://s3.amazonaws.com/...",
      "size": 47963166,
      "checksum": "628870d2..."
    }
  }
}
```

| フィールド       | 説明                                                                        |
| ---------------- | --------------------------------------------------------------------------- |
| `isEnabled`      | アップロード機能の有効/無効                                                 |
| `checkInterval`  | アップロード間隔（秒）                                                      |
| `uploadUrls`     | S3 pre-signed URL のリスト（有効期限 60 秒）                                |
| `firmwareUpdate` | 更新指示。予約がある場合のみ。**予約が続く間は毎回同じ内容が返る**（後述）   |

`firmwareUpdate` は 1 回きりの通知ではない。サーバはレスポンス消失に備えて予約が有効な間
毎回同じオファーを返す（配信保証）ため、重複ダウンロードの防止はカメラ側の責務である
（更新state の `TARGET_VERSION` で判定）。

`firmwareUpdate.url` の有効期限は 15 分。ダウンロードの `curl --max-time` は 600 秒なので、
どちらかを変更する場合は他方も併せて見直すこと。

### S3 アップロード

```
PUT {uploadUrl}
Content-Type: application/tar
Body: tarball（JPEG + contents.json）
```

**tar アーカイブ構成:**
```
{timestamp_msec}.jpg   # キャプチャした JPEG 画像
contents.json          # メタデータ
```

**contents.json の形式:**
```json
[{"filename": "1771545741490.jpg", "capturedAt": "2026-02-20T09:00:00.000Z"}]
```

---

## ファームウェアアップデート（OTA）

サーバで予約された更新を受け取り、ダウンロード・検証・適用し、通信が復帰しなければ
旧ファームウェアへ自動的に戻す。

### 関係するファイル

| パス                                   | 役割                                                                 |
| -------------------------------------- | -------------------------------------------------------------------- |
| `/etc/mocula.ver`                      | 現在のバージョン。`configs/mocula.ver` からビルド時に焼かれる         |
| `/media/mmc/fwupdate/state`            | 更新の進行状態。**この存在がロールバック監視の前提**                  |
| `/media/mmc/fwbackup/`                 | 更新前のカーネルと rootfs の退避先。ロールバックはこれだけが頼り       |
| `/media/mmc/update/`                   | initramfs が拾う適用待ちファイルの置き場                              |
| `/var/run/mocula.sync_ok`              | 更新後に一度でも sync 成功したか。**tmpfs である必要がある**           |
| `/var/run/fwboot_counted`              | 1起動につき1回だけ BOOT_COUNT を加算するためのマーカー（同上）          |

`sync_ok` と `fwboot_counted` を永続領域へ移すとロールバックが機能しなくなる。
起動ごとに消えることが判定の前提になっている。

### 更新の流れ

```
camera-sync で firmwareUpdate を受信
 ├─ 既に適用済み / 同じバージョンを試行済みなら何もしない
 ├─ /etc/mocula.ver が読めなければ中止（完了判定ができなくなるため）
 ├─ 空き容量を確認（zip×2 + カーネル + rootfs の 110%。実測で約 151MB）
 ├─ ダウンロード（curl --max-time 600）
 ├─ サイズと sha256 を検証
 ├─ 現行のカーネルと rootfs を fwbackup/ へ退避し、cmp で照合
 ├─ state に PHASE=applied を書く（書けなければ再起動しない）
 └─ zip を update/ へ移して reboot
      └─ initramfs が zip を展開して適用（initramfs は無改造のまま流用）
           └─ 起動後 camera-sync 成功 → サーバが completed と判定
                └─ fwrollback.sh が state を削除
```

### 更新state（`/media/mmc/fwupdate/state`）

`fwstate.sh` 経由で読み書きする。`.` でソースしてはいけない（値にシェルのメタ文字が
入ると読み込んだ側が死ぬ）。書き込みは一時ファイル + `mv` で原子的に行う。

```
TARGET_VERSION=0.4.0     # 適用しようとしているバージョン
PREV_VERSION=0.3.0       # 適用前のバージョン（ロールバック先）
PHASE=applied            # applied / failed / rolled_back / rollback_failed
TIMEOUT=600              # ロールバック発火までの秒数（mconfig 由来）
BOOT_COUNT=1             # 更新state が残っている間の起動回数
REASON=                  # 終端した理由（failed 系のときのみ）
```

`PHASE` の意味:

| 値                | 意味                                                                       |
| ----------------- | -------------------------------------------------------------------------- |
| `applied`         | 適用して再起動した。まだ疎通確認できていない（ロールバック監視の対象）       |
| `failed`          | ダウンロードまたは検証で失敗。適用していない                                |
| `rolled_back`     | 旧ファームウェアへ戻した                                                   |
| `rollback_failed` | 戻そうとしたがバックアップが使用不能。**新ファームのまま復旧手段を失った**   |

`rollback_failed` は物理的な介入（SDカードの差し替え等）が必要な唯一の状態。
`rolled_back` と混同してはならない。

### ロールバック（`fwrollback.sh`）

cron から毎分呼ばれ、`PHASE=applied` のときだけ動く。

発火条件はいずれか:

- 連続稼働時間が `TIMEOUT` 秒を超えた
- 更新state が残ったままの起動が 3 回に達した（起動直後に再起動を繰り返すケースの救済）

壁時計ではなく uptime と `BOOT_COUNT` を使う。カメラの RTC は未同期・巻き戻りがありうる。

判定の順序:

1. `BOOT_COUNT` が 0 なら何もしない — 更新のための再起動がまだ起きていない。
   cron は毎分動くので、`reboot` のシャットダウン処理中に呼ばれることがある
2. `/etc/mocula.ver` が `TARGET_VERSION` と違えば、initramfs が適用できなかったと判断して `failed`
3. `sync_ok` があれば成功。state を削除して終了
4. 発火条件を満たしたら、退避物を検証 → `update/` へコピー → コピーも検証 → `rolled_back` を書いて reboot
   - 退避物が壊れていれば `rollback_failed` を書いて終了（再起動しない）
   - コピーに失敗した場合は `applied` のままにして次回起動で再試行する

`rolled_back` は再起動の**前**に書く。復旧後に再度ロールバックが発火しないようにするため。

### 失敗の扱い

ネットワーク起因の失敗とそれ以外を区別している。

| 失敗                     | state を書くか            | 挙動                          |
| ------------------------ | ------------------------- | ----------------------------- |
| curl の通信エラー        | 書かない                  | 次の周期で再試行する          |
| サイズ不一致             | `failed` / `size_mismatch`     | 停止し、サーバへ報告する |
| チェックサム不一致       | `failed` / `checksum_mismatch` | 同上                     |
| 空き容量不足             | `failed` / `insufficient_space` | 同上                    |
| `df` の出力が読めない    | `failed` / `df_unreadable`      | 空き容量を確認できないため中止 |
| バージョン文字列が不正   | `failed` / `invalid_version`    | state に書けない文字を含む場合 |
| バックアップ検証失敗     | `failed` / `backup_failed`      | 同上                    |
| rootfs が存在しない      | `failed` / `no_rootfs_image`    | ext2 で動作している個体など |
| 再起動後のバージョン不一致 | `failed` / `version_mismatch_after_reboot` | initramfs が適用できなかった |
| 退避物が使用不能         | `rollback_failed` / `backup_unusable` | ロールバック不能        |

再試行しても結果が変わらない失敗は `failed` を書いて止める。**自動リトライはしない**。
再試行は運用者が予約し直す運用。

### ログ

更新関連のイベントは `/tmp/log/mocula.log` と `/media/mmc/atomhack.log` の両方に出る。
後者は logrotate 対象の永続ファイルで、**診断したい更新再起動を跨いで残る**。
`/tmp` は tmpfs なので前者だけでは再起動で失われる。

```
2026/07/30 12:05:58 : mocula.sh: firmware update staged: 0.1.0 -> 0.3.0, rebooting
2026/07/30 12:09:59 : mocula.sh: firmware update failed (checksum_mismatch): expected=... actual=...
2026/07/30 12:18:01 : fwrollback: rollback triggered (uptime=136s timeout=120s bootCount=1)
2026/07/30 12:18:01 : fwrollback: backup verification failed, cannot roll back; reporting rollback_failed
```

### 動作確認

`tests/test_fwrollback.sh` が `fwrollback.sh` の全分岐を検証する（busybox ash、実機不要）。

```sh
busybox ash tests/test_fwrollback.sh
```

---

## ログ出力

正常時はログを出力しない。エラー時のみ記録される。

| ログメッセージ                                     | 原因                                       |
| -------------------------------------------------- | ------------------------------------------ |
| `mocula started (pid=...)`                         | デーモン起動                               |
| `mocula stopped`                                   | `off` コマンドによる停止                   |
| `watchdog: restarting mocula`                      | watchdog によるプロセス再起動              |
| `tenantKey or cameraKey not configured`            | mconfig にキーが未設定                     |
| `camera-sync failed: curl error {N}`               | curl 通信エラー（N は curl エラーコード）  |
| `camera-sync failed: empty response`               | サーバーが空レスポンスを返した             |
| `camera-sync failed: {レスポンス先頭200字}`        | `success:false` レスポンス（NOT_FOUND 等） |
| `JPEG capture failed`                              | `/scripts/cmd jpeg` が空を返した           |
| `upload failed: curl={N} HTTP={code} {レスポンス}` | S3 アップロード失敗                        |
| `firmware download failed: curl error {N}`         | FW ダウンロードの通信エラー（再試行する）  |
| `firmware update failed ({reason}): {詳細}`        | FW の検証・準備で失敗（停止して報告する）  |
| `firmware update staged: {旧} -> {新}, rebooting`  | 適用して再起動する                        |
| `firmware update skipped: cannot read current version` | `/etc/mocula.ver` が読めない          |
| `firmware update aborted: cannot persist state`    | state を書けないため再起動を中止した      |
| `fwrollback: rollback triggered (...)`             | ロールバック発火                          |
| `fwrollback: backup verification failed, ...`      | 退避物が使用不能（`rollback_failed`）     |

---

## 既知の制限事項

- **pre-signed URL の有効期限**: `uploadUrls` の有効期限は 60 秒。`checkInterval` や URL 数の組み合わせ次第では camera_sync 取得後のアップロードが期限切れになるリスクがある（TODO）。
- **更新中は sync と画像アップロードが止まる**: ダウンロードがメインループ内で同期的に行われるため、最大 10 分＋再起動 2 回のあいだ画像が上がらない。サーバ側は予約が有効なカメラの接続監視の猶予を延長して誤検知を防いでいる。
- **バージョンを上げずに再ビルド・再デプロイしてはいけない**: S3 のオブジェクトだけが差し替わり、サーバに登録済みの size / checksum とずれるため、そのファームウェアを予約した全カメラが検証失敗する。再ビルドした場合はサーバ側の登録を削除してから登録し直すこと。
- **A/B パーティションではない**: 退避は SD カード上の単一コピー。SD カードが壊れている場合はロールバックできない。
- **署名検証はしていない**: 完全性は sha256 のみで担保している。

---

## 起動時の DNS 問題について

iCamera_app（カメラ純正ファームウェア）が起動時に `/tmp/resolv.conf` を上書きするため、udhcpc が設定した DNS が失われる。`S76mocula` の `start` 処理で `udhcpc` に `USR1 (RENEW)` シグナルを送ることで回避している。

```sh
# /etc/init.d/S76mocula より
kill -USR1 $(pgrep udhcpc) > /dev/null 2>&1
sleep 1
/scripts/mocula.sh on &
```
