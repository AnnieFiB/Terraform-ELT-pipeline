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
  url             = "https://api.ipify.org?format=text"
  request_headers = { Accept = "text/plain" }
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_client" {
  name             = "allow-current-ip"
  server_id        = azurerm_postgresql_flexible_server.pg.id
  start_ip_address = trimspace(data.http.client_ip.response_body)
  end_ip_address   = trimspace(data.http.client_ip.response_body)
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.pg.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
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

#================================
# ADF Linked Services
#================================

resource "azurerm_data_factory_linked_service_azure_blob_storage" "adf_civicpulse_lsblob" {
  name                     = "DLLS_Blob"
  data_factory_id          = azurerm_data_factory.adf_civicpulse.id
  # service_endpoint         = azurerm_storage_account.st.primary_blob_endpoint
  connection_string        = azurerm_storage_account.st.primary_connection_string
  use_managed_identity     = true

  description = "Linked Service to ${azurerm_storage_container.raw.name} container"

}

resource "azurerm_data_factory_linked_service_postgresql" "adf_civicpulse_lspg" {
  name              = "DDLS_PostgresDB"
  data_factory_id   = azurerm_data_factory.adf_civicpulse.id
  # connection_string = "host=${azurerm_postgresql_flexible_server.pg.fqdn} port=5432 dbname=${azurerm_postgresql_flexible_server_database.db.name} user=${var.pg_admin_user} password=${var.pg_admin_pwd} sslmode=require"
  connection_string = "host=${var.pg_host};port=5432;database=${var.pg_db};user=${var.pg_admin_user};password=${var.pg_admin_pwd};sslmode=Require;"

  description              = "Linked Service to Postgres ${azurerm_postgresql_flexible_server.pg.name} warehouse for CivicPulse (stg.api_311_flat, dwh.fact_311_requests)"
}

#================================
# ADF Dataset
#================================

resource "azurerm_data_factory_dataset_parquet" "ds_parquet_311" {
  name                = "ds_blob_311_parquet"
  data_factory_id     = azurerm_data_factory.adf_civicpulse.id
  linked_service_name = azurerm_data_factory_linked_service_azure_blob_storage.adf_civicpulse_lsblob.name

  azure_blob_storage_location {
    container = azurerm_storage_container.raw.name
    path     = "api/311/source=nyc"
    filename = "*.parquet"
  }

  description       = "NYC 311 incremental Parquet dropped by Astronomer Airflow"
  folder      = "staging"
  parameters = {
    ingest_date = ""
  }

  schema_column {
    name = "unique_key"
    type = "String"
  }
  schema_column {
    name = "created_date"
    type = "String"
  }
  schema_column {
    name = "complaint_type"
    type = "String"
  }
}


# sink Dataset
resource "azurerm_data_factory_dataset_postgresql" "ds_pg_311_staging" {
  name                = "ds_pg_311_linebuffer"
  data_factory_id     = azurerm_data_factory.adf_civicpulse.id
  linked_service_name = azurerm_data_factory_linked_service_postgresql.adf_civicpulse_lspg.name

  table_name  = "stg.api_311_flat"
  description = "Append-only landing table for raw NYC 311 requests before DWH upsert"
  folder              = "staging"
}

#================================
# ADF Pipeline
#================================

