# WebRTC ライブビュー機能 仕様書

## 概要

ブラウザからネットワークカメラの映像をリアルタイムに閲覧する機能の仕様。  
カメラは NAT 内ネットワークにあり、バックエンドへのアウトバウンド HTTPS のみ可能。

> **シグナリング方式（2026-07 更新）**: 常時ロングポーリングは廃止した。ライブ開始指示は既存の
> camera-sync（`POST /api/v1/camera-sync/...`、mocula.sh が 60 秒ごとに送信）のレスポンスに
> `liveAction` / `liveSessionId`（スカラのみ）を混ぜて配信する。カメラは開始指示を受けたときだけ
> `mocula_live.sh` をオンデマンド起動し、1 セッションの生存期間だけ双方向通信する。視聴者は開始まで
> 最大 60 秒待つ。SDP 本体は camera-sync には載せず、別リクエスト（`/offer` GET）で取得する。
> API の正本はバックエンドの OpenAPI 定義を参照。以下は本方式に合わせて改訂中。

**P2P 成立時**: go2rtc を介した H.264 WebRTC ストリーム（ハードウェアエンコード済み、1920×1080）  
**P2P 不成立時**: 5 秒おきの JPEG 静止画をバックエンド経由でブラウザに配信

---

## アーキテクチャ

```
[ブラウザ]
    │  HTTPS (app.mocula.jp)
    ▼
[バックエンド] ◄─ camera-sync 応答に liveAction=offer を載せる（60秒周期）
    │                                    │
    │  ① mocula.sh が検知 → mocula_live.sh start <id> をオンデマンド起動
    │  ② GET /offer で offer SDP 取得（単発）
    │  ③ POST /status で state/consumers 報告・stop/image 受信（セッション中のみ、既定10秒間隔）
    ▼
[カメラ: mocula_live.sh]
    │  localhost:1984 (go2rtc API)
    ▼
[go2rtc] ─── UDP:8555 ────────────────────────── [ブラウザ]
                        (WebRTC P2P, STUN経由)
```

フォールバック時:

```
[カメラ: mocula_live.sh] ─── HTTPS POST (JPEG) ──► [バックエンド]
                                                         │
[ブラウザ] ◄──────── HTTPS GET (/frame) ─────────────────┘
```

---

## セッション状態遷移

```
IDLE
  │  ブラウザが視聴開始リクエスト
  ▼
OFFER_QUEUED
  │  バックエンドが offer を保持
  ▼
SENT_TO_CAMERA
  │  カメラが GET /offer で offer SDP を単発取得
  ▼
ANSWERED
  │  カメラが /answer に answer SDP を POST
  ▼
CONNECTED ──── ブラウザが ICE 失敗を報告 ────► IMAGE_FALLBACK
  │                                                  │
  │  ブラウザ切断 / バックエンドが stop アクション       │  ブラウザ切断 / stop
  ▼                                                  ▼
CLOSED                                           CLOSED

SENT_TO_CAMERA ──── カメラが busy/stack_failed を報告 ──────► IMAGE_FALLBACK
SENT_TO_CAMERA ──── offer 取得後 30 秒経っても answer 未着 ──► IMAGE_FALLBACK
ANSWERED       ──── 60 秒経っても consumer が付かない ───────► IMAGE_FALLBACK
ANSWERED       ──── ブラウザが ICE 失敗を報告 ───────────────► IMAGE_FALLBACK
```

※ ice-failed 報告（ブラウザが ICE 接続失敗を検知して通知するエンドポイント）は CLOSED を除く
どの状態からでも受理される。ANSWERED から answer 受信直後の接続試行で発生するのが典型的で、
上の図はそのケースを明示するために ANSWERED からの矢印も追加している。

---

## カメラ向け API

認証: `tenantKey` / `cameraKey` による URL パス認証（camera-sync と同じモデル）

### ライブ開始トリガ（camera-sync レスポンス）

