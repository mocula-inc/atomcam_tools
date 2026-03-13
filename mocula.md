# mocula.sh 解説

## 概要

ATOM Cam から定期的に JPEG 画像をキャプチャし、mocula クラウド API と連携して S3 にアップロードするデーモンスクリプト。

- **スクリプトパス**: `/scripts/mocula.sh`
- **設定ファイル**: `/media/mmc/mconfig`
- **ログファイル**: `/tmp/log/mocula.log`
- **PID ファイル**: `/var/run/mocula.pid`
- **起動スクリプト**: `/etc/init.d/S76mocula`

---

## 設定ファイル（mconfig）

INI 形式。SD カード上の `/media/mmc/mconfig` に配置する。

```ini
[global]
tenantKey=<テナントキー>
cameraKey=<カメラキー>
origin=https://qa1.mocula-dev.com  # 省略時は https://app.mocula.jp
```

| キー        | セクション | 説明                     |
| ----------- | ---------- | ------------------------ |
| `tenantKey` | `global`   | テナント識別子           |
| `cameraKey` | `global`   | カメラ識別子             |
| `apiOrigin` | `dev`      | API ベース URL（省略可） |

---

## 起動コマンド

```sh
/scripts/mocula.sh on       # デーモン起動
/scripts/mocula.sh off      # デーモン停止
/scripts/mocula.sh restart  # 再起動
/scripts/mocula.sh watchdog # プロセス死活監視（cron から毎分呼び出し）
```

`watchdog` は `/etc/crontab` に登録されており、デーモンが落ちていれば自動再起動する。

---

## 動作フロー

```
起動
 └─ mconfig 読み込み（tenantKey / cameraKey / apiOrigin）
     └─ メインループ（1秒ごと）
          ├─ [60秒ごと] camera-sync API を呼び出し
          │    ├─ デバイス情報収集（SSID / RSSI / IP / タイムスタンプ）
          │    ├─ POST /api/v1/camera-sync/{tenantKey}/{cameraKey}
          │    └─ レスポンスから isEnabled / checkInterval / uploadUrls を取得
          │
          └─ [isEnabled=true かつ checkInterval 秒ごと]
               ├─ uploadUrls キューから URL を 1 件取り出し
               ├─ JPEG キャプチャ（/scripts/cmd jpeg）
               ├─ tar アーカイブ作成（JPEG + contents.json）
               └─ S3 pre-signed URL へ PUT アップロード
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
  "wifi": { "ssid": "...", "rssi": -57 },
  "ip":   { "address": "192.168.x.x", "netmask": "255.255.255.0" },
  "timestamp": 1771545741490
}
```

**レスポンス:**
```json
{
  "success": true,
  "data": {
    "isEnabled": true,
    "checkInterval": 10,
    "uploadUrls": ["https://s3.amazonaws.com/..."]
  }
}
```

| フィールド      | 説明                                         |
| --------------- | -------------------------------------------- |
| `isEnabled`     | アップロード機能の有効/無効                  |
| `checkInterval` | アップロード間隔（秒）                       |
| `uploadUrls`    | S3 pre-signed URL のリスト（有効期限 60 秒） |

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

---

## 既知の制限事項

- **pre-signed URL の有効期限**: `uploadUrls` の有効期限は 60 秒。`checkInterval` や URL 数の組み合わせ次第では camera_sync 取得後のアップロードが期限切れになるリスクがある（TODO）。

---

## 起動時の DNS 問題について

iCamera_app（カメラ純正ファームウェア）が起動時に `/tmp/resolv.conf` を上書きするため、udhcpc が設定した DNS が失われる。`S76mocula` の `start` 処理で `udhcpc` に `USR1 (RENEW)` シグナルを送ることで回避している。

```sh
# /etc/init.d/S76mocula より
kill -USR1 $(pgrep udhcpc) > /dev/null 2>&1
sleep 1
/scripts/mocula.sh on &
```
