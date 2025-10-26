#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./scripts/db_apply.sh --all            # staging + schema + transform (default)
#   ./scripts/db_apply.sh --stg            # staging only
#   ./scripts/db_apply.sh --schema         # DWH schema only
#   ./scripts/db_apply.sh --transform      # transform/load only
#   PGUSER=... PGPASSWORD=... ./scripts/db_apply.sh --transform

MODE="${1:---all}"

MODE="${1:---all}"

# --- paths ---
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
SQL_STG="$REPO_ROOT/sql/stg/api_311_raw.sql"
SQL_DWH_SCHEMA="$REPO_ROOT/sql/dwh/schema.sql"
SQL_DWH_TRANSFORM="$REPO_ROOT/sql/dwh/transform_load.sql"
SQL_SAMPLE="$REPO_ROOT/sql/stg/sample_insert.sql"   # optional

# --- check dependencies ---
command -v psql >/dev/null 2>&1 || { echo "psql not found. Install it first."; exit 1; }

# --- get connection details ---
PGHOST="${PGHOST:-$(terraform -chdir="$TF_DIR" output -raw postgres_fqdn 2>/dev/null || true)}"
PGDB="${PGDB:-$(terraform -chdir="$TF_DIR" output -raw database 2>/dev/null || echo civicpulse_311)}"
PGUSER="${PGUSER:-${TF_VAR_pg_admin_user:-pgadmin}}"

[[ -n "${PGHOST:-}" ]] || read -rp "Postgres host (FQDN): " PGHOST
if [[ -z "${PGPASSWORD:-}" ]]; then
  read -rs -p "Password for user '$PGUSER': " PGPASSWORD
  echo
fi

# --- safe wrapper for psql ---
run_sql() {
  local file="$1"
  echo "-> Applying: $file"
  PGPASSWORD="$PGPASSWORD" psql -v ON_ERROR_STOP=1 \
    -h "$PGHOST" -d "$PGDB" -U "$PGUSER" -f "$file"
}

run_stg()      { [[ -f "$SQL_STG" ]] || { echo "Missing $SQL_STG"; exit 1; }; run_sql "$SQL_STG"; }
run_sample()   { [[ -f "$SQL_SAMPLE" ]] && run_sql "$SQL_SAMPLE" || true; }
run_schema()   { [[ -f "$SQL_DWH_SCHEMA" ]] || { echo "Missing $SQL_DWH_SCHEMA"; exit 1; }; run_sql "$SQL_DWH_SCHEMA"; }
run_transform(){ [[ -f "$SQL_DWH_TRANSFORM" ]] || { echo "Missing $SQL_DWH_TRANSFORM"; exit 1; }; run_sql "$SQL_DWH_TRANSFORM"; }

case "$MODE" in
  --all)       run_stg; run_sample; run_schema; run_transform ;;
  --stg)       run_stg ;;
  --schema)    run_schema ;;
  --transform) run_transform ;;
  *) echo "Usage: $0 [--all|--stg|--schema|--transform]"; exit 2 ;;
esac

echo "Done ($MODE). Host=$PGHOST DB=$PGDB User=$PGUSER"