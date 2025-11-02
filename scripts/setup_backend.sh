#!/usr/bin/env bash
set -eo pipefail

# ============================================================
# setup_backend.sh
#
# This script:
#   1. Reads backend settings from terraform/terraform.tfvars
#   2. Ensures RG, Storage Account, and Container exist
#   3. Sets az CLI context to that subscription
#   4. Runs `terraform init -reconfigure` with AAD auth
#
# NOTE:
#   If `terraform init` still fails with 403/AuthorizationPermissionMismatch,
#   you must assign yourself "Storage Blob Data Contributor" on the Storage
#   Account in Azure Portal (Access control (IAM)).
# ============================================================

# =========================================
# Load required backend values from tfvars
# =========================================
TF_DIR="terraform"
TFVARS_FILE="${TF_DIR}/terraform.tfvars"

if [[ ! -f "$TFVARS_FILE" ]]; then
  echo "ERROR: terraform.tfvars not found in ${TF_DIR}"
  exit 1
fi

SUBSCRIPTION_ID=$(grep -E '^[[:space:]]*subscription_id[[:space:]]*=' "$TFVARS_FILE" \
  | awk -F'=' '{print $2}' | tr -d '[:space:]"')
LOCATION=$(grep -E '^[[:space:]]*location[[:space:]]*=' "$TFVARS_FILE" \
  | awk -F'=' '{print $2}' | tr -d '[:space:]"')
RESOURCE_GROUP=$(grep -E '^[[:space:]]*resource_group_name[[:space:]]*=' "$TFVARS_FILE" \
  | awk -F'=' '{print $2}' | tr -d '[:space:]"')
STACCOUNT=$(grep -E '^[[:space:]]*storage_account_name[[:space:]]*=' "$TFVARS_FILE" \
  | awk -F'=' '{print $2}' | tr -d '[:space:]"')
CONTAINER=$(grep -E '^[[:space:]]*container_name[[:space:]]*=' "$TFVARS_FILE" \
  | awk -F'=' '{print $2}' | tr -d '[:space:]"')

# basic validation
for var in SUBSCRIPTION_ID LOCATION RESOURCE_GROUP STACCOUNT CONTAINER; do
  if [[ -z "${!var}" ]]; then
    echo "ERROR: ${var} missing in terraform.tfvars"
    exit 1
  fi
done

echo "[2/5] Setting Azure CLI subscription context ..."
if ! az account set --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1; then
  echo "ERROR: Cannot select subscription '$SUBSCRIPTION_ID'. Check spelling or access."
  exit 1
fi
echo "    Subscription context set."

echo "[3/5] Ensuring Azure resources exist ..."


# =========================================
# Ensure resource group exists
# =========================================
if az group show --subscription "$SUBSCRIPTION_ID" --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "    Resource group $RESOURCE_GROUP exists."
else
  echo "    Creating resource group $RESOURCE_GROUP ..."
  az group create \
    --subscription "$SUBSCRIPTION_ID" \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    -o none
fi



# =========================================
# Ensure storage account exists
# =========================================
if az storage account show --subscription "$SUBSCRIPTION_ID" -n "$STACCOUNT" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "    Storage account $STACCOUNT exists."
else
  echo "    Creating storage account $STACCOUNT ..."
  az storage account create \
    --subscription "$SUBSCRIPTION_ID" \
    --name "$STACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    -o none
fi
# =========================================
# Ensure blob container exists
# NOTE: az storage container commands are data-plane and don't accept --subscription,
# but we already set the account above in the right subscription.
# =========================================
if az storage container show --account-name "$STACCOUNT" -n "$CONTAINER" >/dev/null 2>&1; then
  echo "    Container $CONTAINER exists."
else
  echo "    Creating container $CONTAINER ..."
  az storage container create \
    --name "$CONTAINER" \
    --account-name "$STACCOUNT" \
    --auth-mode login \
    -o none
fi

# =========================================
# Initialise Terraform backend using AAD auth
# =========================================
echo "[4/5] Initialising Terraform backend ..."
(
  cd "$TF_DIR"
  # '|| true' prevents set -e from killing the script before we can handle the error
  terraform init -reconfigure \
    -backend-config="resource_group_name=${RESOURCE_GROUP}" \
    -backend-config="storage_account_name=${STACCOUNT}" \
    -backend-config="container_name=${CONTAINER}" \
    -backend-config="key=terraform.tfstate" \
    -backend-config="use_azuread_auth=true" || true
  INIT_STATUS=$?
  echo $INIT_STATUS > /tmp/_tfinit_status.$$
)
INIT_STATUS=$(cat /tmp/_tfinit_status.$$)
rm -f /tmp/_tfinit_status.$$


# If init succeeded, we're done.
if [[ $INIT_STATUS -eq 0 ]]; then
  echo "[5/5] Backend ready. You can now run: cd terraform && terraform plan"
  exit 0
fi

# If init failed (403 most likely), print RBAC guidance.
echo ""
echo "Terraform backend init failed with exit code ${INIT_STATUS}."
echo ""
echo "This usually means your current identity does not have data-plane access"
echo "to the storage account '${STACCOUNT}' for blob operations."
echo ""
echo "Fix:"
echo "  1. In Azure Portal:"
echo "     - Open Storage Account: ${STACCOUNT}"
echo "     - Go to 'Access control (IAM)'"
echo "     - Click 'Add role assignment'"
echo "     - Role: Storage Blob Data Contributor"
echo "     - Assign access to: your user account"
echo "     - Scope: This storage account"
echo ""
echo "  2. Wait a short moment for the role assignment to propagate."
echo ""
echo "  3. Re-run:"
echo "     cd terraform && terraform init -reconfigure \\"
echo "       -backend-config=\"resource_group_name=${RESOURCE_GROUP}\" \\"
echo "       -backend-config=\"storage_account_name=${STACCOUNT}\" \\"
echo "       -backend-config=\"container_name=${CONTAINER}\" \\"
echo "       -backend-config=\"key=terraform.tfstate\" \\"
echo "       -backend-config=\"use_azuread_auth=true\""
echo ""
echo "If that still fails with 403 after assigning the role, set RBAC manually in the Azure Portal as above and confirm you're logged in with the same user you granted."
exit $INIT_STATUS