resource "azurerm_data_factory_pipeline" "pl_civicpulse" {
  name            = "PL_CivicPulse_311_Ingest"
  data_factory_id = azurerm_data_factory.adf_civicpulse.id
  description     = "ADF pipeline: Copy NYC 311 Parquet → Postgres staging → Upsert into DWH"

  parameters = {
    ingest_date = ""
  }

  activities_json = jsonencode([
    {
      "name"      = "CopyParquetToStaging",
      "type"      = "Copy",
      "dependsOn" = [],
      "policy" = {
        "timeout"                = "0.12:00:00",
        "retry"                  = 1,
        "retryIntervalInSeconds" = 30
      },
      "typeProperties" = {
        "source" = {
          "type" = "ParquetSource",
          "additionalColumns" = [
            {
              "name"  = "src_file",
              "value" = "@{concat('ingest_date=', pipeline().parameters.ingest_date)}"
            }
          ],
          "storeSettings" = {
            "type"      = "AzureBlobStorageReadSettings",
            "recursive" = true,
            "wildcardFolderPath" = {
              "value" = "@{concat('api/311/source=nyc/ingest_date=', pipeline().parameters.ingest_date, '/')}",
              "type"  = "Expression"
            },
            "wildcardFileName" = "*.parquet"
          },
          "formatSettings" = {
            "type" = "ParquetReadSettings"
          }
        },
        "sink" = {
          "type"              = "AzurePostgreSqlSink",
          "writeBatchSize"    = 2000000,
          "writeBatchTimeout" = "00:30:00",
          "writeMethod"       = "BulkInsert"
        },
        "enableStaging" = false,
        "translator" = {
          "type"           = "TabularTranslator",
          "typeConversion" = true,
          "typeConversionSettings" = {
            "allowDataTruncation"  = true,
            "treatBooleanAsNumber" = false
          },
          "mappings" = [
            {
              "source" = { "name" = "src_file", "type" = "String" },
              "sink"   = { "name" = "src_file", "type" = "String" }
            }
          ]
        }
      },
      "inputs" = [
        {
          "referenceName" = azurerm_data_factory_dataset_parquet.ds_parquet_311.name,
          "type"          = "DatasetReference"
        }
      ],
      "outputs" = [
        {
          "referenceName" = azurerm_data_factory_dataset_postgresql.ds_pg_311_staging.name,
          "type"          = "DatasetReference"
        }
      ]
    },
    {
      "name"        = "Upsert_to_DWH",
      "description" = "Run SQL merge of staging rows into dwh.fact_311_requests",
      "type"        = "Script",
      "dependsOn" = [
        {
          "activity"             = "CopyParquetToStaging",
          "dependencyConditions" = ["Succeeded"]
        }
      ],
      "policy" = {
        "timeout"                = "0.12:00:00",
        "retry"                  = 0,
        "retryIntervalInSeconds" = 30
      },
      "linkedServiceName" = {
        "referenceName" = azurerm_data_factory_linked_service_postgresql.adf_civicpulse_lspg.name,
        "type"          = "LinkedServiceReference"
      },
      "typeProperties" = {
        "scripts" = [
          {
            "type" = "Query",
            "text" = "SELECT dwh.run_311_transform(interval '1 day');"
          }
        ],
        "scriptBlockExecutionTimeout" = "02:00:00"
      }
    }
  ])
}


#================================
# ADF Pipeline Trigger
#================================

resource "azurerm_data_factory_trigger_blob_event" "trg_blob_ingest" {
  name            = "trg_blob_ingest_311"
  data_factory_id = azurerm_data_factory.adf_civicpulse.id
  description     = "Trigger when new NYC 311 Parquet file is added"

  events                = ["Microsoft.Storage.BlobCreated"]
  storage_account_id    = azurerm_storage_account.st.id
  blob_path_begins_with = "api/311/source=nyc/"
  blob_path_ends_with   = ".parquet"
  ignore_empty_blobs    = true
  activated             = false

  pipeline {
    name = azurerm_data_factory_pipeline.pl_civicpulse.name
    parameters = {
      ingest_date = "@{formatDateTime(utcNow(),'yyyy-MM-dd')}"
    }
  }
}



resource "azurerm_data_factory_trigger_schedule" "trg_daily_ingest" {
  name            = "trg_daily_ingest_311"
  data_factory_id = azurerm_data_factory.adf_civicpulse.id
  description     = "Runs the NYC 311 ingestion pipeline daily at 18:00 UTC"

  pipeline {
    name = azurerm_data_factory_pipeline.pl_civicpulse.name
    parameters = {
      ingest_date = "@{formatDateTime(utcNow(),'yyyy-MM-dd')}"
    }
  }

  frequency  = "Day"                        # Day / Hour / Minute / Month / etc.
  interval   = 1                            # every 1 Day
  start_time = "2025-11-02T18:00:00Z"       # UTC ISO8601 start
  time_zone  = "UTC"                        # timezone string
  activated  = true                         # automatically "Started"

   schedule {
    hours   = [18]
    minutes = [0]
  }
}
