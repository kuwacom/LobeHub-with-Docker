#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-lobehub-db.sh
source "${SCRIPT_DIR}/lib-lobehub-db.sh"

usage() {
  cat <<'EOF'
Usage:
  TARGET_EMAIL='user@example.com' BACKUP_FILE=./scripts/user-backup.json bash scripts/restore-user-data.sh
  TARGET_USER_ID='user_xxx' BACKUP_FILE=./scripts/user-backup.json bash scripts/restore-user-data.sh

Environment variables:
  TARGET_EMAIL       Restore target user email
  TARGET_USER_ID     Restore target user id
  USER_EMAIL         Alias of TARGET_EMAIL
  USER_ID            Alias of TARGET_USER_ID
  BACKUP_FILE        Path to backup JSON created by backup-user-data.sh
  POSTGRES_SERVICE   Docker Compose PostgreSQL service name. Default: postgresql
  POSTGRES_DB        PostgreSQL database name. Default: LOBE_DB_NAME or lobechat
  POSTGRES_USER      PostgreSQL user. Default: postgres
  POSTGRES_PASSWORD_VALUE
                    PostgreSQL password. Default: POSTGRES_PASSWORD from .env

Notes:
  - The target user must already exist in LobeHub.
  - This restore replaces the target user's managed tables with the backup contents.
  - Auth tables, RustFS object data, files/knowledge-base blobs, and server-side sessions are not restored.
EOF
}

emit_delete_sql() {
  local table_name="$1"
  local where_clause="$2"

  cat <<SQL
DO \$\$
BEGIN
  IF to_regclass('public.${table_name}') IS NOT NULL THEN
    DELETE FROM ${table_name} WHERE ${where_clause};
  END IF;
END
\$\$;
SQL
}

emit_restore_sql() {
  local table_name="$1"
  local transform_sql="$2"

  cat <<SQL
DO \$\$
BEGIN
  IF to_regclass('public.${table_name}') IS NOT NULL THEN
    INSERT INTO ${table_name}
    SELECT *
    FROM jsonb_populate_recordset(
      NULL::public.${table_name},
      (
        SELECT COALESCE(jsonb_agg(${transform_sql}), '[]'::jsonb)
        FROM backup_payload bp
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(bp.doc->'tables'->'${table_name}', '[]'::jsonb)) AS item(row_json)
      )
    );
  END IF;
END
\$\$;
SQL
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 0 ]]; then
  echo "This script uses environment variables instead of positional arguments." >&2
  usage >&2
  exit 1
fi

load_lobehub_env
init_lobehub_postgres

TARGET_EMAIL="${TARGET_EMAIL:-${USER_EMAIL:-}}"
TARGET_USER_ID="${TARGET_USER_ID:-${USER_ID:-}}"
BACKUP_FILE="${BACKUP_FILE:-}"

validate_email_or_empty "${TARGET_EMAIL}"

if [[ -z "${BACKUP_FILE}" ]]; then
  echo "Set BACKUP_FILE." >&2
  usage >&2
  exit 1
fi

if [[ ! -f "${BACKUP_FILE}" ]]; then
  echo "Backup file not found: ${BACKUP_FILE}" >&2
  exit 1
fi

if [[ -z "${TARGET_EMAIL}" && -z "${TARGET_USER_ID}" ]]; then
  echo "Set TARGET_EMAIL or TARGET_USER_ID." >&2
  usage >&2
  exit 1
fi

TARGET_USER_ID_RESOLVED="$(resolve_user_id "${TARGET_USER_ID}" "${TARGET_EMAIL}")"
if [[ -z "${TARGET_USER_ID_RESOLVED}" ]]; then
  if [[ -n "${TARGET_USER_ID}" ]]; then
    echo "Target user not found: ${TARGET_USER_ID}" >&2
  else
    echo "Target user not found: ${TARGET_EMAIL}" >&2
  fi
  exit 1
fi

TARGET_EMAIL_RESOLVED="$(resolve_user_email "${TARGET_USER_ID_RESOLVED}")"
TARGET_USER_ID_SQL="$(sql_escape_literal "${TARGET_USER_ID_RESOLVED}")"
CONTAINER_BACKUP_FILE="/tmp/lobehub-user-restore-$$.json"
CONTAINER_BACKUP_FILE_SQL="$(sql_escape_literal "${CONTAINER_BACKUP_FILE}")"

cleanup_container_backup() {
  docker compose -f "${LOBE_ROOT_DIR}/docker-compose.yml" exec -T "${POSTGRES_SERVICE}" \
    sh -lc "rm -f '${CONTAINER_BACKUP_FILE}'" >/dev/null 2>&1 || true
}

trap cleanup_container_backup EXIT

printf 'Uploading backup file to PostgreSQL container...\n' >&2
docker compose -f "${LOBE_ROOT_DIR}/docker-compose.yml" exec -T "${POSTGRES_SERVICE}" \
  sh -lc "cat > '${CONTAINER_BACKUP_FILE}'" < "${BACKUP_FILE}"

