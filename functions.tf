# Compute — Azure Functions + FILAS em 3 etapas (Pacote 12-R).
#
# A arquitetura que o Matheus explicou ao Nicolas e ao Felipe na call da
# calculadora: subir "milhares de Azure Functions em paralelo" sem "estourar o
# limite de conexoes no banco de voces". Dai as tres etapas:
#
#   (gatilho)            leituras          lotes            resultados
#   timer 21h  ─┐                                                        ┌─ SQL
#               ├─► agendador ─► leitor ─► calculadora ─► gravador ──────┘
#   HTTP       ─┘                ETAPA 1    ETAPA 2        ETAPA 3
#                                1 conexao  0 conexoes     1 conexao
#
# O `compute.tf` anterior (2 Container App Jobs) foi arquivado em
# docs/superseded/ — ele era coeso, mas NAO era a arquitetura combinada.
#
# DUAS Function Apps, UMA imagem (paridade — licao do worker dual-tier do OCR):
#
#   func-...-io    agendador + leitor + gravador + backfill   COM credencial SQL
#   func-...-calc  calculadora                                SEM credencial SQL
#
# A etapa 2 nao "promete" nao tocar no banco: ela roda onde as variaveis de
# conexao nao existem. Garantia estrutural, nao disciplina de codigo.

# ---------------------------------------------------------------------------
# Storage: runtime do host + as 3 filas + os blobs do claim-check
# ---------------------------------------------------------------------------
# Sem chave compartilhada: tudo por managed identity, igual ao resto da casa.
resource "azurerm_storage_account" "func" {
  name                            = "st${substr(replace(local.name, "-", ""), 0, 20)}"
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  tags                            = local.tags
}

# As 3 filas da esteira + as filas POISON.
#
# A poison o runtime cria sozinho na primeira mensagem envenenada — declarar
# aqui e de proposito: ela passa a existir desde o dia 1, da para olhar no
# portal antes de acontecer problema, e o alerta de mensagem-envenenada
# (alerts.tf) tem o que monitorar. Era o requisito do Felipe: "nao posso perder
# esses jobs" (hoje ele usa Redis como DLQ no ETL).
locals {
  filas = ["leituras", "lotes", "resultados"]
}

resource "azurerm_storage_queue" "esteira" {
  for_each           = toset(concat(local.filas, [for f in local.filas : "${f}-poison"]))
  name               = each.value
  storage_account_id = azurerm_storage_account.func.id
}

# Claim-check: mensagem de fila tem teto de 64 KB e o lote de um fundo grande
# passa disso. O payload vai para o blob; a fila leva so o ponteiro.
resource "azurerm_storage_container" "lotes" {
  name                  = "lotes"
  storage_account_id    = azurerm_storage_account.func.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "resultados" {
  name                  = "resultados"
  storage_account_id    = azurerm_storage_account.func.id
  container_access_type = "private"
}

# Papeis da identidade sobre o storage. Blob Data OWNER (nao Contributor): o
# host do Functions precisa gerenciar leases de blob para o singleton/lock.
resource "azurerm_role_assignment" "st_blob" {
  scope                = azurerm_storage_account.func.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azurerm_role_assignment" "st_queue" {
  scope                = azurerm_storage_account.func.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# O host guarda estado proprio em Tables mesmo quando o codigo nao usa.
resource "azurerm_role_assignment" "st_table" {
  scope                = azurerm_storage_account.func.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# ---------------------------------------------------------------------------
# Plano: Elastic Premium
# ---------------------------------------------------------------------------
# Por que NAO Consumption/Flex (que seria ~US$130/mes mais barato): a camada de
# conexao usa pyodbc + "ODBC Driver 18 for SQL Server", que e pacote de SISTEMA.
# Plano gerenciado so aceita wheels Python -> exigiria trocar o driver e perder a
# autenticacao AAD sem senha, que e o padrao ja provado no ETL. Premium tambem e
# o unico que entra na VNet, caso o SQL esteja atras de private endpoint.
resource "azurerm_service_plan" "func" {
  name                         = "asp-${local.name}"
  resource_group_name          = azurerm_resource_group.this.name
  location                     = azurerm_resource_group.this.location
  os_type                      = "Linux"
  sku_name                     = var.functions_sku
  maximum_elastic_worker_count = var.functions_max_workers
  tags                         = local.tags
}

locals {
  # Conexao do host com o storage, por identidade (sem connection string).
  # `storage_uses_managed_identity = true` ja faz o provider escrever
  # AzureWebJobsStorage__accountName — NAO repetir as URIs aqui, senao as duas
  # formas de configurar a mesma conexao brigam. So o que falta: dizer QUAL
  # identidade usar (a user-assigned nao e descoberta sozinha).
  app_settings_storage = {
    "AzureWebJobsStorage__credential" = "managedidentity"
    "AzureWebJobsStorage__clientId"   = azurerm_user_assigned_identity.this.client_id

    # A conexao "FILAS" que os bindings do function_app.py referenciam, e o
    # blob do claim-check (claim_check.py le FILAS__blobServiceUri).
    "FILAS__queueServiceUri" = azurerm_storage_account.func.primary_queue_endpoint
    "FILAS__blobServiceUri"  = azurerm_storage_account.func.primary_blob_endpoint
    "FILAS__credential"      = "managedidentity"
    "FILAS__clientId"        = azurerm_user_assigned_identity.this.client_id
  }

  app_settings_comuns = merge(local.app_settings_storage, {
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.this.connection_string
    "AZURE_CLIENT_ID"                       = azurerm_user_assigned_identity.this.client_id
    "APP_ENV"                               = var.environment
    "TZ"                                    = var.timezone
    "FUNCTIONS_WORKER_RUNTIME"              = "python"
  })

  # Conexao com o SQL — SO na app "-io". Host/porta/base nao sao segredo
  # (doc 12 §2.1); em dev, usuario/senha vem do Key Vault por referencia.
  app_settings_sql = merge(
    {
      "SQL_SERVER_HOST" = var.sql_server_host
      "SQL_SERVER_PORT" = tostring(var.sql_server_port)
      "SQL_SERVER_DB"   = var.sql_server_db
      "CALC_POOL_SIZE"  = tostring(var.calc_pool_size)
    },
    var.sql_auth_enabled ? {
      "SQL_SERVER_USER" = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.this.vault_uri}secrets/sql-server-user)"
      "SQL_SERVER_PWD"  = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.this.vault_uri}secrets/sql-server-pwd)"
    } : {}
  )

  # Credenciais do registry para ACR cross-tenant
  app_settings_acr_registry = var.acr_tenant_id != "" ? {
    "DOCKER_REGISTRY_SERVER_USERNAME" = var.acr_client_id
    "DOCKER_REGISTRY_SERVER_PASSWORD" = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.this.vault_uri}secrets/acr-client-secret)"
    "DOCKER_REGISTRY_SERVER_URL"      = "https://${local.acr_login_server}"
  } : {}
}

