#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-lobehub-db.sh
source "${SCRIPT_DIR}/lib-lobehub-db.sh"

usage() {
  cat <<'EOF'
Usage:
  TARGET_EMAIL='user@example.com' bash scripts/delete-user.sh --dry-run
  TARGET_EMAIL='user@example.com' bash scripts/delete-user.sh --no-dry-run --confirm-delete
  TARGET_USER_ID='user_xxx' bash scripts/delete-user.sh --no-dry-run --confirm-delete

Environment variables:
  TARGET_EMAIL       Delete target user email
  TARGET_USER_ID     Delete target user id
  USER_EMAIL         Alias of TARGET_EMAIL
  USER_ID            Alias of TARGET_USER_ID
  POSTGRES_SERVICE   Docker Compose PostgreSQL service name. Default: postgresql
  POSTGRES_DB        PostgreSQL database name. Default: LOBE_DB_NAME or lobechat
  POSTGRES_USER      PostgreSQL user. Default: postgres
  POSTGRES_PASSWORD_VALUE
                    PostgreSQL password. Default: POSTGRES_PASSWORD from .env

Arguments:
  --dry-run          Print the delete plan only. Default behavior
  --no-dry-run       Execute deletion instead of printing the plan
  --confirm-delete   Required together with --no-dry-run
  --help, -h         Show this help

Notes:
  - This script deletes the target user from the LobeHub PostgreSQL database.
  - Run backup-user-data.sh before execution if you may need to restore core chat data later.
  - Casdoor and other external identity stores are not modified by this script.
EOF
}

is_truthy() {
  local value="${1:-}"
  case "${value,,}" in
    1|true|yes|y|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

DRY_RUN='1'
CONFIRM_DELETE='false'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN='1'
      shift
      ;;
    --no-dry-run)
      DRY_RUN='0'
      shift
      ;;
    --confirm-delete)
      CONFIRM_DELETE='true'
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

load_lobehub_env
init_lobehub_postgres

TARGET_EMAIL="${TARGET_EMAIL:-${USER_EMAIL:-}}"
TARGET_USER_ID="${TARGET_USER_ID:-${USER_ID:-}}"

validate_email_or_empty "${TARGET_EMAIL}"

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

if is_truthy "${DRY_RUN}"; then
  DRY_RUN_SQL='true'
  printf 'Planning full deletion for id=%s email=%s\n' \
    "${TARGET_USER_ID_RESOLVED}" \
    "${TARGET_EMAIL_RESOLVED:-<empty>}" >&2
else
  DRY_RUN_SQL='false'

  if ! is_truthy "${CONFIRM_DELETE}"; then
    echo "Pass --confirm-delete together with --no-dry-run." >&2
    exit 1
  fi

  printf 'Deleting full account data for id=%s email=%s\n' \
    "${TARGET_USER_ID_RESOLVED}" \
    "${TARGET_EMAIL_RESOLVED:-<empty>}" >&2
fi