BACKUP_APP="$(psql_scalar "SELECT COALESCE(pg_read_file('${CONTAINER_BACKUP_FILE_SQL}')::jsonb->>'app', '');")"
BACKUP_FORMAT_VERSION="$(psql_scalar "SELECT COALESCE(pg_read_file('${CONTAINER_BACKUP_FILE_SQL}')::jsonb->>'format_version', '');")"
BACKUP_SOURCE_USER_ID="$(psql_scalar "SELECT COALESCE(pg_read_file('${CONTAINER_BACKUP_FILE_SQL}')::jsonb->'source_user'->>'id', '');")"
BACKUP_SOURCE_EMAIL="$(psql_scalar "SELECT COALESCE(pg_read_file('${CONTAINER_BACKUP_FILE_SQL}')::jsonb->'source_user'->>'email', '');")"

if [[ "${BACKUP_APP}" != "lobehub-user-backup" ]]; then
  echo "Unsupported backup file app marker: ${BACKUP_APP:-<empty>}" >&2
  exit 1
fi

if [[ "${BACKUP_FORMAT_VERSION}" != "1" ]]; then
  echo "Unsupported backup file format_version: ${BACKUP_FORMAT_VERSION:-<empty>}" >&2
  exit 1
fi

printf 'Restoring core user data from backup source id=%s email=%s to target id=%s email=%s...\n' \
  "${BACKUP_SOURCE_USER_ID:-<empty>}" \
  "${BACKUP_SOURCE_EMAIL:-<empty>}" \
  "${TARGET_USER_ID_RESOLVED}" \
  "${TARGET_EMAIL_RESOLVED:-<empty>}" >&2

{
  cat <<SQL
BEGIN;

CREATE TEMP TABLE backup_payload AS
SELECT pg_read_file('${CONTAINER_BACKUP_FILE_SQL}')::jsonb AS doc;

SQL

  emit_delete_sql "messages" "user_id = '${TARGET_USER_ID_SQL}'"
  emit_delete_sql "threads" "user_id = '${TARGET_USER_ID_SQL}'"
  emit_delete_sql "topics" "user_id = '${TARGET_USER_ID_SQL}'"
  emit_delete_sql "sessions" "user_id = '${TARGET_USER_ID_SQL}'"
  emit_delete_sql "agents" "user_id = '${TARGET_USER_ID_SQL}'"
  emit_delete_sql "session_groups" "user_id = '${TARGET_USER_ID_SQL}'"
  emit_delete_sql "ai_models" "user_id = '${TARGET_USER_ID_SQL}'"
  emit_delete_sql "ai_providers" "user_id = '${TARGET_USER_ID_SQL}'"
  emit_delete_sql "user_installed_plugins" "user_id = '${TARGET_USER_ID_SQL}'"
  emit_delete_sql "user_settings" "id = '${TARGET_USER_ID_SQL}'"

  emit_restore_sql "user_settings" "jsonb_set(row_json, '{id}', to_jsonb('${TARGET_USER_ID_SQL}'::text), true)"
  emit_restore_sql "user_installed_plugins" "jsonb_set(row_json, '{user_id}', to_jsonb('${TARGET_USER_ID_SQL}'::text), true)"
  emit_restore_sql "ai_providers" "jsonb_set(row_json, '{user_id}', to_jsonb('${TARGET_USER_ID_SQL}'::text), true)"
  emit_restore_sql "ai_models" "jsonb_set(row_json, '{user_id}', to_jsonb('${TARGET_USER_ID_SQL}'::text), true)"
  emit_restore_sql "session_groups" "jsonb_set(row_json, '{user_id}', to_jsonb('${TARGET_USER_ID_SQL}'::text), true)"
  emit_restore_sql "agents" "jsonb_set(row_json, '{user_id}', to_jsonb('${TARGET_USER_ID_SQL}'::text), true)"
  emit_restore_sql "sessions" "jsonb_set(row_json, '{user_id}', to_jsonb('${TARGET_USER_ID_SQL}'::text), true)"
  emit_restore_sql "topics" "jsonb_set(jsonb_set(row_json, '{user_id}', to_jsonb('${TARGET_USER_ID_SQL}'::text), true), '{group_id}', 'null'::jsonb, true)"
  emit_restore_sql "threads" "jsonb_set(jsonb_set(row_json, '{user_id}', to_jsonb('${TARGET_USER_ID_SQL}'::text), true), '{group_id}', 'null'::jsonb, true)"
  emit_restore_sql "messages" "jsonb_set(jsonb_set(jsonb_set(row_json, '{user_id}', to_jsonb('${TARGET_USER_ID_SQL}'::text), true), '{group_id}', 'null'::jsonb, true), '{message_group_id}', 'null'::jsonb, true)"
  emit_restore_sql "message_plugins" "jsonb_set(row_json, '{user_id}', to_jsonb('${TARGET_USER_ID_SQL}'::text), true)"
  emit_restore_sql "message_translates" "jsonb_set(row_json, '{user_id}', to_jsonb('${TARGET_USER_ID_SQL}'::text), true)"
  emit_restore_sql "agents_to_sessions" "jsonb_set(row_json, '{user_id}', to_jsonb('${TARGET_USER_ID_SQL}'::text), true)"

  cat <<'SQL'
COMMIT;
SQL
} | psql_run

printf 'Completed.\n' >&2