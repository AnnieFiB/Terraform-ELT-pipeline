#!/usr/bin/env bash
set -euo pipefail

# -------- Directory + file setup --------
TF_DIR="${TF_DIR:-terraform}"          # default folder containing TF files
TFVARS="${TF_DIR}/terraform.tfvars"    # target tfvars file

# -------- Inputs (override via env if desired) --------
LOCATION="${LOCATION:-uksouth}"
RESOURCE_GROUP="${RESOURCE_GROUP:-tf-backend-rg}"
STACCOUNT="${STACCOUNT:-sabackend$RANDOM}"   # must be globally unique, lowercase only
CONTAINER="${CONTAINER:-tfstate}"

# normalize storage account name (must be lowercase alphanumeric)
STACCOUNT="$(echo "$STACCOUNT" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"

# -------- Create backend resources --------
echo " Creating resource group and storage account for Terraform backend..."

echo " Creating resource group and storage account for Terraform backend..."
az group create -n "$RESOURCE_GROUP" -l "$LOCATION" -o none
az storage account create -n "$STACCOUNT" -g "$RESOURCE_GROUP" -l "$LOCATION" --sku Standard_LRS --kind StorageV2 -o none
az storage container create --account-name "$STACCOUNT" --name "$CONTAINER" --auth-mode login -o none

# -------- Update terraform.tfvars idempotently --------
BEGIN_MARK="# BEGIN: backend (auto)"
END_MARK="# END: backend (auto)"
TMP_BLOCK="$(mktemp 2>/dev/null || mktemp -t tmp)"

cat > "$TMP_BLOCK" <<EOF
$BEGIN_MARK
resource_group_name  = "$RESOURCE_GROUP"
storage_account_name = "$STACCOUNT"
container_name       = "$CONTAINER"
location             = "$LOCATION"
$END_MARK
EOF

if [[ -f "$TFVARS" ]]; then
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    BEGIN { skip=0 }
    $0 ~ b { skip=1; next }
    $0 ~ e { skip=0; next }
    skip==0 { print }
  ' "$TFVARS" > "${TFVARS}.tmp"
  cat "$TMP_BLOCK" >> "${TFVARS}.tmp"
  mv "${TFVARS}.tmp" "$TFVARS"
else
  cp "$TMP_BLOCK" "$TFVARS"
fi
rm -f "$TMP_BLOCK"



# -------- Run terraform init with generated backend values --------
echo " Initialising Terraform backend (AAD auth)..."
(
  cd "$TF_DIR"
  terraform init -reconfigure \
    -backend-config="resource_group_name=${RESOURCE_GROUP}" \
    -backend-config="storage_account_name=${STACCOUNT}" \
    -backend-config="container_name=tfstate" \
    -backend-config="key=terraform.tfstate" \
    -backend-config="access_key=$(az storage account keys list --account-name ${STACCOUNT} --query '[0].value' -o tsv)" \
    -backend-config="use_azuread_auth=true"

)


echo "Terraform backend configured successfully for ${STACCOUNT}"
