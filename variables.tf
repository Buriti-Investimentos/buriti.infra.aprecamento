variable "subscription_id" {
  type        = string
  description = "ID da subscription Azure da Buriti (obrigatório no azurerm 4.x)."
}

variable "environment" {
  type        = string
  description = "Ambiente: dev | hml | prod."
  default     = "dev"
}

variable "location" {
  type        = string
  description = "Região Azure."
  default     = "brazilsouth"
}

variable "prefix" {
  type        = string
  description = "Prefixo dos recursos."
  default     = "buriti-aprec"
}

variable "tags" {
  type        = map(string)
  description = "Tags padrão aplicadas a todos os recursos."
  default = {
    projeto = "calculadora-aprecamento"
    time    = "anka"
    iac     = "terraform"
  }
}

# --- Imagem (uma so, para as 2 Function Apps) ---
variable "image_name" {
  type        = string
  description = "Nome da imagem do microserviço no ACR."
  default     = "buriti-aprecamento"
}

variable "image_tag" {
  type        = string
  description = "Tag da imagem (o CI seta; lifecycle ignora drift em prod)."
  default     = "latest"
}

variable "cron_expression" {
  type        = string
  description = <<-DESC
    Agenda do lote diario, em NCRONTAB de SEIS campos (o Azure Functions poe os
    SEGUNDOS na frente -- "0 0 21 * * *" = 21h em ponto). Cron de cinco campos,
    do modelo antigo de Container App Job, e aceito no apply e dispara na hora
    ERRADA. O cron e so o despertador: a trava real e dia util + watermark.
  DESC
  default     = "0 0 21 * * *"
}

# --- Banco (SQL Server do ETL — valores com Felipe/Jefferson; NÃO são segredo) ---
variable "sql_server_host" {
  type        = string
  description = "FQDN do Azure SQL (ex.: <servidor>.database.windows.net). Pedir ao Felipe."
  default     = ""
}

variable "sql_server_port" {
  type        = number
  description = "Porta do SQL Server."
  default     = 1433
}

variable "sql_server_db" {
  type        = string
  description = "Nome do database. Pedir ao Felipe."
  default     = ""
}

variable "calc_pool_size" {
  type        = number
  description = "Teto de conexões por réplica (pool SQLAlchemy, max_overflow=0). Teto efetivo no banco = parallelism × este valor. Default 5 (doc 12 §2.1)."
  default     = 5
}

variable "sql_auth_enabled" {
  type        = bool
  description = "SÓ DEV: injeta SQL_SERVER_USER/PWD via secret ref do Key Vault. Exige os secrets JÁ criados no KV (README §ordem de subida). Prod = false (AAD via managed identity, sem senha)."
  default     = false
}

variable "sql_trust_server_certificate" {
  type        = string
  description = <<-DESC
    "no" (default) = valida o certificado do servidor, que e o correto para
    Azure SQL. "yes" aceita qualquer certificado -- so use se o nome do host
    nao casar com o certificado. O default do CODIGO e "yes"; aqui o Terraform
    o sobrescreve de proposito.
  DESC
  default     = "no"
}

variable "storage_shared_key_enabled" {
  type        = bool
  description = <<-DESC
    Mantem a chave compartilhada da conta de storage habilitada. Default true.
    O host e o codigo autenticam por managed identity e nao usam a chave -- mas
    desliga-la em Function App CONTEINERIZADA no plano Elastic Premium ainda
    nao foi testado por nos (sem acesso Azure). Virar false e conferir se as
    duas apps sobem e a fila consome; se subirem, deixar false.
  DESC
  default     = true
}

variable "timezone" {
  type        = string
  description = "Timezone dos jobs (data alvo do batch)."
  default     = "America/Sao_Paulo"
}

# --- Alertas (doc 12 §5.5 — vazio = nenhum alerta criado) ---
variable "alert_emails" {
  type        = list(string)
  description = "E-mails do action group (seu + Felipe/Jefferson a confirmar — checklist item 8). Vazio desliga os alertas."
  default     = []
}

variable "alert_quarantine_max" {
  type        = number
  description = "Ativos quarentenados por dia acima do qual o alerta dispara."
  default     = 20
}

# --- ACR: reusar o do ETL (recomendado) ou criar novo ---
variable "acr_resource_group_name" {
  type        = string
  description = "RG do ACR existente a reusar (ex.: o do funds-api). Vazio = criar ACR novo."
  default     = ""
}

variable "acr_name" {
  type        = string
  description = "Nome do ACR existente a reusar. Vazio = criar ACR novo."
  default     = ""
}

