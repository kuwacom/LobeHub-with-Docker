#!/usr/bin/env bash
set -euo pipefail

# master ユーザーの設定を最近作成されたユーザーへ複製する
# さらに generated env から OpenAI keyVaults を再暗号化して反映する
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_ENV_FILE="${ROOT_DIR}/.env"
GENERATED_ENV_FILE="${GENERATED_ENV_FILE:-${ROOT_DIR}/scripts/generated-model-provider.env}"

if [[ ! -f "${BASE_ENV_FILE}" ]]; then
  echo "Missing .env file: ${BASE_ENV_FILE}" >&2
  exit 1
fi

# docker compose と psql に渡すため .env を現在の shell に読み込む
set -a
# shellcheck disable=SC1090
source "${BASE_ENV_FILE}"
set +a

# 実行時に上書きできる環境変数
# GENERATED_ENV_FILE は OpenAI 候補値を読む env ファイルのパス
# SOURCE_EMAIL はコピー元にする master ユーザーのメールアドレス
# HOURS_BACK は何時間前までに作成されたユーザーを対象にするかを表す
# POSTGRES_SERVICE は docker compose 上の PostgreSQL サービス名
# POSTGRES_DB は接続先データベース名で未指定時は LOBE_DB_NAME を使う
# POSTGRES_USER は PostgreSQL の接続ユーザー名
# POSTGRES_PASSWORD_VALUE は PostgreSQL の接続パスワードで未指定時は POSTGRES_PASSWORD を使う
# LOBE_SERVICE は key_vaults 暗号化に使う LobeHub コンテナ名
# OPENAI_API_KEY と OPENAI_PROXY_URL を明示すると generated env より優先して使う
# 実行時に未指定でも動くよう既定値を定める
SOURCE_EMAIL="${SOURCE_EMAIL:-0_0@kuwa.dev}"
HOURS_BACK="${HOURS_BACK:-6}"
POSTGRES_SERVICE="${POSTGRES_SERVICE:-postgresql}"
POSTGRES_DB="${LOBE_DB_NAME:-lobechat}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD_VALUE="${POSTGRES_PASSWORD:-}"
LOBE_SERVICE="${LOBE_SERVICE:-lobe}"

# 危険な誤入力を避けるため先に値を検証する
if [[ -z "${POSTGRES_PASSWORD_VALUE}" ]]; then
  echo "POSTGRES_PASSWORD is not set in ${BASE_ENV_FILE}" >&2
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

# generated env 全体を source せず 必要なキーだけ末尾優先で読む
read_env_value() {
  local key="$1"
  local file="$2"

  [[ -f "$file" ]] || return 0

  local line
  line="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -n 1 || true)"
  if [[ -z "$line" ]]; then
    return 0
  fi

  line="${line#*=}"
  printf '%s' "$line"
}

# 明示指定がなければ generated env の候補値を利用する
OPENAI_API_KEY="${OPENAI_API_KEY:-$(read_env_value 'OPENAI_API_KEY' "${GENERATED_ENV_FILE}")}" 
OPENAI_PROXY_URL="${OPENAI_PROXY_URL:-$(read_env_value 'OPENAI_PROXY_URL' "${GENERATED_ENV_FILE}")}" 

