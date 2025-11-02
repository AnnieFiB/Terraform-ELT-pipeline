
variable "project" {
  type    = string
  default = "civicpulse"
}

variable "env" {
  type    = string
  default = "dev"
}

variable "location" {
  type    = string
  default = "uksouth"
  description = "Azure region for all resources."
}

variable "resource_group_name" {
  type      = string
  description = "Azure backend rg name"
}

variable "storage_account_name" {
  type      = string
  description = "Name of the Storage Account that holds tfstate."
}

variable "container_name" {
  type      = string
  description = "Name of the blob container that holds Terraform state."
}

variable "raw_container" {
  type      = string
  description = "Name of the raw ingest container where NYC 311 parquet lands (e.g. 'raw')."
}

variable "pg_admin_user" {
  description = "Username for ADF to connect to Postgres."
  type = string
}

variable "pg_admin_pwd" {
  description = "Password for ADF to connect to Postgres."
  type      = string
  sensitive = true
}

variable "pg_host" {
  description = "Postgres fully-qualified host"
  type        = string
}

variable "pg_db" {
  description = "Database name for civicpulse_311 staging + dwh."
  type      = string
  sensitive = true
}

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID"
}