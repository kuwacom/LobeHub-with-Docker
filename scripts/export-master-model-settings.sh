#!/usr/bin/env bash
set -euo pipefail

# master ユーザーの model/provider 設定を確認用にエクスポートする
# Docker Compose 経由で PostgreSQL コンテナ内の psql を利用する
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
# SOURCE_EMAIL は設定を読み出す master ユーザーのメールアドレス
# POSTGRES_SERVICE は docker compose 上の PostgreSQL サービス名
# POSTGRES_DB は接続先データベース名で未指定時は LOBE_DB_NAME を使う
# POSTGRES_USER は PostgreSQL の接続ユーザー名
# POSTGRES_PASSWORD_VALUE は PostgreSQL の接続パスワードで未指定時は POSTGRES_PASSWORD を使う
# 未指定時は運用で使っている標準値を採用する
SOURCE_EMAIL="${SOURCE_EMAIL:-0_0@kuwa.dev}"
POSTGRES_SERVICE="${POSTGRES_SERVICE:-postgresql}"
POSTGRES_DB="${LOBE_DB_NAME:-lobechat}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD_VALUE="${POSTGRES_PASSWORD:-}"

# SQL 実行前に必須値と入力形式を検証する
if [[ -z "${POSTGRES_PASSWORD_VALUE}" ]]; then
  echo "POSTGRES_PASSWORD is not set in ${ENV_FILE}" >&2
  exit 1
fi

if [[ ! "${SOURCE_EMAIL}" =~ ^[^[:space:]']+@[^[:space:]']+$ ]]; then
  echo "Invalid SOURCE_EMAIL: ${SOURCE_EMAIL}" >&2
  exit 1
fi

# SQL の文字列リテラルへ埋め込めるよう単引用符をエスケープする
sql_escape_literal() {
  printf '%s' "$1" | sed "s/'/''/g"
}

SOURCE_EMAIL_SQL="$(sql_escape_literal "${SOURCE_EMAIL}")"

printf 'Exporting enabled model settings for %s...\n' "${SOURCE_EMAIL}"

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

# 転記元ユーザーが存在するかを先に確認する
SOURCE_USER_ID="$(${PSQL_BASE[@]} -At -c "SELECT id FROM users WHERE email = '${SOURCE_EMAIL_SQL}' LIMIT 1;")"

if [[ -z "${SOURCE_USER_ID}" ]]; then
  echo "Source user not found: ${SOURCE_EMAIL}" >&2
  exit 1
fi

echo "Source user id: ${SOURCE_USER_ID}"

# 監査用の詳細情報と .env 化しやすい候補をセクション分けして出力する
"${PSQL_BASE[@]}" <<SQL
\pset pager off
\pset tuples_only on

\echo === USER ===
WITH source_user AS (
  SELECT id, email, username, created_at, updated_at
  FROM users
  WHERE email = '${SOURCE_EMAIL_SQL}'
  LIMIT 1
)
SELECT jsonb_pretty(to_jsonb(source_user))
FROM source_user;

\echo
\echo === USER_SETTINGS ===
WITH source_user AS (
  SELECT id
  FROM users
  WHERE email = '${SOURCE_EMAIL_SQL}'
  LIMIT 1
)
SELECT jsonb_pretty(
  jsonb_build_object(
    'default_agent', us.default_agent,
    'general', us.general,
    'key_vaults_encrypted', us.key_vaults,
    'language_model', us.language_model,
    'system_agent', us.system_agent
  )
)
FROM user_settings us
JOIN source_user s ON us.id = s.id;

\echo
\echo === ENABLED_AI_PROVIDERS ===
WITH source_user AS (
  SELECT id
  FROM users
  WHERE email = '${SOURCE_EMAIL_SQL}'
  LIMIT 1
), provider_rows AS (
  SELECT
    ap.id,
    ap.name,
    ap.source,
    ap.enabled,
    ap.sort,
    ap.fetch_on_client,
    ap.check_model,
    ap.logo,
    ap.description,
    ap.key_vaults AS key_vaults_encrypted,
    ap.settings,
    ap.config,
    ap.created_at,
    ap.updated_at
  FROM ai_providers ap
  JOIN source_user s ON ap.user_id = s.id
  WHERE COALESCE(ap.enabled, false) = true
  ORDER BY ap.sort NULLS LAST, ap.updated_at DESC, ap.id ASC
)
SELECT COALESCE(jsonb_pretty(jsonb_agg(to_jsonb(provider_rows))), '[]')
FROM provider_rows;

\echo
\echo === ENABLED_AI_MODELS ===
WITH source_user AS (
  SELECT id
  FROM users
  WHERE email = '${SOURCE_EMAIL_SQL}'
  LIMIT 1
), model_rows AS (
  SELECT
    am.id,
    am.display_name,
    am.description,
    am.organization,
    am.enabled,
    am.provider_id,
    am.type,
    am.sort,
    am.pricing,
    am.parameters,
    am.config,
    am.abilities,
    am.context_window_tokens,
    am.source,
    am.released_at,
    am.settings,
    am.created_at,
    am.updated_at
  FROM ai_models am
  JOIN source_user s ON am.user_id = s.id
  WHERE COALESCE(am.enabled, false) = true
  ORDER BY am.provider_id ASC, am.sort NULLS LAST, am.id ASC
)
SELECT COALESCE(jsonb_pretty(jsonb_agg(to_jsonb(model_rows))), '[]')
FROM model_rows;