`POST /api/v1/live-signal/.../poll` の常時ロングポーリングは**廃止**。開始指示は camera-sync
（`POST /api/v1/camera-sync/{tenantKey}/{cameraKey}`）のレスポンス `data` に以下のスカラ 2 キーで載せる。
キー欠落は不可（パーサの位置ズレ防止のため常に両方返す）。

| フィールド | 値 | 説明 |
|-----------|-----|------|
| `liveAction` | `"offer"` \| `"none"` | `offer` のときライブ開始。指示なしは `none` |
| `liveSessionId` | `"<uuid>"` \| `""` | セッション識別子。`none` のときは空文字 |

カメラ（mocula.sh）は `liveAction=offer` かつ未処理の新しい `liveSessionId` を検出したときだけ
`mocula_live.sh start <id>` をオンデマンド起動する（直近処理 id を記録し同一 id では再起動しない）。
バックエンドはセッションが active 化したら以降の camera-sync で `liveAction:"none"` を返す（再トリガ防止）。

### `GET /api/v1/live-signal/{tenantKey}/{cameraKey}/offer?session={id}`

カメラが offer SDP を単発取得する。**成功**: `200` + `Content-Type: application/sdp`（生 SDP）／ **なし**: `404`。  
ブラウザの offer SDP は `iceGatheringState === 'complete'` 待機後に送信されたもの（non-trickle）。

### `POST /api/v1/live-signal/{tenantKey}/{cameraKey}/status?session={id}`

セッション実行中のみカメラが `live_sessionPoll`（既定 10 秒）間隔で送る双方向通信エンドポイント。

**リクエストボディ** (application/json): `{ "state": "streaming" | "image", "consumers": <number> }`  
**レスポンス**: `204` + レスポンスヘッダ `X-Mocula-Action: continue | stop | image`
（`stop`=セッション終了、`image`=静止画フォールバックへ）

### `POST /api/v1/live-signal/{tenantKey}/{cameraKey}/answer`

カメラが SDP exchange 結果をバックエンドに返す。

**成功時**: `?session={id}` + `Content-Type: application/sdp` ボディ (go2rtc の answer SDP そのまま)  
**失敗時**: `?session={id}&error=busy` または `?session={id}&error=stack_failed`（ボディなし）

バックエンドはこの answer SDP を、ブラウザの answer 取得ロングポーリング（`GET /live-view/{cameraId}/session/{id}/answer`）へ転送する。

### `POST /api/v1/live-frame/{tenantKey}/{cameraKey}`

静止画フォールバック時にカメラが 5 秒おきに JPEG を POST する。

**クエリパラメータ**: `?session={id}`  
**ボディ**: `Content-Type: image/jpeg`、生バイナリ（実測 ~19KB @ 640×360）  
**バックエンドの保持**: 最新 1 フレームのみメモリ（またはごく短い TTL キャッシュ）で保持する。S3 等への永続化は不要。

**レスポンスヘッダ**:

| `X-Mocula-Action` | 意味 |
|-------------------|------|
| `continue`（または省略） | 次のフレームを送り続ける |
| `stop` | セッション終了、カメラは静止画ループを抜ける |

カメラ側の最大継続時間: `live_sessionMax`（既定 600 秒）。WebRTC P2P 区間と合算した配信開始からの
経過時間で判定するため、P2P からのフォールバック時にカウンタがリセットされることはない。

---

## ブラウザ向け API

認証: 既存のアプリ認証を使用（仕様詳細はバックエンド実装チームに委ねる）

### `POST /api/v1/live-view/{cameraId}/session`

ブラウザが視聴開始。offer SDP を送ると answer を待たずに即座に `sessionId` を返す（非同期モデル）。
answer は別リクエスト（下記 `GET .../answer`）でポーリング取得する。

**リクエスト**: `Content-Type: application/sdp`、ブラウザが生成した offer SDP  
**レスポンス成功**: `202`、`{"sessionId": "<uuid>"}`  
**レスポンス失敗**:

| ステータス | 意味 |
|-----------|------|
| `404` | カメラが存在しない |
| `409` | カメラは同時に1セッションしか配信できないため、既に別の視聴セッションがアクティブ |

**409 の実装と再試行のタイミング**: バックエンドは事前チェック(高速パス、`404`同様に軽量)と、
カメラ単位の排他ロック(DynamoDB `TransactWriteItems` による原子的なロック取得、ほぼ同時の
リクエストが来た場合の TOCTOU レースを閉じる)の二段構えで多重セッションを防ぐ。ロックは
視聴中の `/status` 報告のたびにセッション本体の TTL と一緒にスライディング延長されるため、
先行セッションが視聴を続けている限り 409 が返り続ける。先行セッションが `DELETE` で終了する
(通常経路)か、TTL(既定600秒)が切れて自動失効すると、以後の作成が成功するようになる。
クライアント SDK(`mocula-backend` の `client/live-viewer/MoculaLiveViewer.ts`)はこの 409 を
専用の `LiveViewerAlreadyStreamingError` として `instanceof` 判別できるようにしている。

**ボディが SDP のまま（JSON化しない）理由**: SDP 内の `\r\n` を ash/awk で JSON エスケープするのが困難なため、カメラ〜バックエンド間で SDP を生バイナリとして通す。バックエンド〜ブラウザ間も合わせる。

### `GET /api/v1/live-view/{cameraId}/session/{id}/answer`

ブラウザが answer SDP をポーリング取得する（サーバ側で短時間ロングポーリング）。

| ステータス | 意味 |
|-----------|------|
| `200` + `Content-Type: application/sdp` | answer SDP が確定（`setRemoteDescription` へ渡す） |
| `202` | まだ未確定。サーバ側ロングポーリング窓が尽きただけなので即座に再取得する |
| `503 {"reason": "busy"\|"stack_failed"\|"timeout"}` | P2P 不成立が確定、静止画フォールバックへ |
| `404` | セッションが存在しない（TTL 失効等） |

### `POST /api/v1/live-view/{cameraId}/session/{id}/ice-failed`

ブラウザが ICE 失敗を報告。バックエンドはセッションを IMAGE_FALLBACK に遷移させ、カメラへ image アクションを送る。

### `DELETE /api/v1/live-view/{cameraId}/session/{id}`

視聴終了。バックエンドはカメラへ stop アクションを送る。

### `GET /api/v1/live-view/{cameraId}/frame`

最新の静止画フレームを返す。IMAGE_FALLBACK 時にブラウザが 5 秒おきにポーリングする。

**レスポンス**: `Content-Type: image/jpeg`、最新フレーム  
**フレームがまだない場合**: `503`

---

## ブラウザ側実装責務

上記の非同期フロー（offer 送信 → sessionId 即時受信 → answer ポーリング → ICE 確立、失敗時は
ice-failed 報告して静止画フォールバックへ）を実装した正式なクライアント SDK が
`mocula-backend` リポジトリの `client/live-viewer/MoculaLiveViewer.ts` にある
（`client/examples/vanilla/live-view.html`、`client/examples/react/` にサンプルあり）。
自前実装する場合はこちらを正本として参照すること。ここに古いコード例を重複して置かないのは、
実装が変わった際にこのドキュメントだけが取り残されて食い違う事故を防ぐため。

---

## STUN 選定と TURN 不採用の根拠

### STUN

| エンドポイント | 用途 |
|--------------|------|
| `stun:stun.l.google.com:19302` | カメラ側（mocula_live.sh が生成する go2rtc 設定 `ice_servers` の既定値） |
| `stun:stun.l.google.com:19302` | ブラウザ側（`MoculaLiveViewer` の既定 `rtcConfig`。呼び出し側は `rtcConfig` オプションで追加のSTUN/TURNを指定可能） |