# ---------------------------------------------------------------------------
# App "-io": etapas 1 e 3 + os dois gatilhos. UNICA que fala com o banco.
# ---------------------------------------------------------------------------
resource "azurerm_linux_function_app" "io" {
  name                          = "func-${local.name}-io"
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  service_plan_id               = azurerm_service_plan.func.id
  storage_account_name          = azurerm_storage_account.func.name
  storage_uses_managed_identity = true
  https_only                    = true
  virtual_network_subnet_id     = var.functions_subnet_id != "" ? var.functions_subnet_id : null
  tags                          = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  site_config {
    # Teto DURO de instancias: as etapas 1 e 3 sao "1 conexao cada". Com 1
    # instancia + batchSize 1 (app setting abaixo), o banco ve UMA transacao por
    # vez, por construcao.
    app_scale_limit                               = 1
    elastic_instance_minimum                      = 1
    vnet_route_all_enabled                        = var.functions_subnet_id != ""
    container_registry_use_managed_identity       = var.acr_tenant_id == "" ? true : false
    container_registry_managed_identity_client_id = var.acr_tenant_id == "" ? azurerm_user_assigned_identity.this.client_id : null

    application_stack {
      docker {
        registry_url = "https://${local.acr_login_server}"
        image_name   = var.image_name
        image_tag    = var.image_tag
      }
    }
  }

  app_settings = merge(local.app_settings_comuns, local.app_settings_sql, local.app_settings_acr_registry, {
    # Cron do diario, lido pelo timer_trigger via "%CRON_DIARIO%".
    "CRON_DIARIO" = var.cron_expression

    # Esta app NAO calcula: a etapa 2 e da outra app.
    "AzureWebJobs.calculadora.Disabled" = "true"

    # Serializa o consumo de fila: uma mensagem por vez, uma transacao por vez.
    "AzureFunctionsJobHost__extensions__queues__batchSize"         = "1"
    "AzureFunctionsJobHost__extensions__queues__newBatchThreshold" = "0"
  })

  depends_on = [
    azurerm_role_assignment.acr_pull[0],
    azurerm_role_assignment.kv_secrets_user,
    azurerm_role_assignment.st_blob,
    azurerm_role_assignment.st_queue,
    azurerm_role_assignment.st_table,
  ]

  lifecycle {
    # O CI atualiza a tag da imagem; evita rollback acidental no apply
    # (bug visto no OCR).
    ignore_changes = [site_config[0].application_stack[0].docker[0].image_tag]
  }
}

# ---------------------------------------------------------------------------
# App "-calc": ETAPA 2. Escala à vontade e NAO recebe credencial de banco.
# ---------------------------------------------------------------------------
resource "azurerm_linux_function_app" "calc" {
  name                          = "func-${local.name}-calc"
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  service_plan_id               = azurerm_service_plan.func.id
  storage_account_name          = azurerm_storage_account.func.name
  storage_uses_managed_identity = true
  https_only                    = true
  tags                          = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  site_config {
    app_scale_limit                               = var.calc_scale_limit
    container_registry_use_managed_identity       = var.acr_tenant_id == "" ? true : false
    container_registry_managed_identity_client_id = var.acr_tenant_id == "" ? azurerm_user_assigned_identity.this.client_id : null

    application_stack {
      docker {
        registry_url = "https://${local.acr_login_server}"
        image_name   = var.image_name
        image_tag    = var.image_tag
      }
    }
  }

  # Note o que NAO esta aqui: SQL_SERVER_HOST, SQL_SERVER_DB, credencial nenhuma.
  # Mesmo um bug que tentasse abrir conexao nao teria para onde ir.
  app_settings = merge(local.app_settings_comuns, local.app_settings_acr_registry, {
    "AzureWebJobs.agendador.Disabled" = "true"
    "AzureWebJobs.leitor.Disabled"    = "true"
    "AzureWebJobs.gravador.Disabled"  = "true"
    "AzureWebJobs.backfill.Disabled"  = "true"
  })

  depends_on = [
    azurerm_role_assignment.acr_pull[0],
    azurerm_role_assignment.st_blob,
    azurerm_role_assignment.st_queue,
    azurerm_role_assignment.st_table,
  ]

  lifecycle {
    ignore_changes = [site_config[0].application_stack[0].docker[0].image_tag]
  }
}
