#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------
# Terraform runner for Azure infrastructure (project root)
#  - Optional: create/overwrite remote backend (RG/SA/Container)
#  - Injects backend access key for azurerm remote state
#  - Detects backend changes, uses -reconfigure/-migrate-state
#  - Prints Terraform outputs after apply
# ----------------------------------------------------------

# ===============================
# Configuration (override via env)
# ===============================
TF_DIR="${TF_DIR:-terraform}"                # Terraform configuration folder
PLAN_DIR="${PLAN_DIR:-$TF_DIR/tfplans}"      # Folder for plan files (filesystem path)
LABEL="${LABEL:-run}"                        # Label for plan filename
AUTO_APPROVE="${AUTO_APPROVE:-false}"        # Apply without prompt if true
RECONFIGURE="${RECONFIGURE:-false}"          # Force terraform init -reconfigure
UPGRADE="${UPGRADE:-true}"                   # Terraform init -upgrade if true
MIGRATE_STATE="${MIGRATE_STATE:-false}"      # Terraform init -migrate-state if true

DO_PRECHECKS="${DO_PRECHECKS:-true}"         # Run Azure login/provider checks
RESET="${RESET:-false}"                      # Remove .terraform, lockfile, plan files
DO_DESTROY="${DO_DESTROY:-false}"            # Run terraform destroy (using backend if available)
NUKE_RG="${NUKE_RG:-}"                       # Force delete RG (defaults to backend RG when empty)
EXIT_AFTER_CLEANUP="${EXIT_AFTER_CLEANUP:-false}"   # if true, exit after destroy/nuke (no deploy)


CREATE_BACKEND="${CREATE_BACKEND:-true}"    # Create remote state RG/SA/Container
WRITE_BACKEND="${WRITE_BACKEND:-true}"      # If true, auto-write/overwrite terraform/backend.hcl
LOCATION="${LOCATION:-uksouth}"              # Region for backend when creating it
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-civicpulse-311}"  # RG name when creating backend
STACCOUNT="${STACCOUNT:-}"                   # Storage account name (auto if empty)
CONTAINER="${CONTAINER:-tfstate}"            # Container name for state blob
STATE_KEY="${STATE_KEY:-terraform.tfstate}"  # Blob name used as key

# Internal marker to signal backend was changed/recreated this run
BACKEND_CHANGED="false"

# ===============================
# Requirements
# ===============================
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1 — install it first."; exit 1; }; }
need az
need terraform
need awk
need sed

# Utilities
ts() { date +%Y-%m-%d_%H%M; }
tf() { terraform -chdir="$TF_DIR" "$@"; }   # always run terraform with -chdir

BACKEND_HCL="$TF_DIR/backend.hcl"

# ===============================
# Helper functions
# ===============================

# Parse backend.hcl to extract RG, SA, Container, Key (globals: BK_RG, BK_SA, BK_CT, BK_KEY)
parse_backend() {
  if [[ -f "$BACKEND_HCL" ]]; then
    BK_RG=$(awk -F= '/resource_group_name/ {gsub(/[ "]/,"",$2);print $2}' "$BACKEND_HCL" || true)
    BK_SA=$(awk -F= '/storage_account_name/ {gsub(/[ "]/,"",$2);print $2}' "$BACKEND_HCL" || true)
    BK_CT=$(awk -F= '/container_name/ {gsub(/[ "]/,"",$2);print $2}' "$BACKEND_HCL" || true)
    BK_KEY=$(awk -F= '/^ *key/ {gsub(/[ "]/,"",$2);print $2}' "$BACKEND_HCL" || true)
  else
    BK_RG=""; BK_SA=""; BK_CT=""; BK_KEY=""
  fi
}

# Check if a resource group exists (exit code 0 if exists)
rg_exists() {
  az group show -n "$1" --query name -o tsv >/dev/null 2>&1
}

# Get provisioning state of an RG (returns a string)
rg_state() {
  az group show -n "$1" --query "properties.provisioningState" -o tsv 2>/dev/null || echo "Deleted"
}

# Wait until RG is deleted (or timeout)
wait_rg_deleted() {
  local rg="$1" tries="${2:-30}" delay="${3:-5}"
  echo "Waiting for resource group '$rg' to finish deleting..."
  for i in $(seq 1 "$tries"); do
    if ! rg_exists "$rg"; then
      echo "RG '$rg' no longer exists."
      return 0
    fi
    local st; st=$(rg_state "$rg")
    echo "Check $i/$tries: provisioningState=$st"
    sleep "$delay"
  done
  echo "Timed out waiting for RG '$rg' to disappear. Continuing anyway."
  return 0
}

