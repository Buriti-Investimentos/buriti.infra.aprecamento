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

variable "acr_tenant_subscripton_id" {
  type        = string
  description = "ID da subscription do tenant alternativo onde o ACR está localizado. Vazio = usa a subscription atual."
  default     = ""
}

variable "acr_tenant_id" {
  type        = string
  description = "Tenant ID do outro Azure tenant onde o ACR está localizado. Vazio = usa o tenant atual."
  default     = ""
}


# --- Functions (Pacote 12-R) ---
variable "functions_sku" {
  type        = string
  description = <<-DESC
    SKU do plano. EP1 (default) = Elastic Premium: e o unico que roda CONTAINER
    proprio -- necessario porque o pyodbc exige o ODBC Driver 18, que e pacote de
    sistema e nao entra em plano gerenciado -- e o unico que integra em VNet, caso
    o SQL esteja atras de private endpoint. Custo ~US$150/mes por ambiente.
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
