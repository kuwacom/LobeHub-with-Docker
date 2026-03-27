#!/usr/bin/env bash

LOBE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOBE_ROOT_DIR="$(cd "${LOBE_SCRIPT_DIR}/.." && pwd)"
LOBE_ENV_FILE="${LOBE_ROOT_DIR}/.env"

LOBE_USER_BACKUP_TABLES=(
  user_settings
  user_installed_plugins
  ai_providers
  ai_models
  session_groups
  agents
  sessions
  topics
  threads
  messages
  message_plugins
  message_translates
  agents_to_sessions
)

load_lobehub_env() {
  if [[ ! -f "${LOBE_ENV_FILE}" ]]; then
    echo "Missing .env file: ${LOBE_ENV_FILE}" >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "${LOBE_ENV_FILE}"
  set +a
}

init_lobehub_postgres() {
  POSTGRES_SERVICE="${POSTGRES_SERVICE:-postgresql}"
  POSTGRES_DB="${POSTGRES_DB:-${LOBE_DB_NAME:-lobechat}}"
  POSTGRES_USER="${POSTGRES_USER:-postgres}"
  POSTGRES_PASSWORD_VALUE="${POSTGRES_PASSWORD_VALUE:-${POSTGRES_PASSWORD:-}}"

  if [[ -z "${POSTGRES_PASSWORD_VALUE}" ]]; then
    echo "POSTGRES_PASSWORD is not set in ${LOBE_ENV_FILE}" >&2
    exit 1
  fi

  PSQL_BASE=(
    docker compose
    -f "${LOBE_ROOT_DIR}/docker-compose.yml"
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
}

sql_escape_literal() {
  printf '%s' "$1" | sed "s/'/''/g"
}

psql_scalar() {
  local sql="$1"
  "${PSQL_BASE[@]}" -At -c "${sql}"
}

psql_run() {
  "${PSQL_BASE[@]}"
}

pg_table_exists() {
  local table_name="$1"
  local table_name_sql
  table_name_sql="$(sql_escape_literal "${table_name}")"
  [[ "$(psql_scalar "SELECT to_regclass('public.${table_name_sql}') IS NOT NULL;")" == "t" ]]
}

validate_email_or_empty() {
  local email="$1"
  if [[ -z "${email}" ]]; then
    return 0
  fi

  if [[ ! "${email}" =~ ^[^[:space:]']+@[^[:space:]']+$ ]]; then
    echo "Invalid email: ${email}" >&2
    exit 1
  fi
}

resolve_user_row_json() {
  local user_id="$1"
  local email="$2"
  local sql

  if [[ -n "${user_id}" ]]; then
    local user_id_sql
    user_id_sql="$(sql_escape_literal "${user_id}")"
    sql="SELECT row_to_json(u)::text FROM users u WHERE id = '${user_id_sql}' LIMIT 1;"
  else
    local email_sql
    email_sql="$(sql_escape_literal "${email}")"
    sql="SELECT row_to_json(u)::text FROM users u WHERE email = '${email_sql}' LIMIT 1;"
  fi

  psql_scalar "${sql}"
}

resolve_user_id() {
  local user_id="$1"
  local email="$2"
  local sql

  if [[ -n "${user_id}" ]]; then
    local user_id_sql
    user_id_sql="$(sql_escape_literal "${user_id}")"
    sql="SELECT id FROM users WHERE id = '${user_id_sql}' LIMIT 1;"
  else
    local email_sql
    email_sql="$(sql_escape_literal "${email}")"
    sql="SELECT id FROM users WHERE email = '${email_sql}' LIMIT 1;"
  fi

  psql_scalar "${sql}"
}

resolve_user_email() {
  local user_id="$1"
  local user_id_sql
  user_id_sql="$(sql_escape_literal "${user_id}")"
  psql_scalar "SELECT COALESCE(email, '') FROM users WHERE id = '${user_id_sql}' LIMIT 1;"
}