# Build backend flags (backend.hcl + access key) into BACKEND_FLAGS array
build_backend_flags() {
  BACKEND_FLAGS=()
  if [[ -f "$BACKEND_HCL" ]]; then
    BACKEND_FLAGS+=(-backend-config="backend.hcl")
    if [[ -n "$BK_RG" && -n "$BK_SA" ]]; then
      if rg_exists "$BK_RG" ]; then
        echo "Fetching backend access key for $BK_SA in RG $BK_RG"
        ACCESS_KEY=$(az storage account keys list -n "$BK_SA" -g "$BK_RG" --query "[0].value" -o tsv)
        BACKEND_FLAGS+=(-backend-config="access_key=$ACCESS_KEY")
      else
        echo "Backend RG '$BK_RG' not found — backend will be created before init."
        BACKEND_FLAGS=()  # skip passing backend until created
      fi
    else
      echo "backend.hcl missing required values (resource_group_name/storage_account_name)."
    fi
  else
    echo "No backend.hcl found — Terraform will use local state."
  fi
}

# Write/overwrite backend.hcl with provided values
write_backend_file() {
  local rg="$1" sa="$2" ct="$3" key="$4"
  mkdir -p "$(dirname "$BACKEND_HCL")"
  cat > "$BACKEND_HCL" <<EOF
resource_group_name  = "$rg"
storage_account_name = "$sa"
container_name       = "$ct"
key                  = "$key"
EOF
  echo "backend.hcl written to: $BACKEND_HCL"
}

# Create backend RG + Storage + Container
# If WRITE_BACKEND=true, auto-write backend.hcl; otherwise prompt to paste.
create_backend() {
  local rg="$1" loc="$2" sa="$3" ct="$4" key="$5"
  echo "Creating remote state resources:"
  echo "RG=$rg  Location=$loc  Container=$ct  Key=$key"

  # If RG is still deleting, wait for it to finish
  if rg_exists "$rg"; then
    local st; st=$(rg_state "$rg")
    if [[ "$st" =~ ^(Deleting|Deprovisioning)$ ]]; then
      wait_rg_deleted "$rg" 30 5
    fi
  fi

  az group create -n "$rg" -l "$loc" -o table

  local acc="$sa"
  if [[ -z "$acc" ]]; then
    RAND=$(tr -dc a-z0-9 </dev/urandom | head -c 6 || true)
    acc="stcivicpulse${RAND}"
  fi
  echo "Storage account: $acc"
  az storage account create -n "$acc" -g "$rg" -l "$loc" --sku Standard_LRS --kind StorageV2 -o table
  az storage container create --account-name "$acc" --name "$ct" --auth-mode login -o table

  if [[ "$WRITE_BACKEND" == "true" ]]; then
    write_backend_file "$rg" "$acc" "$ct" "$key"
  else
    echo
    echo "Backend created. Copy the following into $TF_DIR/backend.hcl:"
    echo
    echo "  resource_group_name  = \"$rg\""
    echo "  storage_account_name = \"$acc\""
    echo "  container_name       = \"$ct\""
    echo "  key                  = \"$key\""
    echo
    echo "Update backend.hcl, then press ENTER to continue (or Ctrl+C to cancel)."
    read -r
  fi

  # Mark backend changed and force reconfigure on init
  BACKEND_CHANGED="true"
  RECONFIGURE="true"

  # Refresh parsed backend details after write/paste
  parse_backend
}

# ===============================
# Step 1: Azure login & provider check
# ===============================
if [[ "${DO_PRECHECKS}" == "true" ]]; then
  echo "Checking Azure CLI login..."
  if ! az account show >/dev/null 2>&1; then
    az login >/dev/null
  fi
  TENANT_ID=$(az account show --query tenantId -o tsv)
  SUBSCRIPTION_ID=$(az account show --query id -o tsv)
  SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
  echo "Tenant: $TENANT_ID"
  echo "Subscription: $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"
  echo

  # Make subscription/tenant explicit for the AzureRM provider
  export ARM_TENANT_ID="$TENANT_ID"
  export ARM_SUBSCRIPTION_ID="$SUBSCRIPTION_ID"
  export ARM_USE_AZUREAD=true
  export ARM_USE_OIDC=false

  echo "Ensuring Microsoft.Storage provider is registered..."
  az provider register --namespace Microsoft.Storage >/dev/null || true
  for _ in {1..15}; do
    st=$(az provider show --namespace Microsoft.Storage --query registrationState -o tsv)
    [[ "$st" == "Registered" ]] && break
    echo "  Checking registrationState=$st"
    sleep 2
  done
  echo "Provider ready."
  echo
fi

# ===============================
# Step 2: Optional reset (cleanup local TF files)
# ===============================
if [[ "$RESET" == "true" ]]; then
  echo "Resetting local Terraform artifacts..."
  rm -rf "$TF_DIR/.terraform" || true
  rm -f  "$TF_DIR/.terraform.lock.hcl" || true
  # rm -rf "$PLAN_DIR" || true
  RECONFIGURE="true"   # ensure init reconfigures after reset
  echo "Local artifacts cleaned."
  echo