\echo
\echo === ENV_CANDIDATES ===
\echo # Enabled built-in provider candidates only. Custom providers need manual migration.

-- builtin provider だけは ENV へ寄せやすいので候補を列挙する
WITH source_user AS (
  SELECT id
  FROM users
  WHERE email = '${SOURCE_EMAIL_SQL}'
  LIMIT 1
)
SELECT format(
  'ENABLED_%s=1',
  upper(regexp_replace(ap.id, '[^a-zA-Z0-9]+', '_', 'g'))
)
FROM ai_providers ap
JOIN source_user s ON ap.user_id = s.id
WHERE ap.source = 'builtin'
  AND COALESCE(ap.enabled, false) = true
ORDER BY ap.sort NULLS LAST, ap.updated_at DESC, ap.id ASC;

\echo
WITH source_user AS (
  SELECT id
  FROM users
  WHERE email = '${SOURCE_EMAIL_SQL}'
  LIMIT 1
), model_tokens AS (
  SELECT
    am.provider_id,
    am.sort,
    am.id,
    format(
      '%s%s%s',
      '+',
      am.id,
      CASE
        WHEN am.display_name IS NOT NULL AND am.display_name <> am.id
          THEN '=' || am.display_name
        ELSE ''
      END ||
      CASE
        WHEN concat_ws(
          ':',
          NULLIF(am.context_window_tokens::text, ''),
          CASE WHEN COALESCE((am.abilities ->> 'reasoning')::boolean, false) THEN 'reasoning' END,
          CASE WHEN COALESCE((am.abilities ->> 'vision')::boolean, false) THEN 'vision' END,
          CASE WHEN COALESCE((am.abilities ->> 'functionCall')::boolean, false) THEN 'fc' END,
          CASE WHEN COALESCE((am.abilities ->> 'files')::boolean, false) THEN 'file' END,
          CASE WHEN COALESCE((am.abilities ->> 'video')::boolean, false) THEN 'video' END,
          CASE WHEN COALESCE((am.abilities ->> 'search')::boolean, false) THEN 'search' END,
          CASE WHEN COALESCE((am.abilities ->> 'imageOutput')::boolean, false) THEN 'imageOutput' END
        ) <> ''
          THEN '<' || concat_ws(
            ':',
            NULLIF(am.context_window_tokens::text, ''),
            CASE WHEN COALESCE((am.abilities ->> 'reasoning')::boolean, false) THEN 'reasoning' END,
            CASE WHEN COALESCE((am.abilities ->> 'vision')::boolean, false) THEN 'vision' END,
            CASE WHEN COALESCE((am.abilities ->> 'functionCall')::boolean, false) THEN 'fc' END,
            CASE WHEN COALESCE((am.abilities ->> 'files')::boolean, false) THEN 'file' END,
            CASE WHEN COALESCE((am.abilities ->> 'video')::boolean, false) THEN 'video' END,
            CASE WHEN COALESCE((am.abilities ->> 'search')::boolean, false) THEN 'search' END,
            CASE WHEN COALESCE((am.abilities ->> 'imageOutput')::boolean, false) THEN 'imageOutput' END
          ) || '>'
        ELSE ''
      END
    ) AS token
  FROM ai_models am
  JOIN source_user s ON am.user_id = s.id
  WHERE COALESCE(am.enabled, false) = true
), grouped AS (
  SELECT
    provider_id,
    string_agg(token, ',' ORDER BY sort NULLS LAST, id ASC) AS enabled_model_list
  FROM model_tokens
  GROUP BY provider_id
)
SELECT format(
  '%s_MODEL_LIST=-all,%s',
  upper(regexp_replace(provider_id, '[^a-zA-Z0-9]+', '_', 'g')),
  enabled_model_list
)
FROM grouped
ORDER BY provider_id;

\echo
\echo === ENABLED_CUSTOM_PROVIDER_HINTS ===
-- custom provider は ENV だけで再現しづらいためヒントだけを残す
WITH source_user AS (
  SELECT id
  FROM users
  WHERE email = '${SOURCE_EMAIL_SQL}'
  LIMIT 1
)
SELECT format(
  '# provider=%s source=%s enabled=%s settings=%s config=%s key_vaults_encrypted=%s',
  ap.id,
  ap.source,
  COALESCE(ap.enabled, false),
  COALESCE(ap.settings::text, '{}'),
  COALESCE(ap.config::text, '{}'),
  COALESCE(ap.key_vaults, '')
)
FROM ai_providers ap
JOIN source_user s ON ap.user_id = s.id
WHERE ap.source <> 'builtin'
  AND COALESCE(ap.enabled, false) = true
ORDER BY ap.sort NULLS LAST, ap.updated_at DESC, ap.id ASC;
SQL

echo "Completed."

