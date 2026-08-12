data "azurerm_client_config" "current" {}

locals {
  name = "${var.prefix}-${var.environment}"
  tags = merge(var.tags, { ambiente = var.environment })
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = local.tags
}

# --- Observabilidade ---
resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_application_insights" "this" {
  name                = "appi-${local.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "other"
  tags                = local.tags
}

# --- Identidade gerenciada (sem senha: token AAD no SQL, pull no ACR) ---
resource "azurerm_user_assigned_identity" "this" {
  name                = "id-${local.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

# --- Key Vault (segredos que não têm managed identity) ---
# Secrets esperados (doc 12 §5.2): sql-server-user / sql-server-pwd (SÓ dev;
# prod = AAD sem senha). Os VALORES entram
# fora do Terraform (az keyvault secret set — README §Secrets) para não vazarem
# no state; os jobs referenciam por URI (compute.tf). Quem seta precisa da role
# "Key Vault Secrets Officer" no KV (RBAC).
resource "azurerm_key_vault" "this" {
  name                       = "kv-${substr(replace(local.name, "-", ""), 0, 20)}"
  resource_group_name        = azurerm_resource_group.this.name
  location                   = azurerm_resource_group.this.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  tags                       = local.tags
}

resource "azurerm_role_assignment" "kv_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# O Redis dedicado que existia aqui saiu no Pacote 12-R: o fan-out agora e
# feito por Azure Storage Queue (functions.tf), que ja vem com fila poison
# nativa -- resolve o mesmo problema sem os ~US$100/mes do Redis C1.

# --- ACR: reusa o existente (recomendado) se informado ---
data "azurerm_container_registry" "acr" {
  count               = var.acr_name != "" ? 1 : 0
  name                = var.acr_name
  resource_group_name = var.acr_resource_group_name
}

resource "azurerm_container_registry" "acr" {
  count               = var.acr_name == "" ? 1 : 0
  name                = "acr${substr(replace(local.name, "-", ""), 0, 20)}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Basic"
  tags                = local.tags
}

locals {
  acr_login_server = var.acr_name != "" ? data.azurerm_container_registry.acr[0].login_server : azurerm_container_registry.acr[0].login_server
  acr_id           = var.acr_name != "" ? data.azurerm_container_registry.acr[0].id : azurerm_container_registry.acr[0].id
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = local.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}