fi

# ===============================
# Step 3: Parse backend configuration
# ===============================
parse_backend

# ===============================
# Step 4: Optional terraform destroy
# ===============================
if [[ "$DO_DESTROY" == "true" ]]; then
  echo "Running terraform destroy..."
  if [[ -n "$BK_RG" && -n "$BK_SA" ]] && rg_exists "$BK_RG"; then
    build_backend_flags
    tf init -reconfigure ${UPGRADE:+-upgrade} "${BACKEND_FLAGS[@]}"
    tf destroy
    echo "Destroy complete."
  else
    echo "Skipping destroy — backend RG not found or backend.hcl incomplete."
  fi
  echo
fi

# ===============================
# Step 5: Optional RG deletion (nuke)
# ===============================
if [[ -z "$NUKE_RG" && -n "$BK_RG" ]]; then
  NUKE_RG="$BK_RG"
fi
if [[ -n "$NUKE_RG" ]]; then
  if rg_exists "$NUKE_RG"; then
    echo "Deleting resource group '$NUKE_RG'..."
    az group delete -n "$NUKE_RG" --yes --no-wait
    wait_rg_deleted "$NUKE_RG" 30 5
    RECONFIGURE="true"   # backend is gone; force reconfigure on next init
  else
    echo "RG '$NUKE_RG' not found — nothing to delete."
  fi
  echo
fi

# ===============================
# Stop after cleanup, if requested
# ===============================
if [[ "$EXIT_AFTER_CLEANUP" == "true" ]]; then
  echo "Requested to exit after cleanup. No deployment will be performed."
  exit 0
fi


# ===============================
# Step 6: Backend creation (if missing or CREATE_BACKEND requested)
# ===============================
if [[ -n "$BK_RG" && -n "$BK_SA" ]]; then
  # backend.hcl exists but RG missing ⇒ create backend using provided or fallback values
  if ! rg_exists "$BK_RG"; then
    echo "Backend RG '$BK_RG' does not exist — creating it now..."
    create_backend "${RESOURCE_GROUP:-$BK_RG}" "$LOCATION" "${STACCOUNT:-$BK_SA}" "${CONTAINER:-${BK_CT:-$CONTAINER}}" "${BK_KEY:-$STATE_KEY}"
  fi
else
  # No usable backend info; create if requested
  if [[ "$CREATE_BACKEND" == "true" ]]; then
    create_backend "$RESOURCE_GROUP" "$LOCATION" "$STACCOUNT" "$CONTAINER" "$STATE_KEY"
  fi
fi

# ===============================
# Step 7: Terraform workflow (init → validate → plan → apply → output)
# ===============================
build_backend_flags

INIT_FLAGS=()
# Prefer migrate-state when explicitly requested (e.g., moving existing state)
if [[ "$MIGRATE_STATE" == "true" ]]; then
  INIT_FLAGS+=(-migrate-state)
  [[ "$UPGRADE" == "true" ]] && INIT_FLAGS+=(-upgrade)
else
  # Use -reconfigure if backend changed or we're told to reconfigure
  [[ "$BACKEND_CHANGED" == "true" || "$RECONFIGURE" == "true" ]] && INIT_FLAGS+=(-reconfigure)
  [[ "$UPGRADE" == "true" ]] && INIT_FLAGS+=(-upgrade)
fi

echo "Initializing Terraform..."
tf init "${INIT_FLAGS[@]}" "${BACKEND_FLAGS[@]}"

echo "Formatting Terraform files..."
tf fmt -check || tf fmt -write=true

echo "Validating Terraform configuration..."
tf validate

# Create plan folder (filesystem) and define plan file path RELATIVE to TF_DIR
mkdir -p "$PLAN_DIR"
PLAN_FILE_REL="tfplans/$(ts)-${LABEL}.tfplan"

echo "Generating plan file: $TF_DIR/$PLAN_FILE_REL"
tf plan -out="$PLAN_FILE_REL"

# Apply using the relative path (because -chdir is in effect)
if [[ "$AUTO_APPROVE" == "true" ]]; then
  echo "Applying Terraform plan automatically..."
  tf apply -auto-approve "$PLAN_FILE_REL"
else
  echo "Applying Terraform plan (interactive mode)..."
  tf apply "$PLAN_FILE_REL"
fi

# Print outputs from Terraform folder
echo
echo "Terraform outputs:"
set +e
tf output
TF_OUTPUT_RC=$?
set -e
if [[ $TF_OUTPUT_RC -ne 0 ]]; then
  echo "(No outputs found or output command failed.)"
fi

echo
echo "Terraform run complete."
echo "Azure resources (for reference) → az resource list -o table"