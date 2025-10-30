#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------
# Terraform runner that ALWAYS ensures Azure remote state
#   (RG + Storage Account + Container) BEFORE 'terraform init'
# Supports backend.tf (azurerm backend) or backend.hcl
# ----------------------------------------------------------

# ---------- Config (overrides via env) ----------
TF_DIR="${TF_DIR:-terraform}"
PLAN_DIR="${PLAN_DIR:-$TF_DIR/tfplans}"
LABEL="${LABEL:-run}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"
UPGRADE="${UPGRADE:-true}"
RECONFIGURE="${RECONFIGURE:-false}"     # force -reconfigure
MIGRATE_STATE="${MIGRATE_STATE:-false}" # set true when you intentionally moved backend

# Remote-state fallbacks when backend files are absent/incomplete
LOCATION="${LOCATION:-uksouth}"
RESOURCE_GROUP="${RESOURCE_GROUP:-tf-backend-rg}"
STACCOUNT="${STACCOUNT:-}"              # will auto-generate if empty
CONTAINER="${CONTAINER:-tfstate}"
STATE_KEY="${STATE_KEY:-terraform.tfstate}"

# Optional maintenance flows
RESET="${RESET:-false}"                 # remove .terraform + lockfile
DO_DESTROY="${DO_DESTROY:-false}"       # terraform destroy (if backend reachable)
NUKE_RG="${NUKE_RG:-}"                  # az group delete (defaults to backend RG)
EXIT_AFTER_CLEANUP="${EXIT_AFTER_CLEANUP:-false}"

# ---------- Requirements ----------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1 — install it first."; exit 1; }; }
need az
need terraform
need awk
need sed
need grep

tf() { terraform -chdir="$TF_DIR" "$@"; }
ts() { date +%Y-%m-%d_%H%M; }

BACKEND_HCL="$TF_DIR/backend.hcl"
BACKEND_TF="$TF_DIR/backend.tf"

BK_RG=""; BK_SA=""; BK_CT=""; BK_KEY=""
USING_BACKEND_HCL="false"
USING_BACKEND_TF="false"

# ---------- Azure login / provider ----------
echo "Checking Azure CLI login..."
if ! az account show >/dev/null 2>&1; then
  az login >/dev/null
fi
TENANT_ID=$(az account show --query tenantId -o tsv)
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
echo "Tenant: $TENANT_ID"
echo "Subscription: $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"
export ARM_TENANT_ID="$TENANT_ID"
export ARM_SUBSCRIPTION_ID="$SUBSCRIPTION_ID"
export ARM_USE_AZUREAD=true
export ARM_USE_OIDC=false

echo "Ensuring Microsoft.Storage provider is registered..."
az provider register --namespace Microsoft.Storage >/dev/null || true
for _ in {1..20}; do
  st=$(az provider show --namespace Microsoft.Storage --query registrationState -o tsv)
  [[ "$st" == "Registered" ]] && break
  echo "  registrationState=$st ..."
  sleep 2
done
echo "Provider ready."
echo

# ---------- Helpers ----------
rg_exists() { az group show -n "$1" --query name -o tsv >/dev/null 2>&1; }
rg_state()  { az group show -n "$1" --query "properties.provisioningState" -o tsv 2>/dev/null || echo "Deleted"; }
wait_rg_deleted() {
  local rg="$1" tries="${2:-30}" delay="${3:-5}"
  echo "Waiting RG '$rg' to finish deleting..."
  for i in $(seq 1 "$tries"); do
    if ! rg_exists "$rg"; then echo "RG '$rg' is gone."; return 0; fi
    echo "  attempt $i/$tries: state=$(rg_state "$rg")"
    sleep "$delay"
  done
  echo "Timeout waiting RG delete. Continuing."
}

parse_backend_hcl() {
  if [[ -f "$BACKEND_HCL" ]]; then
    BK_RG=$(awk -F= '/resource_group_name/ {gsub(/[ "]/,"",$2);print $2}' "$BACKEND_HCL" || true)
    BK_SA=$(awk -F= '/storage_account_name/ {gsub(/[ "]/,"",$2);print $2}' "$BACKEND_HCL" || true)
    BK_CT=$(awk -F= '/container_name/ {gsub(/[ "]/,"",$2);print $2}' "$BACKEND_HCL" || true)
    BK_KEY=$(awk -F= '/^ *key/ {gsub(/[ "]/,"",$2);print $2}' "$BACKEND_HCL" || true)
    USING_BACKEND_HCL="true"
  fi
}

