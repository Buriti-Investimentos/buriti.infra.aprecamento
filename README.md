# `buriti.infra.aprecamento`

Infraestrutura (Terraform) do microserviço de apreçamento diário de Renda Fixa.
É o segundo dos dois repositórios combinados com o Nicolas: um só do código
(`buriti.backend.aprecamento`), este só do Terraform.

> **Estado:** validado até `terraform validate`. **Ainda não passou por
> `plan`/`apply`** — falta o acesso à Azure da Buriti. Os `environments/*.tfvars`
> têm placeholders `<ASSIM>` que precisam ser preenchidos antes.

---

## A arquitetura: 3 etapas ligadas por fila

O desenho resolve um problema específico: rodar muito cálculo em paralelo **sem
estourar o limite de conexões** do SQL Server da Buriti.

```
 (gatilho)             leituras          lotes            resultados
 timer 21h  ─┐                                                         ┌─ SQL
             ├─► agendador ─► leitor ─► calculadora ─► gravador ───────┘
 HTTP       ─┘                ETAPA 1    ETAPA 2        ETAPA 3
                              1 conexão  0 conexões     1 conexão
```

| Etapa | Regra | Escala |
|---|---|---|
| **1 · leitor** | lê de uma vez tudo que o fundo precisa | 1 instância |
| **2 · calculadora** | só matemática — **sem credencial de banco** | N em paralelo |
| **3 · gravador** | grava o lote numa transação | 1 instância |

`agendador` (timer) e `backfill` (HTTP) são **gatilhos**, não etapas: os dois
apenas enfileiram pedidos de leitura. Retroativo não tem caminho próprio —
reusa a mesma esteira.

**Duas Function Apps, uma imagem.** O papel de cada uma vem do app setting
`AzureWebJobs.<função>.Disabled`:

| App | Funções | Credencial do SQL |
|---|---|---|
| `func-…-io` | agendador, leitor, gravador, backfill | **sim** |
| `func-…-calc` | calculadora | **não** |

A etapa 2 não *promete* ficar longe do banco: ela roda onde as variáveis de
conexão não existem. Garantia estrutural.

