# Azure Provider source and version being used

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.7" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
    http    = { source = "hashicorp/http", version = "~> 3.3" }
  }
}

# Configure the Microsoft Azure Provider

provider "azurerm" {
  features {}
  use_cli = true
}
