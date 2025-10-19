#!/usr/bin/env bash
set -euo pipefail

# ------------------ Config ------------------
# Terraform directory that holds your state/outputs
TF_DIR="${TF_DIR:-terraform}"

# Run transform right after DDL? (true/false)
RUN_TRANSFORM=${RUN_TRANSFORM:-false}
SINCE_INTERVAL=${SINCE_INTERVAL:-'7 days'}
PGPORT=${PGPORT:-5432}

# ---------------- Requirements --------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing $1. Install it and retry."; exit 1; }; }
need terraform
need psql
need mktemp

# ---------------- Paths ---------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SQL_DIR="${SCRIPT_DIR}/sql"

STG_SQL="${SQL_DIR}/stg/api_311_raw.sql"
DWH_SCHEMA_SQL="${SQL_DIR}/dwh/schema.sql"
DWH_XFORM_SQL="${SQL_DIR}/dwh/transform_load.sql"

for f in "$STG_SQL" "$DWH_SCHEMA_SQL" "$DWH_XFORM_SQL"; do
  [[ -f "$f" ]] || { echo "❌ Missing file: $f"; exit 1; }
done

# --------- Pull connection info from TF -----
# Use -chdir so we don't depend on current working directory
PGHOST="$(terraform -chdir="$TF_DIR" output -raw postgres_fqdn 2>/dev/null || true)"
PGDATABASE="$(terraform -chdir="$TF_DIR" output -raw database 2>/dev/null || true)"

# Strip any CR characters (Windows/Git Bash)
PGHOST="${PGHOST//$'\r'/}"
PGDATABASE="${PGDATABASE//$'\r'/}"

if [[ -z "$PGHOST" || -z "$PGDATABASE" ]]; then
  echo " Could not read Terraform outputs from '$TF_DIR'."
  echo "   Make sure you ran 'terraform apply' in that folder and that outputs exist."
  echo "   Try manually: terraform -chdir=$TF_DIR output"
  exit 1
fi

# ---------------- Credentials ----------------
PGUSER="${TF_VAR_pg_admin_user:-pgadmin}"
if [[ -n "${TF_VAR_pg_admin_pwd:-}" ]]; then
  PGPASS="$TF_VAR_pg_admin_pwd"
elif [[ -n "${PGPASSWORD:-}" ]]; then
  PGPASS="$PGPASSWORD"
else
  read -rsp "Enter Postgres password for user '$PGUSER': " PGPASS
  echo
fi

# ---------- Temporary .pgpass setup ----------
PGPASSFILE="$(mktemp)"
cleanup() { rm -f "$PGPASSFILE" || true; }
trap cleanup EXIT

# host:port:database:username:password  (use * for db to reuse for all steps)
printf '%s:%s:%s:%s:%s\n' "$PGHOST" "$PGPORT" '*' "$PGUSER" "$PGPASS" > "$PGPASSFILE"
chmod 600 "$PGPASSFILE"
export PGPASSFILE
export PGSSLMODE=require

# --------------- Run SQL ---------------------
echo " Applying staging DDL: $STG_SQL"
psql -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -d "$PGDATABASE" -U "$PGUSER" -f "$STG_SQL"

echo " Applying DWH schema: $DWH_SCHEMA_SQL"
psql -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -d "$PGDATABASE" -U "$PGUSER" -f "$DWH_SCHEMA_SQL"

echo " Creating transform function: $DWH_XFORM_SQL"
psql -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -d "$PGDATABASE" -U "$PGUSER" -f "$DWH_XFORM_SQL"

if [[ "$RUN_TRANSFORM" == "true" ]]; then
  echo " Running transform for window: $SINCE_INTERVAL"
  psql -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -d "$PGDATABASE" -U "$PGUSER" \
    -c "SELECT dwh.run_311_transform(interval '$SINCE_INTERVAL');"
fi

echo "   DB init complete."
echo "   Host: $PGHOST"
echo "   DB:   $PGDATABASE"
echo "   User: $PGUSER"
echo "   Staging DDL: $STG_SQL"