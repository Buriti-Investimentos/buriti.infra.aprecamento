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
# fora do Terraform (scripts/subir-segredos.sh — README, Passo 6) para não vazarem
# no state; os jobs referenciam por URI (compute.tf). Quem seta precisa da role
# "Key Vault Secrets Officer" no KV (RBAC).
resource "azurerm_key_vault" "this" {
  name                       = "kv-${substr(replace(local.name, "-", ""), 0, 20)}"
  resource_group_name        = azurerm_resource_group.this.name
  location                   = azurerm_resource_group.this.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true

  # Sem isto o cofre nasce com 90 dias de soft-delete: um `destroy` seguido de
  # `apply` falha porque o NOME fica reservado pelo cofre apagado, e a mensagem
  # nao diz isso. 7 e o minimo permitido, e este ambiente e recriavel.
  # Em prod, subir para 90 e ligar purge_protection quando o cofre passar a
  # guardar segredo que nao pode ser perdido.
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
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
provider "azurerm" {
  alias = "acr_tenant"
  subscription_id = var.acr_tenant_subscription_id == "" ? var.subscription_id : var.acr_tenant_subscription_id
  tenant_id       = var.acr_tenant_id == "" ? data.azurerm_client_config.current.tenant_id : var.acr_tenant_id
  features {}
}

data "azurerm_container_registry" "acr" {
  count               = var.acr_name != "" ? 1 : 0
  provider            = azurerm.acr_tenant
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
  count                = var.acr_name != "" && var.acr_tenant_id != "" ? 0 : 1
  provider             = azurerm
  scope                = local.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# ACR cross-tenant: o Client Secret NAO entra em `variable` -- segredo em
# variable vira texto puro no state. Ele e' gravado a mao, uma vez:
#   ./scripts/subir-segredos.sh    (grava e CONFERE os tres segredos do cofre)
#
# ⚠️ DOIS RECURSOS SAIRAM DAQUI EM 25/08/2026, e cada um tinha um motivo.
#
# `azurerm_key_vault_secret.acr_client_id` -- gravava no cofre justamente o que
# NAO e' segredo (o client id ja viaja em texto claro no app setting e no
# tfvars) e ninguem lia de volta. Pior: era a unica escrita de DATA PLANE do
# repositorio inteiro, num cofre RBAC puro, e nenhum role assignment daqui
# concede papel de dados a quem roda o terraform -- Owner de subscription NAO
# cobre (`az role definition list --name Owner` devolve `dataActions: []`). O
# apply tomaria 403 no meio.
#
# `azurerm_role_assignment.kv_acr_secret_reader` -- era argumento por argumento
# identico ao `kv_secrets_user` (acima): mesmo escopo, mesma role
# "Key Vault Secrets User", mesmo principal. Nenhum dos dois fixa `name`, entao
# saem dois GUIDs distintos para a MESMA tripla e o ARM devolve 409
# `RoleAssignmentExists`. O provider azurerm 4.79 nao tolera esse erro (a string
# nao existe no binario dele, enquanto `RoleAssignmentDoesNotExist` existe): o
# 409 sobe cru e derruba o apply. O `kv_secrets_user` ja concede exatamente essa
# role, a esse principal, nesse cofre, em todos os cenarios.