variable "acr_tenant_subscription_id" {
  type        = string
  description = "ID da subscription do tenant alternativo onde o ACR está localizado. Vazio = usa a subscription atual. Anda SEMPRE junto com acr_tenant_id."
  default     = ""

  # UMA SUBSCRIPTION PERTENCE A EXATAMENTE UM TENANT, entao preencher so' um dos
  # dois e' uma configuracao impossivel -- e o Terraform nao percebia: o provider
  # aliasado monta `tenant_id` e `subscription_id` de forma independente e cai em
  # `var.subscription_id` quando este aqui esta vazio. O resultado e' pegar token
  # no tenant do ACR e procurar o registry numa subscription da Buriti.
  #
  # Medido com ACR real, variando SO' a subscription:
  #   coerente   -> "Read complete", login_server devolvido
  #   incoerente -> "Planning failed ... Registry (Subscription: ...) was not found"
  # A mensagem fala do NOME do registry quando a causa e' a subscription, e
  # ninguem aponta para a variavel esquecida. Dai a validacao.
  validation {
    condition     = (var.acr_tenant_id == "") == (var.acr_tenant_subscription_id == "")
    error_message = "acr_tenant_id e acr_tenant_subscription_id andam juntos: uma subscription pertence a exatamente um tenant. Preencha os dois, ou nenhum."
  }
}

variable "acr_tenant_id" {
  type        = string
  description = "Tenant ID do outro Azure tenant onde o ACR está localizado. Vazio = usa o tenant atual."
  default     = ""

  # O QUARTO QUADRANTE, que nao esta na tabela de cenarios do README e nao
  # deveria existir: `acr_tenant_id` preenchido com `acr_name` VAZIO. Medido:
  # o plan passa e produz um hibrido incoerente -- cria um registry novo e
  # vazio no NOSSO tenant, poe AcrPull nele, e ainda configura as duas apps
  # com usuario e senha de um service principal do tenant do outro. A app
  # sobe apontando para um registry que nao tem imagem nenhuma.
  validation {
    condition     = var.acr_tenant_id == "" || var.acr_name != ""
    error_message = "acr_tenant_id so faz sentido reusando um ACR existente: preencha acr_name (e acr_resource_group_name) ou deixe acr_tenant_id vazio para criar um registry local."
  }
}

variable "acr_client_id" {
  type        = string
  description = "Client ID do Service Principal para autenticar no ACR cross-tenant. Obrigatório apenas se acr_tenant_id for preenchido."
  default     = ""
}


# --- Functions (Pacote 12-R) ---
variable "functions_sku" {
  type        = string
  description = <<-DESC
    SKU do plano. EP1 (default) = Elastic Premium: e o unico que roda CONTAINER
    proprio -- necessario porque o pyodbc exige o ODBC Driver 18, que e pacote de
    sistema e nao entra em plano gerenciado -- e o unico que integra em VNet, caso
    o SQL esteja atras de private endpoint.

    CUSTO: ~US$150/mes e o preco de UMA instancia EP1 -- e um PISO, nao a conta.
    O plano cobra por instancia alocada, e aqui duas apps o dividem: a "-io"
    fica com uma instancia sempre pronta (elastic_instance_minimum = 1) e a
    "-calc" escala ate calc_scale_limit durante o lote. Conferir na primeira
    fatura antes de prometer numero a alguem.
  DESC
  default     = "EP1"
}

variable "functions_max_workers" {
  type        = number
  description = "Teto de workers elasticos do PLANO (as 2 apps dividem)."
  default     = 20
}

variable "calc_scale_limit" {
  type        = number
  description = <<-DESC
    Instancias simultaneas da ETAPA 2 (calculo). Pode subir a vontade: essa app
    nao tem credencial de banco, entao escalar aqui NAO consome conexao do SQL.
    O teto real do lote e a janela de tempo, nao o banco.
  DESC
  default     = 10
}

variable "functions_subnet_id" {
  type        = string
  description = <<-DESC
    Subnet DELEGADA a Microsoft.Web/serverFarms para a app "-io" alcancar o SQL.
    PEDIR AO FELIPE (checklist item 2): so e necessaria se o Azure SQL estiver
    atras de private endpoint. Vazio = SQL publico com firewall (ele libera o IP
    de saida da app).
  DESC
  default     = ""
}

variable "max_dequeue_count" {
  type        = number
  description = <<-DESC
    Tentativas antes da mensagem ir para a fila -poison. Deve espelhar o
    maxDequeueCount do host.json do repo de codigo (default 5) -- aqui o valor
    so alimenta o TEXTO do alerta; quem manda de verdade e o host.json.
  DESC
  default     = 5
}