カメラ側の STUN サーバーは `mocula_live.sh` が生成する go2rtc 設定（`ice_servers`）で指定する。既定は `stun.l.google.com`。

### TURN 不採用の根拠

視聴 1 人・1 時間あたりのコスト比較:

| 方式 | 転送量 | AWS egress 概算 | 追加インフラ |
|------|--------|----------------|------------|
| TURN 中継（H.264 0.5〜1Mbps） | 225〜450 MB | $0.026〜$0.051 | coturn EC2 常時稼働 + EIP + UDP ポートレンジ開放 + 認証情報発行 + 監視 |
| TURN（ビットレート制限 256kbps） | 約 115 MB | 約 $0.013 | 同上 |
| **静止画 5 秒おき（実測 19KB/枚）** | **約 13.7 MB** | **約 $0.0016** | **追加インフラ不要**（既存 HTTPS のみ） |

- coturn は ALB/NLB の背後に置けず、単体 EC2 として常時運用が必要
- 転送量で 8〜33 倍の差があり、静止画フォールバックが許容できる要件では TURN の利点がない
- symmetric NAT（TURN が必要になる主なケース）は家庭用 Wi-Fi では少数
- **将来 TURN が必要になった場合**: go2rtc 設定の `ice_servers` にブラウザ側の `iceServers` 設定を追加するだけで対応可能。アーキテクチャの変更は不要

---

## 運用要件

### バックエンドインフラ

| 要件 | 値 | 理由 |
|-----|----|------|
| /status・/offer エンドポイント | 通常の短時間リクエスト | 常時ロングポーリング廃止によりアイドル接続は無い |
| /live-frame エンドポイント | メモリ or 短 TTL キャッシュのみ | S3 等への書き込みは不要、最新 1 フレームのみ保持 |
| セッション最大時間 | 任意（推奨 10 分） | カメラ側は `live_sessionMax`（既定 600 秒、P2P+画像フォールバック合算）で自動終了。再接続には新規セッション作成が必要 |

### カメラ側設定（/media/mmc/mconfig）

追加の必須キーはない。オプションの `[live]` セクション:

```ini
[live]
disabled=0       # 1 にするとモジュール全体を無効化
idleTimeout=120  # ビューア不在で何秒後にスタックを停止するか
sessionPoll=10   # セッション中の state/consumers 報告間隔（秒）
sessionMax=600   # 1 セッション(配信開始から、P2P+画像フォールバック合算)の最大継続時間（秒）。
                 # 超過すると自動切断され、視聴には新規セッションでの再接続が必要
```

`pollTimeout` はアイドルロングポーリング廃止により削除。

### 相互排他: hack.ini の RTSP/HomeKit との競合

カメラが hack.ini で RTSP/HomeKit/WebRTC を有効にしている場合、go2rtc と v4l2rtspserver がすでに起動している。この場合 `mocula_live.sh` は `busy` をバックエンドに報告し、ブラウザは静止画フォールバックに移行する。

WebUI から RTSP を有効にするとポート 8554 が使用中になるため、`mocula_live.sh` の起動は失敗する。ライブ視聴中に WebUI で RTSP を有効化すると次回の `stack_start()` が失敗することを仕様書に明記する。

### 繰り返し P2P 失敗するカメラ

CGNAT や symmetric NAT 環境では P2P が常に失敗する。この場合、バックエンドはカメラを「フォールバック専用」とマークし、offer を送らずに直接 `image` アクションを返すことを推奨する。これにより毎回最大 30〜60 秒のネゴシエーション待機（offer取得後の応答待ちタイムアウトや ANSWERED 滞留タイムアウト）をスキップできる。

---

## カメラ側の実装ファイル

| ファイル | 内容 |
|---------|------|
| `overlay_rootfs/scripts/mocula_live.sh` | ライブセッションデーモン本体 |
| `overlay_rootfs/scripts/mocula.sh` | ライフサイクル連動（on/off/restart/watchdog の末尾で `mocula_live.sh` を呼び出す） |
