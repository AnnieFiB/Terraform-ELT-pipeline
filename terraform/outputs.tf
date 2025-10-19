
output "storage_account_name" {
  value = azurerm_storage_account.st.name
}

output "raw_container" {
  value = azurerm_storage_container.raw.name
}

output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.pg.fqdn
}

output "database" {
  value = azurerm_postgresql_flexible_server_database.db.name
}

output "data_factory_name" {
  value = azurerm_data_factory.adf_civicpulse.name
}



