parse_backend_tf() {
  if [[ -f "$BACKEND_TF" ]] && grep -q 'backend *"azurerm"' "$BACKEND_TF"; then
    local BLOCK
    BLOCK=$(awk '
      /backend *"azurerm" *{/ {inblk=1}
      inblk {print}
      /}/ && inblk {inblk=0}
    ' "$BACKEND_TF")
    BK_RG=$(echo "$BLOCK" | awk -F= '/resource_group_name/ {gsub(/[ "\r]/,"",$2);print $2}' || true)
    BK_SA=$(echo "$BLOCK" | awk -F= '/storage_account_name/ {gsub(/[ "\r]/,"",$2);print $2}' || true)
    BK_CT=$(echo "$BLOCK" | awk -F= '/container_name/ {gsub(/[ "\r]/,"",$2);print $2}' || true)
    BK_KEY=$(echo "$BLOCK" | awk -F= '/^ *key/ {gsub(/[ "\r]/,"",$2);print $2}' || true)
    if [[ -n "$BK_RG$BK_SA$BK_CT$BK_KEY" ]]; then USING_BACKEND_TF="true"; fi
  fi
}

ensure_backend_stack() {
  # Choose coordinates:
  local rg="${BK_RG:-$RESOURCE_GROUP}"
  local sa="${BK_SA:-$STACCOUNT}"
  local ct="${BK_CT:-$CONTAINER}"
  local key="${BK_KEY:-$STATE_KEY}"

  # Generate SA name if empty
  if [[ -z "$sa" ]]; then
    RAND=$(tr -dc a-z0-9 </dev/urandom | head -c 6 || true)
    sa="sabackend"${RAND}"
  fi

  # Create RG/SA/Container if missing
  if rg_exists "$rg"; then
    st=$(rg_state "$rg"); [[ "$st" =~ ^(Deleting|Deprovisioning)$ ]] && wait_rg_deleted "$rg" 40 5
  fi
  if ! rg_exists "$rg"; then
    echo "Creating remote-state RG: $rg ($LOCATION)"
    az group create -n "$rg" -l "$LOCATION" -o table
  fi
  if ! az storage account show -n "$sa" -g "$rg" >/dev/null 2>&1; then
    echo "Creating remote-state Storage Account: $sa"
    az storage account create -n "$sa" -g "$rg" -l "$LOCATION" --sku Standard_LRS --kind StorageV2 -o table
  fi
  if ! az storage container show --account-name "$sa" --name "$ct" --auth-mode login >/dev/null 2>&1; then
    echo "Creating remote-state Container: $ct"
    az storage container create --account-name "$sa" --name "$ct" --auth-mode login -o table
  fi

  # Export back to globals (so downstream uses the actuals)
  BK_RG="$rg"; BK_SA="$sa"; BK_CT="$ct"; BK_KEY="$key"

  echo
  echo "Remote state ready:"
  echo "  RG=$BK_RG"
  echo "  ST=$BK_SA"
  echo "  CT=$BK_CT"
  echo "  KEY=$BK_KEY"
  echo
}

build_backend_flags() {
  BACKEND_FLAGS=()
  # If using backend.hcl, include it
  [[ "$USING_BACKEND_HCL" == "true" ]] && BACKEND_FLAGS+=(-backend-config="backend.hcl")
  # Always pass access_key so init doesn't prompt
  echo "Fetching backend access key for $BK_SA (RG: $BK_RG)"
  ACCESS_KEY=$(az storage account keys list -n "$BK_SA" -g "$BK_RG" --query "[0].value" -o tsv)
  BACKEND_FLAGS+=(-backend-config="access_key=$ACCESS_KEY")
}

# ---------- Optional local cleanup / destroy / nuke ----------
if [[ "$RESET" == "true" ]]; then
  echo "Resetting local Terraform artifacts..."
  rm -rf "$TF_DIR/.terraform" || true
  rm -f  "$TF_DIR/.terraform.lock.hcl" || true
  RECONFIGURE="true"
  echo "Local artifacts cleaned."
  echo
fi

# Parse backend coordinates from files (if present)
parse_backend_hcl
[[ "$USING_BACKEND_HCL" == "false" ]] && parse_backend_tf

# ALWAYS ensure remote state exists BEFORE init (this is your requested step)
ensure_backend_stack

# If you want to only destroy/nuke and exit:
if [[ -z "$NUKE_RG" && -n "$BK_RG" ]]; then NUKE_RG="$BK_RG"; fi

if [[ "$DO_DESTROY" == "true" ]]; then
  echo "terraform destroy (using remote backend)"
  build_backend_flags
  tf init -reconfigure ${UPGRADE:+-upgrade} "${BACKEND_FLAGS[@]}"
  tf destroy
  echo "Destroy complete."
fi

if [[ -n "$NUKE_RG" ]]; then
  if rg_exists "$NUKE_RG"; then
    echo "Deleting RG '$NUKE_RG'..."
    az group delete -n "$NUKE_RG" --yes --no-wait
    wait_rg_deleted "$NUKE_RG" 40 5
    RECONFIGURE="true"
  else
    echo "RG '$NUKE_RG' not found — nothing to delete."
  fi
  [[ "$EXIT_AFTER_CLEANUP" == "true" ]] && { echo "Exiting after cleanup as requested."; exit 0; }
fi

# ---------- Normal Terraform flow ----------
INIT_FLAGS=()
if [[ "$MIGRATE_STATE" == "true" ]]; then
  INIT_FLAGS+=(-migrate-state)
  [[ "$UPGRADE" == "true" ]] && INIT_FLAGS+=(-upgrade)
else
  [[ "$RECONFIGURE" == "true" ]] && INIT_FLAGS+=(-reconfigure)
  [[ "$UPGRADE" == "true" ]] && INIT_FLAGS+=(-upgrade)
fi

build_backend_flags
echo "terraform init ${INIT_FLAGS[*]} ${BACKEND_FLAGS[*]}"
tf init "${INIT_FLAGS[@]}" "${BACKEND_FLAGS[@]}"

echo "terraform fmt"
tf fmt -check || tf fmt -write=true

echo "terraform validate"
tf validate

mkdir -p "$PLAN_DIR"
PLAN_FILE_REL="tfplans/$(ts)-${LABEL}.tfplan"
echo "terraform plan -> $TF_DIR/$PLAN_FILE_REL"
tf plan -out="$PLAN_FILE_REL"

if [[ "$AUTO_APPROVE" == "true" ]]; then
  echo "terraform apply (auto-approve)"
  tf apply -auto-approve "$PLAN_FILE_REL"
else
  echo "terraform apply (prompted)"
  tf apply "$PLAN_FILE_REL"
fi

echo
echo "Terraform outputs:"
set +e
tf output
set -e

echo
echo "Done."
