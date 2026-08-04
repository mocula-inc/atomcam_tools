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
clockSkewThreshold=60              # 省略時は 60（秒）。0 で時刻補正を無効化

[firmware]
rollbackTimeout=600  # 省略時は 600（秒）
```

| キー                  | セクション  | 説明                                                                    |
| --------------------- | ----------- | ------------------------------------------------------------------------ |
| `tenantKey`           | `global`    | テナント識別子                                                          |
| `cameraKey`           | `global`    | カメラ識別子                                                            |
| `origin`              | `global`    | API ベース URL（省略可。既定 `https://app.mocula.jp`）                  |
| `clockSkewThreshold`  | `global`    | サーバ時刻とのズレがこれを超えたらカメラ時計を補正する秒数（省略可。既定 `60`。`0` で無効化） → [時刻同期](#時刻同期) |
| `rollbackTimeout`     | `firmware`  | 更新後にロールバックを発火させるまでの秒数（省略可。既定 `600`）        |

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
 └─ mconfig 読み込み（tenantKey / cameraKey / origin / clockSkewThreshold / rollbackTimeout）
     └─ メインループ（1秒ごと）
          ├─ [60秒ごと] camera-sync API を呼び出し
          │    ├─ デバイス情報収集（SSID / RSSI / MAC / IP / タイムスタンプ）
          │    ├─ /etc/mocula.ver を読み firmwareVersion として送る
          │    ├─ 更新state が failed / rolled_back / rollback_failed なら
          │    │  firmwareUpdateReport を添える
          │    ├─ POST /api/v1/camera-sync/{tenantKey}/{cameraKey}
          │    ├─ レスポンスから isEnabled / checkInterval / uploadUrls /
          │    │  firstUploadDelay / serverEpoch / firmwareUpdate を取得
          │    └─ serverEpoch とのズレが clockSkewThreshold を超えていれば
          │       カメラ時計を補正（→ [時刻同期](#時刻同期)）
          │
          ├─ [60秒ごと、camera-sync の直後] ファームウェア適用判定
          │    └─ firmwareUpdate があれば apply_firmware_update
          │       （→ OTA セクション）
          │
          └─ [isEnabled=true かつ URL_QUEUE が空でない]
               ├─ camera-sync 直後、firstUploadDelay 秒待ってから
               │  1本目を消化。2本目以降は checkInterval 秒ごと
               ├─ uploadUrls キューから URL を 1 件取り出し
               ├─ JPEG キャプチャ（/scripts/cmd jpeg）
               ├─ tar アーカイブ作成（JPEG + contents.json）
               └─ S3 pre-signed URL へ PUT アップロード
```

ファームウェアのダウンロードはこのループ内で同期的に行われるため、
ダウンロード中（最大10分）は sync も画像アップロードも停止する。

### アップロードタイミング

次回撮影予定時刻はサーバがサーバ時計だけで管理しており、カメラはそれに依存しない
「あと何秒で1本目を使うか」（`firstUploadDelay`）だけを受け取る。カメラ側は
`UPLOAD_TIMER` という残り秒数のカウントダウンでこれを消化する。

- `URL_QUEUE` が空のとき（起動直後、または前回分を消化しきったとき）だけ、
  camera-sync のレスポンスで `UPLOAD_TIMER=$FIRST_UPLOAD_DELAY` に**再アンカー**し、
  `URL_QUEUE` を新しいレスポンスの内容で置き換える
- `URL_QUEUE` がまだ残っている場合は**上書きしない**。新しく配られた分は末尾に
  追記するだけで、`UPLOAD_TIMER` のカウントダウンも触らない。camera-sync は
  「次回撮影予定時刻」をサーバ側で前進させながら応答するため、期限がまだ来ていない
  だけの正当な予約をここで上書きすると、二度と再配信されないまま消えてしまう
- `UPLOAD_TIMER` はメインループの `sleep 1` と処理時間の分だけ実時間よりわずかに
  遅れるが、次にキューが空になったタイミングでサーバ値により補正されるため
  誤差は累積しない
- `checkInterval <= 60` で1回の sync に複数本の URL が配られた場合、2本目以降は
  `UPLOAD_TIMER=$CHECK_INTERVAL` で均等に消化する

この方式に変える前は、`checkInterval` 秒ごとの判定をメインループのカウンタの剰余
（`counter % checkInterval == 0`）で行っていた。このカウンタは camera-sync のたびに
0 へリセットされるため、`checkInterval` が 60 の約数でない場合は
「camera-sync 直後にしか URL を消化しない」実質的なバグになっており、
送信間隔が設定値より最大1分近く短くなっていた。

「空のときだけ置き換え、残っていれば追記」にしているのも同じ理由の再発防止策。
単純に毎回上書きする実装では、`checkInterval` が sync 周期（60秒）の倍数のときに
撮影期限と sync のタイミングがちょうど重なり、期限が来ていた撮影がキューの
上書きで消える／サーバは既にその枠を配信済み扱いにしているため二度と来ない、
という形で2回目以降のアップロードが永久に発生しなくなる不具合があった。

`tests/test_mocula_timing.sh` が camera_sync / capture_and_upload をスタブ化し、
実時間を消費せずに様々な `checkInterval`（60秒の約数・倍数を含む）でこの挙動を
検証する（busybox ash、実機不要）。

```sh
busybox ash tests/test_mocula_timing.sh
```

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
    "firstUploadDelay": 42,
    "serverEpoch": 1785377113,
    "firmwareUpdate": {
      "version": "0.4.0",
      "url": "https://s3.amazonaws.com/...",
      "size": 47963166,
      "checksum": "628870d2..."
    }
  }
}
```

| フィールド         | 説明                                                                        |
| ------------------ | --------------------------------------------------------------------------- |
| `isEnabled`        | アップロード機能の有効/無効                                                 |
| `checkInterval`    | アップロード間隔（秒）                                                      |
| `uploadUrls`       | S3 pre-signed URL のリスト（有効期限 5 分）                                 |
| `firstUploadDelay` | `uploadUrls` の1本目を使うまでの待機秒数。次回撮影予定時刻はサーバの時計だけで管理しており、カメラの時計に依存させないため絶対時刻ではなく相対秒で返す |
| `serverEpoch`      | サーバ現在時刻（UNIX秒）。カメラ側の時刻補正に使う → [時刻同期](#時刻同期)  |
| `firmwareUpdate`   | 更新指示。予約がある場合のみ。**予約が続く間は毎回同じ内容が返る**（後述）   |

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

### 配信手順

```sh
echo "0.4.0" > configs/mocula.ver      # 唯一のバージョン定義元。必ずビルド前に更新する
make build

export MOCULA_ADMIN_EMAIL=you@mocula.co.jp
make firmware-deploy CONFIG=dev1      # dev1 | qa1 | prod1 | prod2
```

`firmware-deploy` は次の2段を順に実行する。S3 に置くだけではカメラへ配信できない。

| ターゲット          | 内容                                                                |
| ------------------- | ------------------------------------------------------------------- |
| `firmware-upload`   | CDK で `firmware/ota/{version}/atomcam_tools.zip` へ配置             |
| `firmware-register` | `POST /api/v1/admin/firmwares` で登録（size と sha256 はサーバが算出） |

配置先バケットと API のURLは `cdk/config/{stage}.yml` の `imageBucketName` / `apiOrigin`
で、いずれも mocula-backend 側の `s3.imageBucketName` / `cloudfront.domainName` に対応する。

`MOCULA_ADMIN_PASSWORD` を設定しない場合は対話的に入力を求める（CI では設定しておく）。
ローカル開発では `MOCULA_API_ORIGIN=http://localhost:3000` を指定する。

登録だけをやり直したい場合は `make firmware-register CONFIG=dev1`。
配置済みのバージョンを再登録すると 409 になるので、その場合は先に
`DELETE /api/v1/admin/firmwares/{id}` で登録を削除する。

登録後、カメラごとに予約すると配信が始まる。

```
POST   /api/v1/cameras/{cameraId}/firmware-update   {"firmwareId": N}
GET    /api/v1/cameras/{cameraId}/firmware-update   # 進捗と失敗理由
DELETE /api/v1/cameras/{cameraId}/firmware-update   # 取消
```

予約から `completed` までは実測で約3分。

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
| `clock corrected: skew=...ms rtt=...ms -> ...`     | サーバ時刻との差が閾値超で時刻補正した（`atomhack.log` にも記録） |
| `clock correction failed: date -s @...`            | `date -s` が失敗した                       |
| `firmware download failed: curl error {N}`         | FW ダウンロードの通信エラー（再試行する）  |
| `firmware update failed ({reason}): {詳細}`        | FW の検証・準備で失敗（停止して報告する）  |
| `firmware update staged: {旧} -> {新}, rebooting`  | 適用して再起動する                        |
| `firmware update skipped: cannot read current version` | `/etc/mocula.ver` が読めない          |
| `firmware update aborted: cannot persist state`    | state を書けないため再起動を中止した      |
| `fwrollback: rollback triggered (...)`             | ロールバック発火                          |
| `fwrollback: backup verification failed, ...`      | 退避物が使用不能（`rollback_failed`）     |

---

## 既知の制限事項

- **pre-signed URL の有効期限**: `uploadUrls` の有効期限は 5 分（`getPresignedUrlForUpload` の `60 * 5`）。`firstUploadDelay` による待機は地平線 90 秒以内に収まるよう設計されているため、有効期限に対して十分な余裕がある。
- **更新中は sync と画像アップロードが止まる**: ダウンロードがメインループ内で同期的に行われるため、最大 10 分＋再起動 2 回のあいだ画像が上がらない。サーバ側は予約が有効なカメラの接続監視の猶予を延長して誤検知を防いでいる。
- **バージョンを上げずに再ビルド・再デプロイしてはいけない**: S3 のオブジェクトだけが差し替わり、サーバに登録済みの size / checksum とずれるため、そのファームウェアを予約した全カメラが検証失敗する。再ビルドした場合はサーバ側の登録を削除してから登録し直すこと。
- **A/B パーティションではない**: 退避は SD カード上の単一コピー。SD カードが壊れている場合はロールバックできない。
- **署名検証はしていない**: 完全性は sha256 のみで担保している。

---

## 時刻同期

カメラには常駐 ntpd（`/etc/init.d/S42ntpd`）が入っており、通常はこれで時刻が合う。
起動時に `ntp.nict.jp` へ ping が通らない場合のみ `/media/mmc/time.ini` の古い時刻に
フォールバックし、以後 NTP が塞がれた環境（企業 LAN で UDP 123 が塞がれている等）では
ntpd が復旧できないまま時刻が狂い続けることがある。

mocula.sh は camera-sync のたびに、サーバ現在時刻（`serverEpoch`）を使ってこれを
救済する:

1. camera-sync の curl 前後でカメラ時計の差分から RTT を求める
2. 推定サーバ時刻 = `serverEpoch + RTT / 2`（往復の半分だけサーバのレスポンス生成時刻より
   進んでいると仮定する）
3. カメラ時計との差が `clockSkewThreshold`（既定 60 秒）を超えていれば `date -s` で補正し、
   `/media/mmc/atomhack.log` に記録する

**あくまで ntpd が機能しない場合のフォールバックであり、置き換えではない。** 閾値を
小さくしすぎると常駐 ntpd との補正が競合するため、既定値を変える場合は注意すること。
`clockSkewThreshold=0` で無効化できる。

補正すると `capturedAt` が不連続になる（画像の撮影時刻が前後する）。原因調査の際は
`/media/mmc/atomhack.log` の `clock corrected` ログを確認する。

---

## 起動時の DNS 問題について

iCamera_app（カメラ純正ファームウェア）が起動時に `/tmp/resolv.conf` を上書きするため、udhcpc が設定した DNS が失われる。`S76mocula` の `start` 処理で `udhcpc` に `USR1 (RENEW)` シグナルを送ることで回避している。

```sh
# /etc/init.d/S76mocula より
kill -USR1 $(pgrep udhcpc) > /dev/null 2>&1
sleep 1
/scripts/mocula.sh on &
```
