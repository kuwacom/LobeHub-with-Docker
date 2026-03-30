# LobeHub Self-Hosting

このリポジトリは、[LobeHub](https://github.com/lobehub/lobehub)の`docker-compose`内にある構成を外に出してカスタマイズしたものです。  
`deploy`版と`production`版を融合させています。

## 現在の構成

現在の root 構成は、LobeHub の `deploy` ベースを維持しつつ、次の要素を追加した merged 構成です。

- 認証: Casdoor
- 監視: Grafana / Prometheus / Tempo / OTel Collector
- オブジェクトストレージ: RustFS
- DB: PostgreSQL
- キャッシュ: Redis
- 検索: SearXNG
- ネットワーク: CloudFlareTunnel

ポイント:

- 認証は `AUTH_SSO_PROVIDERS=casdoor` により Casdoor を使用します
- `AUTH_DISABLE_EMAIL_PASSWORD=1` により、LobeHub 側の email/password 登録は無効です
- ファイルストレージは MinIO ではなく RustFS を使っています
- 永続化は Docker named volume ではなく、すべてホスト側ディレクトリに bind mount しています

## SearXNG 構成

- `searxng/settings.yml` は巨大な全量設定ではなく、`use_default_settings` で upstream defaults を継承し、`json` フォーマットや `ja-JP` など必要最小限だけ上書きしています
- LobeHub 側の検索連携は `SEARCH_PROVIDERS=searxng` と `SEARXNG_URL` を使う形に揃えています
- compose 内の `searxng` は `with-searxng` profile で起動有無を切り替えられるため、外部 `SearXNG` を使う場合は内蔵コンテナを起動しません
- compose 内の `SearXNG` は `./searxng` を `/etc/searxng` へ bind mount し、検索キャッシュだけ named volume `searxng-cache` に保持します

### 外部 SearXNG への切り替え

- ローカルの `SearXNG` を使う場合は `.env` の `COMPOSE_PROFILES` に `with-searxng` を含めたままにします
- 外部の `SearXNG` を使う場合は `COMPOSE_PROFILES` から `with-searxng` を外し、`SEARXNG_URL` を外部 URL に変更します
- 外部 `SearXNG` 側では `json` フォーマットを有効にしてください
- compose 内の `SearXNG` UI を別途公開する場合だけ `SEARXNG_BASE_URL` を実際の公開 URL に合わせて変更してください

例:

```env
COMPOSE_PROFILES=
SEARXNG_URL=https://searx.example.com
```

## ディレクトリ構成

主なファイル / ディレクトリは次のとおりです。

- [`docker-compose.yml`](./docker-compose.yml): 実運用用の Compose 定義
- [`.env`](./.env): 実運用用環境変数
- [`casdoor/init_data.json.exmaple`](./casdoor/init_data.json.exmaple): Casdoor 初期データテンプレート
- [`casdoor/init_data.json`](./casdoor/init_data.json): Casdoor 初期データ出力先
- [`bucket.config.json`](./bucket.config.json): RustFS バケット公開設定
- [`setup.sh`](./setup.sh): merged 構成向け初期化スクリプト
- [`searxng/settings.yml`](./searxng/settings.yml): SearXNG 設定
- [`grafana/`](./grafana): Grafana datasource / dashboard / data
- [`prometheus/`](./prometheus): Prometheus 設定 / data
- [`tempo/`](./tempo): Tempo 設定 / data
- [`otel-collector/`](./otel-collector): OTel Collector 設定
- [`postgresql/data`](./postgresql/data): PostgreSQL データ
- [`redis/data`](./redis/data): Redis データ
- [`rustfs/data`](./rustfs/data): RustFS データ
- [`rustfs/logs`](./rustfs/logs): RustFS ログ
- [`scripts/`](./scripts): 運用補助スクリプト

## 公開ポート / Web UI

現在の公開ポートは次のとおりです。

- `3210`: LobeHub
- `8000`: Casdoor
- `9000`: RustFS API
- `9001`: RustFS Console
- `3000`: Grafana
- `4317`: OTel Collector gRPC
- `4318`: OTel Collector HTTP
- `5432`: PostgreSQL
- `6379`: Redis

用途:

- `http://<host>:3210`: LobeHub 本体
- `http://<host>:8000`: Casdoor 管理 UI / 認証 UI
- `http://<host>:9001`: RustFS Console
- `http://<host>:3000`: Grafana

## 認証 / アカウント運用

### 基本方針

現在の構成では、LobeHub 側で新規登録はしません。

- LobeHub の signup は無効
- Casdoor を ID Provider として利用
- ユーザー追加は Casdoor 側で行う前提

### Casdoor の seed 情報

`casdoor/init_data.json.exmaple` には初期ユーザーや初期アプリ設定のテンプレートが含まれています。

過去に確認した内容:

- `admin@example.com`
- `pfub7l@example.com`
- 初期パスワード: `pswd123`

本番運用前に、Casdoor の管理画面から必ず変更してください。

### 登録方法

新しいユーザーを追加する流れ:

1. Casdoor 管理画面へログインする
2. Casdoor 側でユーザーを作成する
3. そのユーザーが LobeHub にアクセスする
4. Casdoor 経由で認証し、LobeHub を利用する

### LobeHub 側のユーザー設定の扱い

LobeHub OSS では、次の設定は基本的にユーザー単位で保存されます。

- provider 設定
- enabled / disabled model
- custom provider
- default agent
- keyVaults

そのため、管理者 1 人の設定を全ユーザーへ配るには、DB コピーか server-side `.env` 化が必要です。

## 監視構成

### network-service

`network-service` は実体としては `tail -f /dev/null` で待機するだけの軽いコンテナです。

役割:

- 複数サービスに同じ network namespace を共有させる
- `localhost` 前提の設定を使いやすくする
- ポート公開を 1 か所に集約する

共有しているサービス:

- `lobe`
- `rustfs`
- `casdoor`
- `grafana`
- `tempo`
- `prometheus`
- `otel-collector`

### otel-collector

OTel Collector は telemetry の受け口です。

役割:

- `lobe` から送られる OTLP trace / metrics を受け取る
- trace を Tempo へ送る
- collector 自身の metrics を Prometheus へ送る

### Tempo

Tempo は trace 保存用バックエンドです。

役割:

- LobeHub の trace を保存する
- Grafana から trace を検索 / 表示する
- trace から service graph や span metrics を生成して Prometheus に送る

### Prometheus

Prometheus はメトリクス保存用です。

現在見ているもの:

- Prometheus 自身のメトリクス
- Tempo のメトリクス
- Tempo から生成された service graph / span metrics
- OTel Collector 自身のメトリクス

### Grafana

Grafana には datasource のみ登録済みです。

- Prometheus datasource
- Tempo datasource

ダッシュボードはほぼ空です。初期状態では Explore を使って直接見る運用になります。

## 永続化

すべてホスト側ディレクトリに保存するようにしてあります。

- PostgreSQL: [`postgresql/data`](./postgresql/data)
- Redis: [`redis/data`](./redis/data)
- RustFS: [`rustfs/data`](./rustfs/data)
- RustFS logs: [`rustfs/logs`](./rustfs/logs)
- Grafana: [`grafana/data`](./grafana/data)
- Tempo: [`tempo/data`](./tempo/data)
- Prometheus: [`prometheus/data`](./prometheus/data)

### 権限注意

**Ubuntu で RustFS を bind mount する場合、所有者を `10001:10001` にしないと `Permission denied` になることがあります。**

例:

```bash
sudo mkdir -p rustfs/data rustfs/logs
sudo chown -R 10001:10001 rustfs
sudo chmod -R 755 rustfs
```

Grafana / Prometheus / Tempo は compose 側で `user: "0"` にしてあり、bind mount での権限エラーを避けています。

## 初回確認コマンド

設定確認:

```bash
docker compose config
```

イメージ取得:

```bash
docker compose pull
```

起動例:

ローカル `SearXNG` を使う場合:

```bash
docker compose up -d network-service postgresql redis rustfs rustfs-init searxng tempo prometheus otel-collector casdoor
docker compose up -d lobe grafana
```

外部 `SearXNG` を使う場合:

```bash
docker compose up -d network-service postgresql redis rustfs rustfs-init tempo prometheus otel-collector casdoor
docker compose up -d lobe grafana
```

状態確認:

```bash
docker compose ps
docker compose logs -f lobe casdoor rustfs grafana tempo prometheus cloudflared --tail 200
```

簡易疎通確認:

```bash
curl http://localhost:9000/health
curl http://localhost:8000/.well-known/openid-configuration
```

ローカル `SearXNG` の設定確認:

```bash
docker compose exec searxng sed -n '1,120p' /etc/searxng/settings.yml
```

## モデル / provider 設定の考え方

### 1. サーバー全体で共有するもの

`.env` に置くもの。

例:

- `OPENAI_API_KEY`
- `OPENAI_PROXY_URL`
- `OPENAI_MODEL_LIST`
- `DEFAULT_AGENT_CONFIG`
- `SYSTEM_AGENT`
- `ENABLED_*`

### 2. ユーザーごとに持つもの

DB に保存されるもの。

- `ai_providers`
- `ai_models`
- `user_settings.key_vaults`
- `user_settings.default_agent`
- `user_settings.language_model`

### 3. custom provider

custom provider は official docs ベースの `.env` だけでは完全再現しづらいです。

- UI で作るとユーザー単位になる
- DB seed / SQL で配る方が現実的

## 生成済みファイル

### [`scripts/out.jsonl`](./scripts/out.jsonl)
`0_0@kuwa.dev` の有効 provider / model をエクスポートした結果です。
以下のコマンドでエクスポートできます。
```bash
sudo bash ./scripts/export-master-model-settings.sh > out.jsonl
```

### [`scripts/generated-model-provider.env`](./scripts/generated-model-provider.env)
`out.jsonl` をもとに、official docs へ落とし込める部分だけを ENV 候補としてまとめたファイルです。

注意:

- コメントは日本語化済み
- API キーや proxy URL の平文は手入力前提の部分あり
- custom provider はヒントのみ

## 作成済みスクリプト

### [`scripts/export-master-model-settings.sh`](./scripts/export-master-model-settings.sh)
`0_0@kuwa.dev` の現在設定を SQL だけで取得するスクリプトです。

用途:

- 現在の enabled provider / model を確認
- `.env` 候補を生成するための元データ取得

実行例:

```bash
sudo bash ./scripts/export-master-model-settings.sh > out.jsonl
```

出力セクション:

- `USER`
- `USER_SETTINGS`
- `ENABLED_AI_PROVIDERS`
- `ENABLED_AI_MODELS`
- `ENV_CANDIDATES`
- `ENABLED_CUSTOM_PROVIDER_HINTS`

制約:

- SQL-only 版なので `key_vaults` は復号できない
- API キー平文は取得不可

### [`scripts/copy-master-model-settings.sh`](./scripts/copy-master-model-settings.sh)
`0_0@kuwa.dev` の model/provider 設定を、直近 `HOURS_BACK` 時間以内に作成された他ユーザーへコピーします。
**新規ユーザー作成後は、これを実行して新しいユーザーにmodel設定を適応する必要があります。**  
**ただし、APIエンドポイントやkeyが見えるので、信頼できるユーザーのみに利用させるようにしましょう**

コピー対象:

- `user_settings.key_vaults`
- `user_settings.language_model`
- `user_settings.default_agent`
- `ai_providers`
- `ai_models`

実行例:

```bash
sudo bash ./scripts/copy-master-model-settings.sh
```

オプション例:

```bash
SOURCE_EMAIL='0_0@kuwa.dev' HOURS_BACK=6 bash scripts/copy-master-model-settings.sh
```

### [`scripts/apply-generated-model-settings.sh`](./scripts/apply-generated-model-settings.sh)
`copy-master-model-settings.sh` をベースに、さらに [`generated-model-provider.env`](./scripts/generated-model-provider.env) を参照して、OpenAI の `apiKey` / `baseURL` を target user 側へ反映するスクリプトです。

用途:

- source user の DB 設定コピー
- custom provider もそのままコピー
- OpenAI の `key_vaults` は generated env の値で再暗号化して上書き

実行例:

```bash
bash scripts/apply-generated-model-settings.sh
```

オプション例:

```bash
SOURCE_EMAIL='0_0@kuwa.dev' HOURS_BACK=6 bash scripts/apply-generated-model-settings.sh
```

注意:

- `generated-model-provider.env` は bash で丸ごと source すると危ないため、このスクリプトは必要な値だけを grep で読みます
- OpenAI の `key_vaults` 暗号化のみ、`lobe` コンテナ内の Node 標準 `crypto` を使います

### [`scripts/backup-user-data.sh`](./scripts/backup-user-data.sh) 指定ユーザーのバックアップ
指定ユーザーの LobeHub コアデータを JSON でバックアップするスクリプトです。  
対象は、本家 LobeHub の PostgreSQL importer / exporter が扱う中核テーブルに寄せています。

主な対象:

- `user_settings`
- `user_installed_plugins`
- `ai_providers`
- `ai_models`
- `session_groups`
- `agents`
- `sessions`
- `topics`
- `threads`
- `messages`
- `message_plugins`
- `message_translates`
- `agents_to_sessions`

実行例:

```bash
SOURCE_EMAIL='user@example.com' bash scripts/backup-user-data.sh > scripts/user-backup.json
```

```bash
SOURCE_USER_ID='user_xxx' OUTPUT_FILE=./scripts/user-backup.json bash scripts/backup-user-data.sh
```

注意:

- 出力は JSON なので、標準出力へ書く場合はリダイレクトしてください
- `users` テーブル本体は restore 対象ではなく、`source_user` としてメタデータだけ保存します
- auth テーブル、RustFS の実ファイル、knowledge base / file / blob 系データは含めません

### [`scripts/restore-user-data.sh`](./scripts/restore-user-data.sh) 指定ユーザーの修復
`backup-user-data.sh` で作成したバックアップを、指定した既存ユーザーへ restore するスクリプトです。  
restore 前に、対象ユーザーの managed tables は置き換えられます。

実行例:

```bash
TARGET_EMAIL='user@example.com' BACKUP_FILE=./scripts/user-backup.json bash scripts/restore-user-data.sh
```

```bash
TARGET_USER_ID='user_xxx' BACKUP_FILE=./scripts/user-backup.json bash scripts/restore-user-data.sh
```

注意:

- restore 先ユーザーは、事前に LobeHub 上へ存在している必要があります
- `users` / auth 関連は作成しないので、Casdoor などの認証基盤側ユーザー作成は別途必要です
- `topics.group_id` / `threads.group_id` / `messages.group_id` / `messages.message_group_id` は、未管理の group chat 系テーブルへぶら下がるため restore 時に `null` へ落とします

## リセット方針

### 全部リセットしたい場合

対象ディレクトリを消せば、そのサービスは初期化されます。

- `postgresql/data`
- `redis/data`
- `rustfs/data`
- `rustfs/logs`
- `grafana/data`
- `tempo/data`
- `prometheus/data`

### Casdoor を残して LobeHub だけ消したい場合

注意:

- Casdoor も PostgreSQL を使っている
- そのため `postgresql/data` を丸ごと消すと Casdoor も消える

つまり:

- 全部消すなら `postgresql/data` ごと消す
- Casdoor を残したいなら PostgreSQL 全削除はしない
- LobeHub だけ消したいなら DB 単位で `lobechat` を初期化する必要がある

## 再設定時の注意

- [`setup.sh`](./setup.sh) は merged 構成向けの初期化スクリプトです
- 初回構築時は `bash ./setup.sh` で `.env` と `casdoor/init_data.json` を現在の構成に合わせて更新できます
- 既存の `postgresql/data` がある場合は `casdoor/init_data.json` の変更が Casdoor DB へ自動反映されません
- 元の deploy 用スクリプトは [`original-setup.sh`](./original-setup.sh) として残しています
- 再構築時は `docker-compose.yml` / `.env` / `casdoor/init_data.json.exmaple` / `casdoor/init_data.json` / `scripts/` を基準に運用してください

## 既知の注意点

- `generated-model-provider.env` や `.env` に実キーを書いた場合は、取り扱いに注意してください
- `casdoor/init_data.json.exmaple` と `casdoor/init_data.json` には seed 情報が入っているため、本番前に Casdoor 側で変更が必要です
- custom provider は `.env` だけで完全再現しづらいため、DB / UI / SQL 管理の方が向いています
- RustFS API ポートは現在 9000 固定前提です

## 構築時にやると良いこと

- Casdoor seed ユーザーのパスワード変更
- Grafana の初期ダッシュボード追加
- provider 設定 UI を一般ユーザーへ見せるかどうかの方針決定
- `blackbox-ai` を DB seed 化するか、OpenAI 互換 ENV に寄せるかの決定
- 必要なら dry-run スクリプトの追加

