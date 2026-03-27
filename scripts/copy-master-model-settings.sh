#!/usr/bin/env bash
set -euo pipefail

# master ユーザーの設定を最近作成されたユーザーへ複製する
# target user 側の provider/model は一度削除してから入れ直す
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing .env file: ${ENV_FILE}" >&2
  exit 1
fi

# docker compose と psql に渡すため .env を現在の shell に読み込む
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

# 実行時に上書きできる環境変数
# SOURCE_EMAIL はコピー元にする master ユーザーのメールアドレス
# HOURS_BACK は何時間前までに作成されたユーザーを対象にするかを表す
# POSTGRES_SERVICE は docker compose 上の PostgreSQL サービス名
# POSTGRES_DB は接続先データベース名で未指定時は LOBE_DB_NAME を使う
# POSTGRES_USER は PostgreSQL の接続ユーザー名
# POSTGRES_PASSWORD_VALUE は PostgreSQL の接続パスワードで未指定時は POSTGRES_PASSWORD を使う
# 実行時に未指定でも動くよう既定値を定める
SOURCE_EMAIL="${SOURCE_EMAIL:-0_0@kuwa.dev}"
HOURS_BACK="${HOURS_BACK:-24}"
POSTGRES_SERVICE="${POSTGRES_SERVICE:-postgresql}"
POSTGRES_DB="${LOBE_DB_NAME:-lobechat}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD_VALUE="${POSTGRES_PASSWORD:-}"

# 危険な誤入力を避けるため先に値を検証する
if [[ -z "${POSTGRES_PASSWORD_VALUE}" ]]; then
  echo "POSTGRES_PASSWORD is not set in ${ENV_FILE}" >&2
  exit 1
fi

if [[ ! "${SOURCE_EMAIL}" =~ ^[^[:space:]']+@[^[:space:]']+$ ]]; then
  echo "Invalid SOURCE_EMAIL: ${SOURCE_EMAIL}" >&2
  exit 1
fi

if [[ ! "${HOURS_BACK}" =~ ^[0-9]+$ ]]; then
  echo "HOURS_BACK must be an integer: ${HOURS_BACK}" >&2
  exit 1
fi

# SQL の文字列リテラルへ埋め込めるよう単引用符をエスケープする
sql_escape_literal() {
  printf '%s' "$1" | sed "s/'/''/g"
}

SOURCE_EMAIL_SQL="$(sql_escape_literal "${SOURCE_EMAIL}")"

echo "Copying model settings from ${SOURCE_EMAIL} to accounts created within the last ${HOURS_BACK} hour(s)..."

# 以降の問い合わせで共通利用する psql 実行オプションを配列にまとめる
PSQL_BASE=(
  docker compose
  -f "${ROOT_DIR}/docker-compose.yml"
  exec
  -T
  -e "PGPASSWORD=${POSTGRES_PASSWORD_VALUE}"
  "${POSTGRES_SERVICE}"
  psql
  -h 127.0.0.1
  -U "${POSTGRES_USER}"
  -d "${POSTGRES_DB}"
  -v ON_ERROR_STOP=1
)

# 転記元ユーザーと対象件数を先に把握して誤実行を見つけやすくする
SOURCE_USER_ID="$(${PSQL_BASE[@]} -At -c "SELECT id FROM users WHERE email = '${SOURCE_EMAIL_SQL}' LIMIT 1;")"

if [[ -z "${SOURCE_USER_ID}" ]]; then
  echo "Source user not found: ${SOURCE_EMAIL}" >&2
  exit 1
fi

TARGET_COUNT="$(${PSQL_BASE[@]} -At -c "SELECT count(*) FROM users WHERE created_at >= NOW() - (${HOURS_BACK} * INTERVAL '1 hour') AND email <> '${SOURCE_EMAIL_SQL}';")"

echo "Source user id: ${SOURCE_USER_ID}"
echo "Target users found: ${TARGET_COUNT}"

# 対象ユーザー群を毎回同じ条件で定義し 設定一式を丸ごと差し替える
"${PSQL_BASE[@]}" <<SQL
BEGIN;

