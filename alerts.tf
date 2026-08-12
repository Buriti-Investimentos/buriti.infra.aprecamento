# Alertas minimos — "o minimo que deixa dormir".
#
# Todos condicionados a alert_emails nao-vazio (checklist item 8: canal a
# confirmar com Felipe/Jefferson).
#
# ⚠️ CORRECAO DO PACOTE 12-R: a versao anterior destes alertas consultava
# `customEvents`, contando com um `src/service/observability.py` que NUNCA
# existiu. O que o servico realmente faz (`log_evento`, config.py:47-49) e
# escrever JSON em stdout — que no Application Insights cai em **traces**, nao
# em customEvents. Ou seja: os 3 alertas de negocio estavam escritos contra uma
# tabela vazia e **nunca teriam disparado**. Um alerta que nao dispara e pior
# que nenhum: da sensacao de cobertura. Agora as consultas leem `traces` e
# desempacotam o JSON com parse_json — o formato que o codigo emite de fato.
#
# Tambem saiu o alerta de "duracao anomala": ele filtrava por um campo
# `duracao_s` que nenhum evento emite. Volta quando o servico medir a janela.

locals {
  alerts_enabled = length(var.alert_emails) > 0
  app_insights   = [azurerm_application_insights.this.id]
}

resource "azurerm_monitor_action_group" "this" {
  count               = local.alerts_enabled ? 1 : 0
  name                = "ag-${local.name}"
  resource_group_name = azurerm_resource_group.this.name
  short_name          = "aprec" # max. 12 chars
  tags                = local.tags

  dynamic "email_receiver" {
    for_each = { for i, e in var.alert_emails : i => e }
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

# 1) Alguma EXECUCAO de function falhou (qualquer etapa das duas apps).
#    O host registra cada invocacao como `requests`; success=false = falhou.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "funcao_falhou" {
  count                = local.alerts_enabled ? 1 : 0
  name                 = "alrt-${local.name}-funcao-falhou"
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  scopes               = local.app_insights
  description          = "Uma ou mais execucoes de function do aprecamento falharam."
  severity             = 1
  evaluation_frequency = "PT15M"
  window_duration      = "PT30M"
  tags                 = local.tags

  criteria {
    query                   = <<-QUERY
      requests
      | where success == false
    QUERY
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0
  }

  auto_mitigation_enabled = true

  action {
    action_groups = [azurerm_monitor_action_group.this[0].id]
  }
}

# 2) SILENCIO: nenhum lote completo nas ultimas 24h.
#    Pega o caso que nenhum alerta de falha pega — o job que simplesmente NAO
#    rodou (timer nao disparou, fila parada, app parada).
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "batch_silencio" {
  count                = local.alerts_enabled ? 1 : 0
  name                 = "alrt-${local.name}-batch-silencio"
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  scopes               = local.app_insights
  description          = "Nenhum calc.batch.completed nas ultimas 24h — timer nao disparou, fila parada ou app fora do ar."
  severity             = 1
  evaluation_frequency = "PT1H"
  window_duration      = "P1D"
  tags                 = local.tags

  # Ausencia: 0 linhas no resultado -> dispara.
  criteria {
    query                   = <<-QUERY
      traces
      | extend ev = parse_json(message)
      | where tostring(ev.evento) == "calc.batch.completed"
    QUERY
    time_aggregation_method = "Count"
    operator                = "Equal"
    threshold               = 0
  }

  # Stateful: dispara UMA vez por incidente e auto-resolve quando um lote volta
  # a completar. NAO combinar com mute_actions_after_alert_duration — o provider
  # proibe (sao mutuamente exclusivos).
  auto_mitigation_enabled = true

  action {
    action_groups = [azurerm_monitor_action_group.this[0].id]
  }
}

# 3) MENSAGEM ENVENENADA: alguma mensagem estourou maxDequeueCount e foi parar
#    na fila -poison. Este e o alerta que responde diretamente ao requisito do
#    Felipe ("nao posso perder esses jobs"): a mensagem nao se perde, mas fica
#    parada esperando alguem — e esse alguem precisa ser avisado.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "mensagem_envenenada" {
  count                = local.alerts_enabled ? 1 : 0
  name                 = "alrt-${local.name}-fila-poison"
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  scopes               = local.app_insights
  description          = "Mensagem movida para a fila poison: um lote falhou ${var.max_dequeue_count}x e esta parado."
  severity             = 1
  evaluation_frequency = "PT15M"
  window_duration      = "PT1H"
  tags                 = local.tags

  criteria {
    query                   = <<-QUERY
      traces
      | where message has "poison" and message has "moving message"
    QUERY
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0
  }

  auto_mitigation_enabled = true

  action {
    action_groups = [azurerm_monitor_action_group.this[0].id]
  }
}

# 4) QUARENTENA ANOMALA: muitos ativos pulados no dia — sinal de problema
#    SISTEMICO de dado (indice faltando, cadastro incompleto), nao de um papel.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "quarentena" {
  count                = local.alerts_enabled ? 1 : 0
  name                 = "alrt-${local.name}-quarentena"
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  scopes               = local.app_insights
  description          = "Mais de ${var.alert_quarantine_max} ativos quarentenados em 24h — provavel problema de dado sistemico."
  severity             = 2
  evaluation_frequency = "PT1H"
  window_duration      = "P1D"
  tags                 = local.tags

  criteria {
    query                   = <<-QUERY
      traces
      | extend ev = parse_json(message)
      | where tostring(ev.evento) == "calc.asset.quarantined"
    QUERY
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = var.alert_quarantine_max
  }

  auto_mitigation_enabled = true

  action {
    action_groups = [azurerm_monitor_action_group.this[0].id]
  }
}
