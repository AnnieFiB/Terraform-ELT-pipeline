locals {
  name_prefix = "${var.project}-${var.env}"
}

#=====================
# Resource Group
#=====================
resource "azurerm_resource_group" "rg_civicpulse_state" {
  name     = "rg-${local.name_prefix}"
  location = var.location
}

#=============================
# Storage Account + Container
#=============================
resource "random_string" "st" {
  length  = 6
  upper   = false
  lower   = true
  numeric = true
  special = false
}

resource "azurerm_storage_account" "st" {
  name                            = "st${replace(local.name_prefix, "-", "")}${random_string.st.result}"
  resource_group_name             = azurerm_resource_group.rg_civicpulse_state.name
  location                        = azurerm_resource_group.rg_civicpulse_state.location
  account_tier                    = "Standard"
  account_replication_type        = "GRS"
  allow_nested_items_to_be_public = false
}

resource "azurerm_storage_container" "raw" {
  name                  = "raw"
  storage_account_id    = azurerm_storage_account.st.id
  container_access_type = "private"
}

#=====================
# Data Factory
#=====================
resource "azurerm_data_factory" "adf_civicpulse" {
  name                = "adf-${local.name_prefix}"
  location            = azurerm_resource_group.rg_civicpulse_state.location
  resource_group_name = azurerm_resource_group.rg_civicpulse_state.name
}


#================================
# PostgreSQL Flexible Server + db
#================================
resource "azurerm_postgresql_flexible_server" "pg" {
  name                          = "pg-${local.name_prefix}"
  resource_group_name           = azurerm_resource_group.rg_civicpulse_state.name
  location                      = azurerm_resource_group.rg_civicpulse_state.location
  version                       = "17"
  public_network_access_enabled = true
  administrator_login           = var.pg_admin_user
  administrator_password        = var.pg_admin_pwd
  zone                          = "1"

  storage_mb   = 32768
  storage_tier = "P4"

  sku_name = "GP_Standard_D2s_v3"
  authentication {
    password_auth_enabled = true
  }

}

# Dynamic rule for current client IP
data "http" "client_ip" {
  url  = "https://api.ipify.org?format=text"
  request_headers = { Accept = "text/plain" }
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_client" {
  name             = "allow-current-ip"
  server_id        = azurerm_postgresql_flexible_server.pg.id
  start_ip_address = trimspace(data.http.client_ip.response_body)
  end_ip_address   = trimspace(data.http.client_ip.response_body)
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure_services" {
  name                = "AllowAzureServices"
  server_id          = azurerm_postgresql_flexible_server.pg.id
  start_ip_address    = "0.0.0.0"
  end_ip_address      = "0.0.0.0"
}

resource "azurerm_postgresql_flexible_server_database" "db" {
  name      = "civicpulse_311"
  server_id = azurerm_postgresql_flexible_server.pg.id
  collation = "en_US.utf8"
  charset   = "UTF8"

  # prevent the possibility of accidental data loss
  lifecycle {
    prevent_destroy = true
  }
}