WITH source_user AS (
  SELECT id
  FROM users
  WHERE email = '${SOURCE_EMAIL_SQL}'
  LIMIT 1
),
target_users AS (
  SELECT u.id
  FROM users u
  CROSS JOIN source_user s
  WHERE u.created_at >= NOW() - (${HOURS_BACK} * INTERVAL '1 hour')
    AND u.id <> s.id
),
source_settings AS (
  SELECT
    us.key_vaults,
    us.language_model,
    us.default_agent
  FROM user_settings us
  JOIN source_user s ON us.id = s.id
)
-- user_settings は upsert で source user の値へ合わせる
INSERT INTO user_settings (id, key_vaults, language_model, default_agent)
SELECT
  tu.id,
  ss.key_vaults,
  ss.language_model,
  ss.default_agent
FROM target_users tu
CROSS JOIN source_settings ss
ON CONFLICT (id) DO UPDATE
SET
  key_vaults = EXCLUDED.key_vaults,
  language_model = EXCLUDED.language_model,
  default_agent = EXCLUDED.default_agent;

WITH source_user AS (
  SELECT id
  FROM users
  WHERE email = '${SOURCE_EMAIL_SQL}'
  LIMIT 1
),
target_users AS (
  SELECT u.id
  FROM users u
  CROSS JOIN source_user s
  WHERE u.created_at >= NOW() - (${HOURS_BACK} * INTERVAL '1 hour')
    AND u.id <> s.id
)
-- 重複や取り残しを避けるため target user 側の model を先に消す
DELETE FROM ai_models am
USING target_users tu
WHERE am.user_id = tu.id;

WITH source_user AS (
  SELECT id
  FROM users
  WHERE email = '${SOURCE_EMAIL_SQL}'
  LIMIT 1
),
target_users AS (
  SELECT u.id
  FROM users u
  CROSS JOIN source_user s
  WHERE u.created_at >= NOW() - (${HOURS_BACK} * INTERVAL '1 hour')
    AND u.id <> s.id
)
-- provider も同様に一度空にして source user のスナップショットを複製する
DELETE FROM ai_providers ap
USING target_users tu
WHERE ap.user_id = tu.id;

WITH source_user AS (
  SELECT id
  FROM users
  WHERE email = '${SOURCE_EMAIL_SQL}'
  LIMIT 1
),
target_users AS (
  SELECT u.id
  FROM users u
  CROSS JOIN source_user s
  WHERE u.created_at >= NOW() - (${HOURS_BACK} * INTERVAL '1 hour')
    AND u.id <> s.id
)
INSERT INTO ai_providers (
  id,
  name,
  user_id,
  sort,
  enabled,
  fetch_on_client,
  check_model,
  logo,
  description,
  key_vaults,
  source,
  settings,
  config,
  created_at,
  updated_at
)
SELECT
  ap.id,
  ap.name,
  tu.id,
  ap.sort,
  ap.enabled,
  ap.fetch_on_client,
  ap.check_model,
  ap.logo,
  ap.description,
  ap.key_vaults,
  ap.source,
  ap.settings,
  ap.config,
  NOW(),
  NOW()
FROM ai_providers ap
JOIN source_user s ON ap.user_id = s.id
CROSS JOIN target_users tu;

WITH source_user AS (
  SELECT id
  FROM users
  WHERE email = '${SOURCE_EMAIL_SQL}'
  LIMIT 1
),
target_users AS (
  SELECT u.id
  FROM users u
  CROSS JOIN source_user s
  WHERE u.created_at >= NOW() - (${HOURS_BACK} * INTERVAL '1 hour')
    AND u.id <> s.id
)
INSERT INTO ai_models (
  id,
  display_name,
  description,
  organization,
  enabled,
  provider_id,
  type,
  sort,
  user_id,
  pricing,
  parameters,
  config,
  abilities,
  context_window_tokens,
  source,
  released_at,
  settings,
  created_at,
  updated_at
)
SELECT
  am.id,
  am.display_name,
  am.description,
  am.organization,
  am.enabled,
  am.provider_id,
  am.type,
  am.sort,
  tu.id,
  am.pricing,
  am.parameters,
  am.config,
  am.abilities,
  am.context_window_tokens,
  am.source,
  am.released_at,
  am.settings,
  NOW(),
  NOW()
FROM ai_models am
JOIN source_user s ON am.user_id = s.id
CROSS JOIN target_users tu;

COMMIT;

\echo Done.
SQL

echo "Completed."

