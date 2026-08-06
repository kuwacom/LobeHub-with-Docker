#!/usr/bin/env bash
# PostgreSQL 拡張の自動更新スクリプト
#
# LobeHub は ParadeDB (pg_search) に依存しており、Docker イメージを更新しても
# 既存データベース内の拡張は自動更新されない。そのため `pg_search` が古いまま残り、
# 最新の LobeHub が使う `minimum_should_match` などの新機能で
#   error: unboxing minimum_should_match_ argument failed
# が発生してチャット不能になる (pg_search 0.22.x には同引数が無く、
# LobeHub v2.2.x が paradedb.boolean() で同引数を使うため)。
#
# 本スクリプトは PostgreSQL コンテナとは別のマイグレーションコンテナから
# ネットワーク経由で接続し、インストール済み拡張をイメージに同梱の最新版へ更新する。
# PostgreSQL 公式エントリポイントは変更しないため、シグナルハンドリングや
# グレースフルシャットダウンは安全に保たれる。
#
# 参照:
#   https://docs.paradedb.com/deploy/upgrading
#   https://github.com/paradedb/paradedb/releases/tag/v0.24.1 (minimum_should_match 追加)
set -euo pipefail

# 接続先ホスト。同一コンテナ内で実行する場合は未設定で localhost 扱い。
PGHOST="${PGHOST:-postgresql}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-${POSTGRES_DB:-postgres}}"

PSQL=(psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1)

log() { printf '[update-extensions] %s\n' "$*" >&2; }

# pg_search (ParadeDB) の更新
#   - 拡張が未インストールならスキップ
#   - default_version と installed_version を比較し、差分がある場合のみ ALTER EXTENSION を実行
#   - psql -tAc は末尾改行を含むため tr で前後空白を除去してから IFS で分割
PG_SEARCH_STATUS="$("${PSQL[@]}" -tAc "
SELECT
  COALESCE((SELECT installed_version FROM pg_available_extensions WHERE name='pg_search'), '') || '|' ||
  COALESCE((SELECT default_version  FROM pg_available_extensions WHERE name='pg_search'), '');
" | tr -d '[:space:]')"

INSTALLED="${PG_SEARCH_STATUS%%|*}"
DEFAULT="${PG_SEARCH_STATUS##*|}"

if [ -z "$DEFAULT" ]; then
  log 'pg_search is not available in this image; skipping.'
elif [ "$INSTALLED" = "$DEFAULT" ]; then
  log "pg_search is up-to-date ($INSTALLED); nothing to do."
else
  if [ -z "$INSTALLED" ]; then
    log "pg_search is not installed yet; skipping (LobeHub migration will create it)."
  else
    log "Upgrading pg_search: $INSTALLED -> $DEFAULT"
    "${PSQL[@]}" -c "ALTER EXTENSION pg_search UPDATE TO '$DEFAULT';"
  fi
  # version_info() と pg_extension の整合性を確認 (0.25.x で関数名が変わる可能性があるため存在チェック)
  ACTUAL="$("${PSQL[@]}" -tAc "SELECT extversion FROM pg_extension WHERE extname='pg_search';")"
  if [ "$ACTUAL" != "$DEFAULT" ]; then
    log "Warning: pg_search version mismatch after ALTER (pg_extension=$ACTUAL, default=$DEFAULT). A Postgres restart may be required."
  fi
fi

# vector (pgvector) の更新 — LobeHub は埋め込み検索で使用
VECTOR_STATUS="$("${PSQL[@]}" -tAc "
SELECT
  COALESCE((SELECT installed_version FROM pg_available_extensions WHERE name='vector'), '') || '|' ||
  COALESCE((SELECT default_version  FROM pg_available_extensions WHERE name='vector'), '');
" | tr -d '[:space:]')"

V_INSTALLED="${VECTOR_STATUS%%|*}"
V_DEFAULT="${VECTOR_STATUS##*|}"

if [ -n "$V_DEFAULT" ] && [ -n "$V_INSTALLED" ] && [ "$V_INSTALLED" != "$V_DEFAULT" ]; then
  log "Upgrading vector: $V_INSTALLED -> $V_DEFAULT"
  "${PSQL[@]}" -c "ALTER EXTENSION vector UPDATE TO '$V_DEFAULT';"
elif [ -z "$V_INSTALLED" ] && [ -n "$V_DEFAULT" ]; then
  log "vector is not installed yet; skipping (LobeHub migration will create it)."
else
  log "vector is up-to-date ($V_INSTALLED); nothing to do."
fi

log 'Done.'