{
  cat <<SQL
BEGIN;

CREATE TEMP TABLE action_summary (
  order_no bigserial PRIMARY KEY,
  action text NOT NULL,
  table_name text NOT NULL,
  column_name text,
  row_count bigint NOT NULL
);

DO \$\$
DECLARE
  target_user_id text := '${TARGET_USER_ID_SQL}';
  is_dry_run boolean := ${DRY_RUN_SQL};
  current_record record;
  affected_rows bigint;
  pending_rows integer;
  progressed_rows integer;
  blocking_refs text;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.users
    WHERE id = target_user_id
  ) THEN
    RAISE EXCEPTION 'Target user not found: %', target_user_id;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_constraint con
    WHERE con.contype = 'f'
      AND con.confrelid = 'public.users'::regclass
      AND (
        array_length(con.conkey, 1) <> 1
        OR array_length(con.confkey, 1) <> 1
      )
  ) THEN
    RAISE EXCEPTION 'Unsupported multi-column foreign key references to public.users exist';
  END IF;

  CREATE TEMP TABLE delete_targets (
    table_oid oid PRIMARY KEY,
    schema_name text NOT NULL,
    table_name text NOT NULL,
    column_name text NOT NULL
  ) ON COMMIT DROP;

  IF EXISTS (
    SELECT 1
    FROM (
      SELECT
        con.conrelid AS table_oid
      FROM pg_constraint con
      JOIN pg_class cls
        ON cls.oid = con.conrelid
      JOIN pg_namespace ns
        ON ns.oid = cls.relnamespace
      JOIN pg_attribute attr
        ON attr.attrelid = con.conrelid
       AND attr.attnum = con.conkey[1]
      JOIN pg_attribute ref_attr
        ON ref_attr.attrelid = con.confrelid
       AND ref_attr.attnum = con.confkey[1]
      WHERE con.contype = 'f'
        AND con.confrelid = 'public.users'::regclass
        AND ns.nspname = 'public'
        AND ref_attr.attname = 'id'
        AND attr.attname IN ('user_id', 'userId', 'id')
      GROUP BY con.conrelid
      HAVING COUNT(*) > 1
    ) duplicated_targets
  ) THEN
    RAISE EXCEPTION 'Unsupported multiple owner references to public.users exist on a single table';
  END IF;

  INSERT INTO delete_targets (table_oid, schema_name, table_name, column_name)
  SELECT
    con.conrelid AS table_oid,
    ns.nspname AS schema_name,
    cls.relname AS table_name,
    attr.attname AS column_name
  FROM pg_constraint con
  JOIN pg_class cls
    ON cls.oid = con.conrelid
  JOIN pg_namespace ns
    ON ns.oid = cls.relnamespace
  JOIN pg_attribute attr
    ON attr.attrelid = con.conrelid
   AND attr.attnum = con.conkey[1]
  JOIN pg_attribute ref_attr
    ON ref_attr.attrelid = con.confrelid
   AND ref_attr.attnum = con.confkey[1]
  WHERE con.contype = 'f'
    AND con.confrelid = 'public.users'::regclass
    AND ns.nspname = 'public'
    AND ref_attr.attname = 'id'
    AND attr.attname IN ('user_id', 'userId', 'id');

  CREATE TEMP TABLE pending_delete_targets
  ON COMMIT DROP
  AS
  SELECT *
  FROM delete_targets;

  -- 旧スキーマで user_id を持たない中間テーブルを先に掃除する
  IF to_regclass('public.message_plugins') IS NOT NULL
    AND to_regclass('public.messages') IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'message_plugins'
        AND column_name IN ('user_id', 'userId')
    ) THEN
    EXECUTE '
      SELECT COUNT(*)
      FROM public.message_plugins
      WHERE id IN (
        SELECT id
        FROM public.messages
        WHERE user_id = \$1
      )
    '
      INTO affected_rows
      USING target_user_id;

    INSERT INTO action_summary (action, table_name, column_name, row_count)
    VALUES (
      CASE WHEN is_dry_run THEN 'delete-plan' ELSE 'delete' END,
      'message_plugins',
      'id',
      affected_rows
    );

    IF NOT is_dry_run THEN
      EXECUTE '
        DELETE FROM public.message_plugins
        WHERE id IN (
          SELECT id
          FROM public.messages
          WHERE user_id = \$1
        )
      '
        USING target_user_id;
    END IF;
  END IF;

  IF to_regclass('public.message_translates') IS NOT NULL
    AND to_regclass('public.messages') IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'message_translates'
        AND column_name IN ('user_id', 'userId')
    ) THEN
    EXECUTE '
      SELECT COUNT(*)
      FROM public.message_translates
      WHERE id IN (
        SELECT id
        FROM public.messages
        WHERE user_id = \$1
      )
    '
      INTO affected_rows
      USING target_user_id;

    INSERT INTO action_summary (action, table_name, column_name, row_count)
    VALUES (
      CASE WHEN is_dry_run THEN 'delete-plan' ELSE 'delete' END,
      'message_translates',
      'id',
      affected_rows
    );

    IF NOT is_dry_run THEN
      EXECUTE '
        DELETE FROM public.message_translates
        WHERE id IN (
          SELECT id
          FROM public.messages
          WHERE user_id = \$1
        )
      '
        USING target_user_id;
    END IF;
  END IF;

  IF to_regclass('public.agents_to_sessions') IS NOT NULL
    AND to_regclass('public.agents') IS NOT NULL
    AND to_regclass('public.sessions') IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'agents_to_sessions'
        AND column_name IN ('user_id', 'userId')
    ) THEN
    EXECUTE '
      SELECT COUNT(*)
      FROM public.agents_to_sessions
      WHERE agent_id IN (
        SELECT id
        FROM public.agents
        WHERE user_id = \$1
      ) OR session_id IN (
        SELECT id
        FROM public.sessions
        WHERE user_id = \$1
      )
    '
      INTO affected_rows
      USING target_user_id;

    INSERT INTO action_summary (action, table_name, column_name, row_count)
    VALUES (
      CASE WHEN is_dry_run THEN 'delete-plan' ELSE 'delete' END,
      'agents_to_sessions',
      'agent_id|session_id',
      affected_rows
    );

    IF NOT is_dry_run THEN
      EXECUTE '
        DELETE FROM public.agents_to_sessions
        WHERE agent_id IN (
          SELECT id
          FROM public.agents
          WHERE user_id = \$1
        ) OR session_id IN (
          SELECT id
          FROM public.sessions
          WHERE user_id = \$1
        )
      '
        USING target_user_id;
    END IF;
  END IF;

  LOOP
    SELECT COUNT(*)
    INTO pending_rows
    FROM pending_delete_targets;

    EXIT WHEN pending_rows = 0;

    progressed_rows := 0;

    FOR current_record IN
      SELECT
        pending.table_oid,
        pending.schema_name,
        pending.table_name,
        pending.column_name
      FROM pending_delete_targets pending
      WHERE NOT EXISTS (
        SELECT 1
        FROM pg_constraint con
        JOIN pending_delete_targets child
          ON child.table_oid = con.conrelid
        WHERE con.contype = 'f'
          AND con.confrelid = pending.table_oid
          AND con.conrelid <> con.confrelid
      )
      ORDER BY pending.table_name
    LOOP
      EXECUTE format(
        'SELECT COUNT(*) FROM %I.%I WHERE %I = \$1',
        current_record.schema_name,
        current_record.table_name,
        current_record.column_name
      )
        INTO affected_rows
        USING target_user_id;

      INSERT INTO action_summary (action, table_name, column_name, row_count)
      VALUES (
        CASE WHEN is_dry_run THEN 'delete-plan' ELSE 'delete' END,
        current_record.table_name,
        current_record.column_name,
        affected_rows
      );

      IF NOT is_dry_run THEN
        EXECUTE format(
          'DELETE FROM %I.%I WHERE %I = \$1',
          current_record.schema_name,
          current_record.table_name,
          current_record.column_name
        )
          USING target_user_id;
      END IF;

      DELETE FROM pending_delete_targets
      WHERE table_oid = current_record.table_oid;

      progressed_rows := progressed_rows + 1;
    END LOOP;

    IF progressed_rows = 0 THEN
      RAISE EXCEPTION 'Unable to resolve delete order for user-owned tables';
    END IF;
  END LOOP;

  CREATE TEMP TABLE nullify_targets (
    table_oid oid NOT NULL,
    schema_name text NOT NULL,
    table_name text NOT NULL,
    column_name text NOT NULL,
    is_nullable boolean NOT NULL,
    confdeltype "char" NOT NULL
  ) ON COMMIT DROP;

  INSERT INTO nullify_targets (table_oid, schema_name, table_name, column_name, is_nullable, confdeltype)
  SELECT
    con.conrelid AS table_oid,
    ns.nspname AS schema_name,
    cls.relname AS table_name,
    attr.attname AS column_name,
    NOT attr.attnotnull AS is_nullable,
    con.confdeltype
  FROM pg_constraint con
  JOIN pg_class cls
    ON cls.oid = con.conrelid
  JOIN pg_namespace ns
    ON ns.oid = cls.relnamespace
  JOIN pg_attribute attr
    ON attr.attrelid = con.conrelid
   AND attr.attnum = con.conkey[1]
  JOIN pg_attribute ref_attr
    ON ref_attr.attrelid = con.confrelid
   AND ref_attr.attnum = con.confkey[1]
  WHERE con.contype = 'f'
    AND con.confrelid = 'public.users'::regclass
    AND ns.nspname = 'public'
    AND ref_attr.attname = 'id'
    AND attr.attname NOT IN ('user_id', 'userId', 'id');

  SELECT string_agg(
    format('%I.%I.%I', schema_name, table_name, column_name),
    ', '
    ORDER BY table_name, column_name
  )
  INTO blocking_refs
  FROM nullify_targets
  WHERE confdeltype IN ('a', 'r', 'd')
    AND NOT is_nullable;

  IF blocking_refs IS NOT NULL THEN
    RAISE EXCEPTION 'Unsupported non-null user references remain: %', blocking_refs;
  END IF;

  FOR current_record IN
    SELECT
      table_oid,
      schema_name,
      table_name,
      column_name
    FROM nullify_targets
    WHERE confdeltype IN ('a', 'r', 'd')
      AND is_nullable
    ORDER BY table_name, column_name
  LOOP
    EXECUTE format(
      'SELECT COUNT(*) FROM %I.%I WHERE %I = \$1',
      current_record.schema_name,
      current_record.table_name,
      current_record.column_name
    )
      INTO affected_rows
      USING target_user_id;

    INSERT INTO action_summary (action, table_name, column_name, row_count)
    VALUES (
      CASE WHEN is_dry_run THEN 'nullify-plan' ELSE 'nullify' END,
      current_record.table_name,
      current_record.column_name,
      affected_rows
    );

    IF NOT is_dry_run THEN
      EXECUTE format(
        'UPDATE %I.%I SET %I = NULL WHERE %I = \$1',
        current_record.schema_name,
        current_record.table_name,
        current_record.column_name,
        current_record.column_name
      )
        USING target_user_id;
    END IF;
  END LOOP;

  SELECT COUNT(*)
  INTO affected_rows
  FROM public.users
  WHERE id = target_user_id;

  INSERT INTO action_summary (action, table_name, column_name, row_count)
  VALUES (
    CASE WHEN is_dry_run THEN 'delete-plan' ELSE 'delete' END,
    'users',
    'id',
    affected_rows
  );

  IF NOT is_dry_run THEN
    DELETE FROM public.users
    WHERE id = target_user_id;
  END IF;
END
\$\$;

SELECT
  action,
  table_name,
  COALESCE(column_name, '') AS column_name,
  row_count
FROM action_summary
WHERE row_count > 0
ORDER BY order_no;

COMMIT;
SQL
} | psql_run

if is_truthy "${DRY_RUN}"; then
  printf 'Dry-run completed.\n' >&2
else
  printf 'Completed.\n' >&2
fi
