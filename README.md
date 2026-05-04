# LobeHub Self-Hosting

LobeHub を自己ホストするための `docker-compose` 構成です。  
本家 LobeHub の `deploy` / `production` 系構成を土台に、認証、監視、検索、オブジェクトストレージを外出しして運用しやすくしたリポジトリです。

この README は次の 2 つを両立するように整理しています。

- 初めて触る人が「何をどう起動すればよいか」を迷わない
- 慣れている人が「必要な設定や運用コマンド」にすぐ飛べる

## 目次

- [最初に読む場所](#最初に読む場所)
- [この構成で動くもの](#この構成で動くもの)
- [5 分で始める](#5-分で始める)
- [セットアップモード](#セットアップモード)
- [起動パターン](#起動パターン)
- [よく使う確認コマンド](#よく使う確認コマンド)
- [スクリプト一覧](#スクリプト一覧)
- [運用シナリオ別の使い方](#運用シナリオ別の使い方)
- [主要ファイルとディレクトリ](#主要ファイルとディレクトリ)
- [主要な環境変数](#主要な環境変数)
- [認証とユーザー運用](#認証とユーザー運用)
- [監視構成](#監視構成)
- [永続化とデータ保存先](#永続化とデータ保存先)
- [リセット方針](#リセット方針)
- [既知の注意点](#既知の注意点)

## 最初に読む場所

最短で把握したい人はここだけ見れば大丈夫です。

1. まずは [5 分で始める](#5-分で始める)
2. SearXNG の使い方を選ぶなら [起動パターン](#起動パターン)
3. 運用スクリプトを探すなら [スクリプト一覧](#スクリプト一覧)
4. ユーザー管理まわりを見るなら [認証とユーザー運用](#認証とユーザー運用)
5. 消してよいデータ範囲を確認するなら [リセット方針](#リセット方針)

## この構成で動くもの

このリポジトリの構成要素は次のとおりです。

| 項目 | 採用コンポーネント | 役割 |
| --- | --- | --- |
| アプリ本体 | LobeHub | チャット UI / モデル呼び出し |
| 認証 | Casdoor | SSO / ユーザー認証 |
| DB | PostgreSQL | LobeHub / Casdoor の永続データ |
| キャッシュ | Redis | セッション / キャッシュ |
| オブジェクトストレージ | RustFS | S3 互換ストレージ |
| 検索 | SearXNG | Online Search の検索バックエンド |
| 監視 | Grafana / Prometheus / Tempo / OTel Collector | メトリクス / トレース可視化 |
| 公開経路 | Cloudflared | Cloudflare Tunnel 経由の公開 |

この構成の特徴:

- LobeHub のメールアドレス / パスワード登録は無効で、Casdoor を認証基盤として使います
- MinIO ではなく RustFS を使います
- 永続化は Docker named volume ではなく、基本的にホスト側ディレクトリへ bind mount します
- `with-searxng` profile により、内蔵 SearXNG と外部 SearXNG を切り替えられます

## 5 分で始める

### 前提

最低限、次が必要です。

- `docker` と `docker compose`
- `bash`
- `python3` または `python`
- `openssl`

`setup.sh` は `.env` が無ければ [`.env.example`](./.env.example) から自動生成します。

### 最短手順

1. 初期設定を実行する

```bash
bash ./setup.sh
```

2. 構成を確認する

```bash
docker compose config
```

3. イメージを取得する

```bash
docker compose pull
```

4. 基盤サービスを起動する

```bash
docker compose up -d network-service postgresql redis rustfs rustfs-init tempo prometheus otel-collector casdoor
docker compose up -d searxng
docker compose up -d lobe grafana
```

5. 状態を確認する

```bash
docker compose ps
docker compose logs -f lobe casdoor rustfs grafana tempo prometheus --tail 200
```

### 起動後に開く URL

| URL | 用途 |
| --- | --- |
| `http://localhost:3210` | LobeHub |
| `http://localhost:8000` | Casdoor 管理 UI / 認証 UI |
| `http://localhost:9001` | RustFS Console |
| `http://localhost:3000` | Grafana |

### 公開ポート

| ポート | 用途 |
| --- | --- |
| `3210` | LobeHub |
| `8000` | Casdoor |
| `9000` | RustFS API |
| `9001` | RustFS Console |
| `3000` | Grafana |
| `4317` | OTel Collector gRPC |
| `4318` | OTel Collector HTTP |
| `5432` | PostgreSQL |
| `6379` | Redis |

## セットアップモード

[`setup.sh`](./setup.sh) は、利用形態に応じて URL 類をまとめて整えるためのスクリプトです。

### よく使う実行例

```bash
bash ./setup.sh
```

```bash
bash ./setup.sh --mode port --host 192.168.1.10 --yes
```

```bash
bash ./setup.sh --mode domain --protocol https --app-domain lobe.example.com --casdoor-domain auth.example.com --rustfs-domain s3.example.com
```

### モード一覧

| モード | 想定用途 | 主に決まるもの |
| --- | --- | --- |
| `local` | 開発機や単体検証 | `localhost` ベースの URL |
| `port` | LAN 内や IP 直アクセス | `http://<host>:port` 形式の URL |
| `domain` | 本番やリバースプロキシ前提 | 独自ドメインの URL |

### `setup.sh` がやること

- `.env` が無ければ [`.env.example`](./.env.example) から生成する
- `AUTH_SECRET` などのシークレットを必要に応じて生成する
- [`casdoor/init_data.json.exmaple`](./casdoor/init_data.json.exmaple) を元に [`casdoor/init_data.json`](./casdoor/init_data.json) を生成する
- `AUTH_CASDOOR_ISSUER` や `S3_ENDPOINT` などの URL を構成に合わせて更新する
- `docker compose config` を使った構成検証を行う

## 起動パターン

### 1. 内蔵 SearXNG を使う場合

`.env` の `COMPOSE_PROFILES` に `with-searxng` を含めます。

```env
COMPOSE_PROFILES=with-searxng
SEARXNG_URL=http://searxng:8080
```

起動:

```bash
docker compose up -d network-service postgresql redis rustfs rustfs-init tempo prometheus otel-collector casdoor
docker compose up -d searxng
docker compose up -d lobe grafana
```

### 2. 外部 SearXNG を使う場合

`.env` の `COMPOSE_PROFILES` から `with-searxng` を外し、`SEARXNG_URL` を外部 URL へ変更します。

```env
COMPOSE_PROFILES=
SEARXNG_URL=https://searx.example.com
```

起動:

```bash
docker compose up -d network-service postgresql redis rustfs rustfs-init tempo prometheus otel-collector casdoor
docker compose up -d lobe grafana
```

補足:

- 外部 SearXNG 側では `json` フォーマットを有効にしてください
- `SEARXNG_BASE_URL` は SearXNG UI を別途公開する場合だけ実 URL に合わせて調整します

## よく使う確認コマンド

### 構成確認

```bash
docker compose config
docker compose ps
```

### ログ確認

```bash
docker compose logs -f lobe casdoor rustfs grafana tempo prometheus --tail 200
```

### 疎通確認

```bash
curl http://localhost:9000/health
curl http://localhost:8000/.well-known/openid-configuration
```

### SearXNG 設定確認

```bash
docker compose exec searxng sed -n '1,120p' /etc/searxng/settings.yml
```

## スクリプト一覧

運用スクリプトは [`scripts/`](./scripts/) にあります。  
「何に使うか」を最初に判断できるよう、用途別に表にまとめています。

| スクリプト | 役割 | 使うタイミング | 主な入力 | 代表例 |
| --- | --- | --- | --- | --- |
| [`setup.sh`](./setup.sh) | `.env` と Casdoor 初期データのセットアップ | 初回構築、URL 変更、再設定 | `--mode`, `--host`, `--app-domain` など | `bash ./setup.sh --yes` |
| [`original-setup.sh`](./original-setup.sh) | 元の deploy 系セットアップスクリプト | 本家寄りの挙動を参照したい時 | 対話入力 | `bash ./original-setup.sh` |
| [`scripts/export-master-model-settings.sh`](./scripts/export-master-model-settings.sh) | master ユーザーの provider / model 設定を SQL で抽出 | 現在設定の棚卸し、ENV 候補生成 | `SOURCE_EMAIL` | `SOURCE_EMAIL='0_0@kuwa.dev' bash scripts/export-master-model-settings.sh > scripts/out.jsonl` |
| [`scripts/copy-master-model-settings.sh`](./scripts/copy-master-model-settings.sh) | master ユーザーの provider / model 設定を新規ユーザーへ複製 | 新規ユーザーを追加した直後 | `SOURCE_EMAIL`, `HOURS_BACK` | `SOURCE_EMAIL='0_0@kuwa.dev' HOURS_BACK=6 bash scripts/copy-master-model-settings.sh` |
| [`scripts/apply-generated-model-settings.sh`](./scripts/apply-generated-model-settings.sh) | DB コピーに加え、生成済み ENV を使って OpenAI 系の `key_vaults` を再反映 | 新規ユーザーへ実運用向け設定を寄せたい時 | `SOURCE_EMAIL`, `HOURS_BACK` | `SOURCE_EMAIL='0_0@kuwa.dev' HOURS_BACK=6 bash scripts/apply-generated-model-settings.sh` |
| [`scripts/backup-user-data.sh`](./scripts/backup-user-data.sh) | 指定ユーザーの中核データを JSON へバックアップ | 移行前、削除前、復旧用取得 | `SOURCE_EMAIL` または `SOURCE_USER_ID` | `SOURCE_EMAIL='user@example.com' OUTPUT_FILE=./scripts/user-backup.json bash scripts/backup-user-data.sh` |
| [`scripts/restore-user-data.sh`](./scripts/restore-user-data.sh) | バックアップ JSON を既存ユーザーへ restore | ユーザー復旧、複製、移行 | `TARGET_EMAIL` または `TARGET_USER_ID`, `BACKUP_FILE` | `TARGET_EMAIL='user@example.com' BACKUP_FILE=./scripts/user-backup.json bash scripts/restore-user-data.sh` |
| [`scripts/delete-user.sh`](./scripts/delete-user.sh) | 指定ユーザーを PostgreSQL から完全削除 | 退会対応、誤作成アカウント削除 | `TARGET_EMAIL` または `TARGET_USER_ID`, `--confirm-delete` | `TARGET_EMAIL='user@example.com' bash scripts/delete-user.sh --dry-run` |
| [`scripts/lib-lobehub-db.sh`](./scripts/lib-lobehub-db.sh) | DB 系スクリプト共通関数 | 直接実行しない | なし | なし |

### スクリプトの補助生成物

| ファイル | 役割 |
| --- | --- |
| [`scripts/out.jsonl`](./scripts/out.jsonl) | `export-master-model-settings.sh` の出力例 |
| `scripts/generated-model-provider.env` | `out.jsonl` から整理して配置する ENV 候補ファイル |

### スクリプト利用時の注意

- 多くのスクリプトは `.env` を読み込み、`docker compose exec` で PostgreSQL へ接続します
- `copy-master-model-settings.sh` と `apply-generated-model-settings.sh` は、対象ユーザー側の provider / model 設定を上書きします
- `delete-user.sh` はまず `--dry-run` で確認する前提です
- `restore-user-data.sh` は対象ユーザーが LobeHub 上に既に存在している必要があります

## 運用シナリオ別の使い方

### 新規ユーザーを追加したあとに model 設定を配る

1. Casdoor でユーザーを作成する
2. 対象ユーザーに一度ログインしてもらう
3. master 設定をコピーする

```bash
SOURCE_EMAIL='0_0@kuwa.dev' HOURS_BACK=6 bash scripts/copy-master-model-settings.sh
```

必要に応じて OpenAI 系 `key_vaults` まで合わせるなら:

```bash
SOURCE_EMAIL='0_0@kuwa.dev' HOURS_BACK=6 bash scripts/apply-generated-model-settings.sh
```

### master ユーザーの設定を棚卸しする

```bash
SOURCE_EMAIL='0_0@kuwa.dev' bash scripts/export-master-model-settings.sh > scripts/out.jsonl
```

### ユーザーをバックアップして復元する

バックアップ:

```bash
SOURCE_EMAIL='user@example.com' OUTPUT_FILE=./scripts/user-backup.json bash scripts/backup-user-data.sh
```

復元:

```bash
TARGET_EMAIL='user@example.com' BACKUP_FILE=./scripts/user-backup.json bash scripts/restore-user-data.sh
```

### ユーザーを完全削除する

まず dry-run:

```bash
TARGET_EMAIL='user@example.com' bash scripts/delete-user.sh --dry-run
```

問題なければ本実行:

```bash
TARGET_EMAIL='user@example.com' bash scripts/delete-user.sh --no-dry-run --confirm-delete
```

## 主要ファイルとディレクトリ

| パス | 内容 |
| --- | --- |
| [`docker-compose.yml`](./docker-compose.yml) | 実運用用 Compose 定義 |
| [`.env.example`](./.env.example) | 環境変数テンプレート |
| [`.env`](./.env) | 実運用用環境変数 |
| [`setup.sh`](./setup.sh) | 現在の merged 構成向けセットアップ |
| [`original-setup.sh`](./original-setup.sh) | 元の deploy 系セットアップ |
| [`casdoor/init_data.json.exmaple`](./casdoor/init_data.json.exmaple) | Casdoor 初期データテンプレート |
| [`casdoor/init_data.json`](./casdoor/init_data.json) | Casdoor に読み込ませる初期データ |
| [`bucket.config.json`](./bucket.config.json) | RustFS バケット公開設定 |
| [`searxng/settings.yml`](./searxng/settings.yml) | SearXNG 設定 |
| [`grafana/`](./grafana) | Grafana datasource / dashboard / data |
| [`prometheus/`](./prometheus) | Prometheus 設定 / data |
| [`tempo/`](./tempo) | Tempo 設定 / data |
| [`otel-collector/`](./otel-collector) | OTel Collector 設定 |
| [`postgresql/data`](./postgresql/data) | PostgreSQL データ |
| [`redis/data`](./redis/data) | Redis データ |
| [`rustfs/data`](./rustfs/data) | RustFS データ |
| [`rustfs/logs`](./rustfs/logs) | RustFS ログ |
| [`scripts/`](./scripts/) | 運用補助スクリプト群 |

## 主要な環境変数

全部を読む必要はありません。まずは次の項目を押さえると運用しやすいです。

| キー | 用途 | 補足 |
| --- | --- | --- |
| `APP_URL` | LobeHub の公開 URL | ブラウザから到達する URL |
| `INTERNAL_APP_URL` | コンテナ内部通信用 URL | Compose 構成で重要 |
| `AUTH_SSO_PROVIDERS` | SSO プロバイダー指定 | 現在は `casdoor` 前提 |
| `AUTH_DISABLE_EMAIL_PASSWORD` | LobeHub 直登録の無効化 | `1` で無効 |
| `AUTH_CASDOOR_ISSUER` | Casdoor issuer URL | OIDC の要 |
| `AUTH_CASDOOR_ID` | Casdoor client id | `setup.sh` がテンプレートから補完 |
| `AUTH_CASDOOR_SECRET` | Casdoor client secret | 同上 |
| `S3_ENDPOINT` | RustFS API 接続先 | LobeHub の保存先 |
| `RUSTFS_ACCESS_KEY` | RustFS アクセスキー | 通常は `admin` |
| `RUSTFS_SECRET_KEY` | RustFS シークレット | 初回で必ず見直す |
| `COMPOSE_PROFILES` | Compose profile 切り替え | `with-searxng` で内蔵 SearXNG |
| `SEARXNG_URL` | 検索バックエンド URL | 内蔵 / 外部どちらでも使用 |
| `GF_SECURITY_ADMIN_PASSWORD` | Grafana 管理者パスワード | 初期値のまま運用しない |
| `CLOUDFLARE_TUNNEL_TOKEN` | Cloudflared 起動用トークン | Tunnel を使う場合だけ必要 |

モデル / provider 系の補足:

- サーバー全体で共有したい値は `.env` に置きます
- ユーザー単位の provider / model / keyVaults は DB に保存されます
- custom provider は `.env` だけでは完全再現しづらく、DB / UI / SQL ベースの運用が向いています

## 認証とユーザー運用

### 基本方針

この構成では、LobeHub 側で新規登録しません。

- LobeHub の signup は無効
- Casdoor を ID Provider として利用
- ユーザー追加は Casdoor 側で実施

### 新しいユーザーを使えるようにする流れ

1. Casdoor 管理画面でユーザーを作成する
2. そのユーザーに LobeHub へログインしてもらう
3. 必要なら `copy-master-model-settings.sh` などでモデル設定を反映する

### Casdoor 初期データについて

[`casdoor/init_data.json.exmaple`](./casdoor/init_data.json.exmaple) には初期設定のテンプレートが含まれています。  
[`setup.sh`](./setup.sh) はこれを元に [`casdoor/init_data.json`](./casdoor/init_data.json) を生成します。

注意:

- seed 情報は本番投入前に必ず見直してください
- 既に `postgresql/data` が存在する場合、`init_data.json` の変更は Casdoor DB へ自動反映されません

## 監視構成

### 役割分担

| コンポーネント | 役割 |
| --- | --- |
| `network-service` | 共有 network namespace とポート公開の集約 |
| `otel-collector` | LobeHub からの OTLP 受け口 |
| `tempo` | trace 保存 |
| `prometheus` | metrics 保存 |
| `grafana` | metrics / trace 可視化 |

### 監視の見え方

- Grafana には Prometheus / Tempo datasource が登録済みです
- 初期状態ではダッシュボードは最小限なので、まずは Explore を使う前提です
- `otel-tracing-test` profile を使えば trace の導通テストもできます

## 永続化とデータ保存先

### 保存先一覧

| サービス | 保存先 |
| --- | --- |
| PostgreSQL | [`postgresql/data`](./postgresql/data) |
| Redis | [`redis/data`](./redis/data) |
| RustFS データ | [`rustfs/data`](./rustfs/data) |
| RustFS ログ | [`rustfs/logs`](./rustfs/logs) |
| Grafana | [`grafana/data`](./grafana/data) |
| Tempo | [`tempo/data`](./tempo/data) |
| Prometheus | [`prometheus/data`](./prometheus/data) |

### 権限注意

Ubuntu で RustFS を bind mount する場合、所有者を `10001:10001` にしないと `Permission denied` になることがあります。

```bash
sudo mkdir -p rustfs/data rustfs/logs
sudo chown -R 10001:10001 rustfs
sudo chmod -R 755 rustfs
```

補足:

- Grafana / Prometheus / Tempo は compose 側で `user: "0"` を指定し、権限エラーを避けています

## リセット方針

### すべて初期化したい場合

次のディレクトリを削除すれば、それぞれのサービスは初期化されます。

- `postgresql/data`
- `redis/data`
- `rustfs/data`
- `rustfs/logs`
- `grafana/data`
- `tempo/data`
- `prometheus/data`

### Casdoor を残して LobeHub だけ初期化したい場合

注意点:

- Casdoor も PostgreSQL を使っています
- そのため `postgresql/data` を丸ごと消すと Casdoor も消えます

つまり:

- 全消しするなら `postgresql/data` ごと消す
- Casdoor を残したいなら PostgreSQL 全削除はしない
- LobeHub だけ消したいなら `lobechat` DB 単位での初期化が必要です

## 既知の注意点

- `.env` や `scripts/generated-model-provider.env` に実キーを書く場合は取り扱いに注意してください
- seed 情報や初期シークレットは、本番運用前に必ず変更してください
- custom provider は `.env` だけで完全再現しづらいため、DB / UI / SQL ベース運用の方が向いています
- RustFS API は現在 `9000` 前提の箇所があります
- Cloudflared は `CLOUDFLARE_TUNNEL_TOKEN` を設定したあとに個別起動する前提です

## 最後に見るチェックリスト

本番前に少なくとも次は確認してください。

- Casdoor の seed ユーザーや初期パスワードを変更した
- `.env` のシークレット類を安全な値へ置き換えた
- `APP_URL` / `AUTH_CASDOOR_ISSUER` / `S3_ENDPOINT` が実際の公開構成と一致している
- SearXNG を内蔵で使うか外部で使うか決めた
- 必要なら Grafana の初期ダッシュボードを追加した