**Nada se perde.** Cada fila tem sua `-poison`: depois de 5 tentativas a
mensagem para lá, e um alerta avisa. É o requisito do Felipe ("não posso perder
esses jobs"), resolvido nativamente — sem o Redis-como-DLQ que ele mantém no ETL.

---

## O que este Terraform cria

| Recurso | Para quê |
|---|---|
| Resource Group | tudo isolado — nada toca o que já roda (combinado com o Nicolas) |
| Log Analytics + Application Insights | logs, alertas e a métrica de lote completo |
| Managed Identity (user-assigned) | autenticação **sem senha**: AAD no SQL, pull no ACR, acesso ao storage |
| Key Vault (RBAC) | só os segredos sem identidade gerenciada (usuário/senha do SQL em dev) |
| Storage Account | runtime do host + 3 filas + 3 filas poison + blobs do claim-check |
| App Service Plan (EP1) | compute das Functions |
| 2 × Linux Function App | as apps `-io` e `-calc` |
| ACR | reusa um existente (recomendado) **ou** cria um Basic novo |
| 4 alertas | falha de execução, silêncio 24h, mensagem envenenada, quarentena anômala |

### Por que Elastic Premium (e não Consumption/Flex)

A camada de conexão usa `pyodbc` + **ODBC Driver 18**, que é pacote de
**sistema**. Plano gerenciado só aceita wheels Python — então precisaríamos
trocar o driver e **perder a autenticação AAD sem senha**, que é o padrão já
provado no ETL. Premium é também o único que entra em VNet, caso o SQL esteja
atrás de private endpoint.

Custo: **~US$150/mês por ambiente** só do plano. Se a economia for prioritária,
a alternativa (Flex + trocar o driver, ~US$25/mês) existe — mas é decisão de
produto, não default de engenharia.

---

## Ordem de subida

O `apply` sozinho não deixa o sistema funcionando. A ordem importa:

1. **Bootstrap do state** — criar Storage Account + container `tfstate` e
   descomentar o bloco `backend "azurerm"` em `versions.tf`. **Antes do primeiro
   apply**: sem isso o state nasce na máquina de quem rodou.
   ```bash
   terraform init -backend-config="key=aprecamento-dev.tfstate"
   ```
2. **Preencher** `environments/dev.tfvars` (subscription, SQL, ACR, rede, e-mails).
3. **Plan e revisar**, recurso por recurso:
   ```bash
   terraform plan -var-file=environments/dev.tfvars
   ```
4. **Apply.**
5. **Grants AAD no SQL** — o Felipe roda o `.sql` da identidade (o
   `identity_client_id` sai nos outputs). Least-privilege: `SELECT` no cadastro
   e nos índices; `INSERT/UPDATE/DELETE` só nas tabelas de resultado.
6. **Migrations Alembic** aplicadas pelo Felipe. Sem elas a infra sobe e o
   gravador falha na escrita.
7. **Secrets de dev** (só se `sql_auth_enabled = true`):
   ```bash
   az keyvault secret set --vault-name <key_vault_name> --name sql-server-user --value '...'
   az keyvault secret set --vault-name <key_vault_name> --name sql-server-pwd  --value '...'
   ```
   Quem executa precisa da role *Key Vault Secrets Officer*. Os **valores nunca
   entram no Terraform** — ficariam no state.
8. **Primeira imagem** publicada pelo CI do repo de código.
9. **Lote de um fundo só**, conferido contra o administrador, antes de soltar o
   diário inteiro.
10. **No cutover:** remover o job `daily_aprecamento_etl` do scheduler do ETL.
    Se ele continuar registrado, os dois escrevem sobre a mesma tabela.

## Backfill

```bash
curl -X POST "https://<func-…-io>.azurewebsites.net/api/backfill?code=<function-key>" \
  -H "Content-Type: application/json" \
  -d '{"de":"2026-01-02","ate":"2026-06-30","fundos":[5,6]}'
```

Responde `202` com quantos pedidos entraram na fila. Datas passadas entram como
**fechadas**: o gravador nunca deleta número já visto — cria versão nova.

---

## O que ainda depende de terceiros

| # | Item | Quem |
|---|---|---|
| 1 | Subscription + acesso para criar (autorizado pelo Nicolas em call) | Felipe |
| 2 | Como o ETL chega no SQL hoje: público+firewall × VNet/private endpoint | Felipe |
| 3 | Tier do SQL e limite de conexões (calibra `calc_pool_size`) | Felipe |
| 4 | Rodar o script de grants AAD | Felipe |
| 5 | Credenciais SQL de dev (só se `sql_auth_enabled`) | Felipe |
| 6 | Aplicar as migrations Alembic | Felipe |
| 7 | Remover o job antigo do scheduler do ETL no cutover | Felipe |
| 8 | E-mails/canal dos alertas (vazio = **nenhum alerta é criado**) | Felipe/Jefferson |
| 9 | Qual ACR reusar (candidato: `fundsapiservice-ceahbnb9h8atcybj`) | Jefferson |

---

## Histórico

O `compute.tf` anterior modelava **2 Container App Jobs** (cron diário +
backfill manual). Era coeso, mas não era a arquitetura combinada com o cliente.
Foi arquivado em `docs/superseded/compute.container-app-job.tf.txt` — vale como
referência, não como alvo.

Junto vieram duas correções que valem registrar:

- **Os alertas de negócio nunca disparariam.** Consultavam `customEvents`,
  contando com um módulo de observabilidade que nunca existiu. O serviço escreve
  JSON em stdout, que cai em `traces`. As consultas foram reescritas contra o
  que o código emite de fato.
- **O cron estava no formato errado.** Azure Functions usa NCRONTAB de **seis**
  campos (segundos na frente). Cron de cinco campos é aceito no apply e dispara
  na hora errada.
