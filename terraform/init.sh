#!/bin/bash

TF_STORAGE_ACCOUNT=$(az storage account list --query "[0].name" -o tsv)
TF_RESOURCE_GROUP=$(az storage account list --query "[0].resourceGroup" -o tsv)
ACCESS_KEY=$(az storage account keys list \
  --account-name "$TF_STORAGE_ACCOUNT" \
  --resource-group "$TF_RESOURCE_GROUP" \
  --query "[0].value" -o tsv)

terraform init -upgrade -reconfigure \
  -backend-config=backend.hcl \
  -backend-config="access_key=$ACCESS_KEY"