# OpenAI の API キーや proxy URL を LobeHub の key_vaults 形式へ再暗号化する
encrypt_openai_keyvaults() {
  if [[ -z "${OPENAI_API_KEY:-}" && -z "${OPENAI_PROXY_URL:-}" ]]; then
    return 0
  fi

  docker compose -f "${ROOT_DIR}/docker-compose.yml" exec -T \
    -e "KEY_VAULTS_SECRET=${KEY_VAULTS_SECRET:-}" \
    -e "OPENAI_API_KEY=${OPENAI_API_KEY:-}" \
    -e "OPENAI_PROXY_URL=${OPENAI_PROXY_URL:-}" \
    "${LOBE_SERVICE}" \
    node - <<'NODE'
const { webcrypto } = require('crypto');
const crypto = webcrypto;

async function main() {
  const secret = process.env.KEY_VAULTS_SECRET || '';
  if (!secret) {
    console.error('KEY_VAULTS_SECRET is not set');
    process.exit(1);
  }

  const payload = {};
  if (process.env.OPENAI_API_KEY) payload.apiKey = process.env.OPENAI_API_KEY;
  if (process.env.OPENAI_PROXY_URL) payload.baseURL = process.env.OPENAI_PROXY_URL;

  if (Object.keys(payload).length === 0) {
    process.stdout.write('');
    return;
  }

  const rawKey = Buffer.from(secret, 'base64');
  if (![16, 24, 32].includes(rawKey.length)) {
    console.error('Invalid KEY_VAULTS_SECRET length');
    process.exit(1);
  }

  const aesKey = await crypto.subtle.importKey(
    'raw',
    rawKey,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt'],
  );

  const iv = crypto.getRandomValues(new Uint8Array(12));
  const plaintext = new TextEncoder().encode(JSON.stringify(payload));
  const encryptedData = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, aesKey, plaintext);
  const buffer = Buffer.from(encryptedData);
  const authTag = buffer.slice(-16);
  const encrypted = buffer.slice(0, -16);

  process.stdout.write(`${Buffer.from(iv).toString('hex')}:${authTag.toString('hex')}:${encrypted.toString('hex')}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
}

SOURCE_EMAIL_SQL="$(sql_escape_literal "${SOURCE_EMAIL}")"
OPENAI_KEYVAULTS_ENCRYPTED="$(encrypt_openai_keyvaults || true)"
OPENAI_KEYVAULTS_SQL="$(sql_escape_literal "${OPENAI_KEYVAULTS_ENCRYPTED}")"

printf 'Applying model settings from %s to accounts created within the last %s hour(s)...\n' "${SOURCE_EMAIL}" "${HOURS_BACK}"

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

if [[ -n "${OPENAI_KEYVAULTS_ENCRYPTED}" ]]; then
  echo "OpenAI keyVaults from generated env will be applied to target users."
else
  echo "OpenAI keyVaults from generated env are empty. Source DB values will be kept as-is."
fi

# generated env に値がある時だけ openai provider の上書き SQL を差し込む
OPENAI_SQL=''
if [[ -n "${OPENAI_KEYVAULTS_ENCRYPTED}" ]]; then
  OPENAI_SQL=$(cat <<SQLBLOCK
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
  user_id,
  enabled,
  source,
  key_vaults
)
SELECT
  'openai',
  tu.id,
  true,
  'builtin',
  '${OPENAI_KEYVAULTS_SQL}'
FROM target_users tu
ON CONFLICT (id, user_id) DO UPDATE
SET
  enabled = EXCLUDED.enabled,
  key_vaults = EXCLUDED.key_vaults,
  updated_at = NOW();
SQLBLOCK
)
fi

# source user の設定を複製し 必要なら OpenAI keyVaults だけ追加で上書きする
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
    us.default_agent,
    us.system_agent
  FROM user_settings us
  JOIN source_user s ON us.id = s.id
)
-- user_settings は upsert で source user の値へ合わせる
INSERT INTO user_settings (id, key_vaults, language_model, default_agent, system_agent)
SELECT
  tu.id,
  ss.key_vaults,
  ss.language_model,
  ss.default_agent,
  ss.system_agent
FROM target_users tu
CROSS JOIN source_settings ss
ON CONFLICT (id) DO UPDATE
SET
  key_vaults = EXCLUDED.key_vaults,
  language_model = EXCLUDED.language_model,
  default_agent = EXCLUDED.default_agent,
  system_agent = EXCLUDED.system_agent;

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

${OPENAI_SQL}

COMMIT;

\echo Done.
SQL

echo "Completed."

