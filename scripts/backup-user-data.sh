#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-lobehub-db.sh
source "${SCRIPT_DIR}/lib-lobehub-db.sh"

usage() {
  cat <<'EOF'
Usage:
  SOURCE_EMAIL='user@example.com' bash scripts/backup-user-data.sh > user-backup.json
  SOURCE_USER_ID='user_xxx' OUTPUT_FILE=./scripts/user-backup.json bash scripts/backup-user-data.sh

Environment variables:
  SOURCE_EMAIL       Backup source user email
  SOURCE_USER_ID     Backup source user id
  USER_EMAIL         Alias of SOURCE_EMAIL
  USER_ID            Alias of SOURCE_USER_ID
  OUTPUT_FILE        Optional output file path. If unset, JSON is written to stdout.
  POSTGRES_SERVICE   Docker Compose PostgreSQL service name. Default: postgresql
  POSTGRES_DB        PostgreSQL database name. Default: LOBE_DB_NAME or lobechat
  POSTGRES_USER      PostgreSQL user. Default: postgres
  POSTGRES_PASSWORD_VALUE
                    PostgreSQL password. Default: POSTGRES_PASSWORD from .env

Notes:
  - This script follows the official PostgreSQL importer/exporter scope of core user data.
  - Auth tables, RustFS object data, files/knowledge-base blobs, and server-side sessions are not included.
EOF
}

export_table_json() {
  local table_name="$1"
  local source_user_id_sql="$2"
  local sql=''

  case "${table_name}" in
    user_settings)
      sql="
SELECT COALESCE(jsonb_agg(to_jsonb(row_data)), '[]'::jsonb)
FROM (
  SELECT *
  FROM user_settings
  WHERE id = '${source_user_id_sql}'
) row_data;
"
      ;;
    user_installed_plugins|ai_providers|ai_models|session_groups|agents|sessions|topics|threads|messages)
      sql="
SELECT COALESCE(jsonb_agg(to_jsonb(row_data)), '[]'::jsonb)
FROM (
  SELECT *
  FROM ${table_name}
  WHERE user_id = '${source_user_id_sql}'
) row_data;
"
      ;;
    message_plugins|message_translates)
      sql="
SELECT COALESCE(jsonb_agg(to_jsonb(row_data)), '[]'::jsonb)
FROM (
  SELECT *
  FROM ${table_name}
  WHERE (
    EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = '${table_name}'
        AND column_name = 'user_id'
    )
    AND user_id = '${source_user_id_sql}'
  ) OR (
    NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = '${table_name}'
        AND column_name = 'user_id'
    )
    AND id IN (
      SELECT id
      FROM messages
      WHERE user_id = '${source_user_id_sql}'
    )
  )
) row_data;
"
      ;;
    agents_to_sessions)
      sql="
SELECT COALESCE(jsonb_agg(to_jsonb(row_data)), '[]'::jsonb)
FROM (
  SELECT *
  FROM agents_to_sessions
  WHERE (
    EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'agents_to_sessions'
        AND column_name = 'user_id'
    )
    AND user_id = '${source_user_id_sql}'
  ) OR (
    NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'agents_to_sessions'
        AND column_name = 'user_id'
    )
    AND (
      agent_id IN (
        SELECT id
        FROM agents
        WHERE user_id = '${source_user_id_sql}'
      ) OR session_id IN (
        SELECT id
        FROM sessions
        WHERE user_id = '${source_user_id_sql}'
      )
    )
  )
) row_data;
"
      ;;
    *)
      echo "Unsupported backup table: ${table_name}" >&2
      exit 1
      ;;
  esac

  psql_scalar "${sql}"
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

SOURCE_EMAIL="${SOURCE_EMAIL:-${USER_EMAIL:-}}"
SOURCE_USER_ID="${SOURCE_USER_ID:-${USER_ID:-}}"
OUTPUT_FILE="${OUTPUT_FILE:-}"

validate_email_or_empty "${SOURCE_EMAIL}"

if [[ -z "${SOURCE_EMAIL}" && -z "${SOURCE_USER_ID}" ]]; then
  echo "Set SOURCE_EMAIL or SOURCE_USER_ID." >&2
  usage >&2
  exit 1
fi

SOURCE_USER_JSON="$(resolve_user_row_json "${SOURCE_USER_ID}" "${SOURCE_EMAIL}")"
if [[ -z "${SOURCE_USER_JSON}" ]]; then
  if [[ -n "${SOURCE_USER_ID}" ]]; then
    echo "Source user not found: ${SOURCE_USER_ID}" >&2
  else
    echo "Source user not found: ${SOURCE_EMAIL}" >&2
  fi
  exit 1
fi

SOURCE_USER_ID_RESOLVED="$(resolve_user_id "${SOURCE_USER_ID}" "${SOURCE_EMAIL}")"
SOURCE_EMAIL_RESOLVED="$(resolve_user_email "${SOURCE_USER_ID_RESOLVED}")"
SOURCE_USER_ID_SQL="$(sql_escape_literal "${SOURCE_USER_ID_RESOLVED}")"

declare -A TABLE_JSON=()

printf 'Backing up core user data for id=%s email=%s...\n' \
  "${SOURCE_USER_ID_RESOLVED}" \
  "${SOURCE_EMAIL_RESOLVED:-<empty>}" >&2

for table_name in "${LOBE_USER_BACKUP_TABLES[@]}"; do
  if pg_table_exists "${table_name}"; then
    TABLE_JSON["${table_name}"]="$(export_table_json "${table_name}" "${SOURCE_USER_ID_SQL}")"
  else
    TABLE_JSON["${table_name}"]='[]'
    printf 'Skipping missing table: %s\n' "${table_name}" >&2
  fi
done

TMP_OUTPUT_FILE="$(mktemp)"

{
  echo '{'
  echo '  "format_version": 1,'
  echo '  "app": "lobehub-user-backup",'
  printf '  "created_at": "%s",\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf '  "source_user": %s,\n' "${SOURCE_USER_JSON}"
  echo '  "managed_tables": ['
  for index in "${!LOBE_USER_BACKUP_TABLES[@]}"; do
    table_name="${LOBE_USER_BACKUP_TABLES[${index}]}"
    if (( index + 1 < ${#LOBE_USER_BACKUP_TABLES[@]} )); then
      printf '    "%s",\n' "${table_name}"
    else
      printf '    "%s"\n' "${table_name}"
    fi
  done
  echo '  ],'
  echo '  "tables": {'
  for index in "${!LOBE_USER_BACKUP_TABLES[@]}"; do
    table_name="${LOBE_USER_BACKUP_TABLES[${index}]}"
    if (( index + 1 < ${#LOBE_USER_BACKUP_TABLES[@]} )); then
      printf '    "%s": %s,\n' "${table_name}" "${TABLE_JSON[${table_name}]}"
    else
      printf '    "%s": %s\n' "${table_name}" "${TABLE_JSON[${table_name}]}"
    fi
  done
  echo '  }'
  echo '}'
} > "${TMP_OUTPUT_FILE}"

if [[ -n "${OUTPUT_FILE}" ]]; then
  mv "${TMP_OUTPUT_FILE}" "${OUTPUT_FILE}"
  printf 'Backup written to %s\n' "${OUTPUT_FILE}" >&2
else
  cat "${TMP_OUTPUT_FILE}"
  rm -f "${TMP_OUTPUT_FILE}"
fi

printf 'Completed.\n' >&2