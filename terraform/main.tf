locals {
  name_prefix = "${var.project}-${var.env}"
}

# 1) Resource Group
resource "azurerm_resource_group" "rg_civicpulse_state" {
  name     = "rg-${local.name_prefix}"
  location = var.location
}

# 2) Storage Account (for raw data and a container for blobs)
resource "random_string" "st" {
  length  = 6
  upper   = false
  lower   = true
  numeric = true
  special = false
}

resource "azurerm_storage_account" "st" {
  # e.g., stcivicpulsedevabc123  (<= 24 chars, lowercase letters/numbers only)
  name                            = "st${replace(local.name_prefix, "-", "")}${random_string.st.result}"
  resource_group_name             = azurerm_resource_group.rg_civicpulse_state.name
  location                        = azurerm_resource_group.rg_civicpulse_state.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  allow_nested_items_to_be_public = false
}

resource "azurerm_storage_container" "raw" {
  name                  = "raw"
  storage_account_id    = azurerm_storage_account.st.id
  container_access_type = "private"
}


# 3) Virtual Network + Subnets
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${local.name_prefix}"
  address_space       = [var.vnet_cidr]
  location            = azurerm_resource_group.rg_civicpulse_state.location
  resource_group_name = azurerm_resource_group.rg_civicpulse_state.name
}

# Subnet delegated to PG Flexible Server
resource "azurerm_subnet" "snet_pg" {
  name                 = "snet-pg"
  resource_group_name  = azurerm_resource_group.rg_civicpulse_state.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.subnet_pg]

  delegation {
    name = "pg-delegation"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Subnet for Private Endpoints (network policies must be disabled)
resource "azurerm_subnet" "snet_pe" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.rg_civicpulse_state.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.subnet_pe]

  # v4 syntax:
  private_endpoint_network_policies = "Disabled"
  # (optional, only if you host Private Link Services in this subnet)
  # private_link_service_network_policies = "Disabled"
}


# 4) Private DNS for Postgres

# Postgres flexible server private DNS zone
resource "azurerm_private_dns_zone" "pg" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.rg_civicpulse_state.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "pg_link" {
  name                  = "pg-dns-link"
  resource_group_name   = azurerm_resource_group.rg_civicpulse_state.name
  private_dns_zone_name = azurerm_private_dns_zone.pg.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}


# 5) PostgreSQL Flexible Server

resource "azurerm_postgresql_flexible_server" "pg" {
  name                = "pg-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.rg_civicpulse_state.name
  location            = azurerm_resource_group.rg_civicpulse_state.location
  zone                = "1"
  lifecycle { ignore_changes = [zone] }
  sku_name = "GP_Standard_D2s_v3" #B_Standard_B1ms
  version  = "16"

  administrator_login    = var.pg_admin_user
  administrator_password = var.pg_admin_pwd
  storage_mb             = 32768

  # Private access
  # delegated_subnet_id           = azurerm_subnet.snet_pg.id
  # private_dns_zone_id           = azurerm_private_dns_zone.pg.id
  public_network_access_enabled = true

  authentication {
    active_directory_auth_enabled = false
    password_auth_enabled         = true # allows local Power BI while still keeping private path for ADF
  }
}

# Dynamic rule for current client IP
data "http" "client_ip" {
  url             = "https://api.ipify.org?format=text"
  request_headers = { Accept = "text/plain" }
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_client" {
  name             = "allow-current-ip"
  server_id        = azurerm_postgresql_flexible_server.pg.id
  start_ip_address = trimspace(data.http.client_ip.response_body)
  end_ip_address   = trimspace(data.http.client_ip.response_body)
}


resource "azurerm_postgresql_flexible_server_database" "db" {
  name      = "civicpulse_311"
  server_id = azurerm_postgresql_flexible_server.pg.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}


# 6) Data Factory
resource "azurerm_data_factory" "adf_civicpulse" {
  name                            = "adf-${local.name_prefix}"
  location                        = azurerm_resource_group.rg_civicpulse_state.location
  resource_group_name             = azurerm_resource_group.rg_civicpulse_state.name
  managed_virtual_network_enabled = true
  public_network_enabled          = true
}

# 7) Private Endpoint for Blob (Storage)
# Private DNS for blob
resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.rg_civicpulse_state.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob_link" {
  name                  = "blob-dns-link"
  resource_group_name   = azurerm_resource_group.rg_civicpulse_state.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

# Private Endpoint to Storage (Blob subresource)
resource "azurerm_private_endpoint" "pe_blob" {
  name                = "pe-blob-${local.name_prefix}"
  location            = azurerm_resource_group.rg_civicpulse_state.location
  resource_group_name = azurerm_resource_group.rg_civicpulse_state.name
  subnet_id           = azurerm_subnet.snet_pe.id

  private_service_connection {
    name                           = "pe-blob-conn"
    private_connection_resource_id = azurerm_storage_account.st.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  # Auto-create the DNS zone group entry
  private_dns_zone_group {
    name                 = "blob-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }
}

# 8) ADF Managed VNet + Managed Private Endpoints: This lets ADF reach private Storage + Postgres without public egress.

# MPE to PostgreSQL Flexible Server
# resource "azurerm_data_factory_managed_private_endpoint" "mpe_pg" {
#  name               = "mpe-postgres"
#  data_factory_id    = azurerm_data_factory.adf_civicpulse.id
#  target_resource_id = azurerm_postgresql_flexible_server.pg.id
#  subresource_name   = "postgresqlServer"
#}

# MPE to Storage (Blob)
resource "azurerm_data_factory_managed_private_endpoint" "mpe_blob" {
  name               = "mpe-blob"
  data_factory_id    = azurerm_data_factory.adf_civicpulse.id
  target_resource_id = azurerm_storage_account.st.id
  subresource_name   = "blob"
}
