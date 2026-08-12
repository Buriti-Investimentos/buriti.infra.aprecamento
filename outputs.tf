output "resource_group" {
  value = azurerm_resource_group.this.name
}

output "identity_client_id" {
  description = "Client ID da managed identity (usar no AAD do SQL e no AZURE_CLIENT_ID)."
  value       = azurerm_user_assigned_identity.this.client_id
}

output "identity_principal_id" {
  value = azurerm_user_assigned_identity.this.principal_id
}

output "key_vault_name" {
  description = "Nome real do Key Vault (hífens removidos + truncado — NÃO derive do nome do RG)."
  value       = azurerm_key_vault.this.name
}

output "acr_login_server" {
  value = local.acr_login_server
}

output "app_insights_connection_string" {
  value     = azurerm_application_insights.this.connection_string
  sensitive = true
}

output "function_app_io" {
  description = "App das etapas 1 e 3 (le e grava). Unica com credencial do SQL."
  value       = azurerm_linux_function_app.io.name
}

output "function_app_calc" {
  description = "App da etapa 2 (calculo puro, escala livre, sem acesso a banco)."
  value       = azurerm_linux_function_app.calc.name
}

output "storage_account_filas" {
  description = "Storage das 3 filas + blobs do claim-check (e do runtime do host)."
  value       = azurerm_storage_account.func.name
}

output "url_backfill" {
  description = "POST {de, ate, fundos?} para enfileirar retroativo (exige a function key)."
  value       = "https://${azurerm_linux_function_app.io.default_hostname}/api/backfill"
}
