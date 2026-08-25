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
# O host e o codigo acessam por managed identity (nao ha connection string em
# lugar nenhum). A CHAVE compartilhada da conta, porem, continua existindo: o
# comentario anterior dizia "sem chave compartilhada" e isso nao era verdade --
# `shared_access_key_enabled` fica em variavel, default `true`, porque
# desliga-la em Function App conteinerizada precisa de um teste de subida que
# ainda nao pudemos fazer (sem acesso Azure). Ver README, "O que ainda depende
# de terceiros".
resource "azurerm_storage_account" "func" {
  name                            = "st${substr(replace(local.name, "-", ""), 0, 20)}"
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  shared_access_key_enabled       = var.storage_shared_key_enabled
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
    "FUNCTIONS_WORKER_RUNTIME"              = "python"

    # APP_MODE decide COMO a conexao autentica -- e nao e cosmetico:
    # `config.py:238` registra o token AAD da managed identity SO quando
    # `app_mode == "production"`, e `sqlalchemy_url()` (config.py:176) so omite
    # usuario/senha nesse mesmo caso. Sem esta linha o default do codigo e
    # "development": em prod a app subia sem token E sem senha, e a conexao
    # falhava com erro de credencial. Deriva de `sql_auth_enabled` porque e a
    # MESMA decisao ("AAD sem senha" x "usuario e senha") -- nao do nome do
    # ambiente, senao um dev com AAD ou um prod com senha autentica errado.
    "APP_MODE" = var.sql_auth_enabled ? "development" : "production"

    # Duas coisas diferentes com o mesmo valor: `TZ` e o fuso do SISTEMA
    # (carimbo de log, `date` do container); `CALC_TIMEZONE` e o que o servico
    # de fato le (config.py:151) para decidir a data-alvo do lote. Antes so o
    # primeiro era setado, e a variavel `timezone` do Terraform nao chegava ao
    # calculo -- funcionava por coincidencia, porque o default do codigo e o
    # mesmo "America/Sao_Paulo".
    # TRES coisas diferentes com o mesmo valor, e cada uma governa uma peca:
    #   TZ ................. fuso do SISTEMA (carimbo de log, `date` do container)
    #   CALC_TIMEZONE ...... o que o SERVICO le (config.py:151) para decidir a
    #                        data-alvo do lote
    #   WEBSITE_TIME_ZONE .. o fuso que o RUNTIME do Functions usa para
    #                        interpretar o NCRONTAB do timer_trigger. Sem ele o
    #                        cron e lido em UTC: "0 0 21 * * *" dispararia as
    #                        18h de Brasilia, tres horas antes do combinado --
    #                        e antes do ETL de posicoes do dia.
    # Setar so TZ nao resolve nenhuma das duas ultimas.
    "TZ"                = var.timezone
    "CALC_TIMEZONE"     = var.timezone
    "WEBSITE_TIME_ZONE" = var.timezone
  })

  # Conexao com o SQL — SO na app "-io". Host/porta/base nao sao segredo
  # (doc 12 §2.1); em dev, usuario/senha vem do Key Vault por referencia.
  app_settings_sql = merge(
    {
      "SQL_SERVER_HOST" = var.sql_server_host
      "SQL_SERVER_PORT" = tostring(var.sql_server_port)
      "SQL_SERVER_DB"   = var.sql_server_db
      "CALC_POOL_SIZE"  = tostring(var.calc_pool_size)

      # O default do codigo e "yes", que ACEITA qualquer certificado -- com
      # ODBC 18 a conexao continua cifrada, mas deixa de validar quem esta do
      # outro lado. O Azure SQL apresenta certificado valido para
      # *.database.windows.net (inclusive por private endpoint), entao o certo
      # aqui e "no". Fica em variavel para o Felipe poder relaxar em um
      # cenario de nome que nao casa, sem editar codigo.
      "SQL_TRUST_SERVER_CERTIFICATE" = var.sql_trust_server_certificate
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
  # ⚠️ SEM ESTA LINHA, NENHUMA REFERENCIA DE COFRE RESOLVE -- 25/08/2026.
  # O App Service resolve `@Microsoft.KeyVault(SecretUri=...)` com a identidade
  # SYSTEM-assigned por padrao, e estas apps nao tem uma: so' a user-assigned
  # acima. Quando nao resolve, a Azure entrega o app setting com a STRING CRUA,
  # e o sintoma aparece longe da causa -- erro de credencial no SQL mandando
  # procurar no banco, ou 401 no pull mandando procurar no registry.
  # Medido: 29 de 29 App Services de uma subscription reportam
  # `keyVaultReferenceIdentity = "SystemAssigned"` mesmo com `identity.type`
  # nulo -- nao existe fallback para "adota a unica identidade que houver".
  # A permissao ja esta certa (`kv_secrets_user` da "Key Vault Secrets User" a
  # esta mesma identidade); o que faltava era DIZER a app qual identidade usar.
  key_vault_reference_identity_id = azurerm_user_assigned_identity.this.id

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
  # Mesma razao da app `-io`, acima: sem isto o app setting chega com a string
  # crua. Vale para esta tambem porque a credencial do registry cross-tenant e
  # uma referencia de cofre, e e' ela que autentica o pull da imagem.
  key_vault_reference_identity_id = azurerm_user_assigned_identity.this.id

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
    # A `calc` passou a LER o cofre -- a credencial do registry cross-tenant e
    # uma referencia de Key Vault, como as do SQL na `-io`. Sem esta aresta a
    # app pode nascer antes de a identidade ter permissao de leitura.
    # (`depends_on` nao tem ordem: fica no FIM de proposito, para nao encostar
    # na linha do `acr_pull` -- que o PR #3 tambem edita, e duas edicoes na
    # mesma linha viram conflito de merge na vespera do deploy.)
    azurerm_role_assignment.kv_secrets_user,
  ]

  lifecycle {
    ignore_changes = [site_config[0].application_stack[0].docker[0].image_tag]
  }
}
