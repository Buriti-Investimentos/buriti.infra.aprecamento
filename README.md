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

### ACR: localmente ou cross-tenant

O Terraform pode criar um ACR novo ou reusar um existente. Se o ACR existente
estiver no **mesmo tenant**, a autenticação é automática via Managed Identity
(sem senha). Se estiver em **outro tenant**, você precisa fornecer credenciais
manuais:

| Cenário | `acr_name` | `acr_tenant_id` | O que acontece |
|---|---|---|---|
| **ACR novo** | vazio | vazio | Terraform cria um registry `Basic` novo no tenant atual |
| **ACR existente, mesmo tenant** | preenchido | vazio (padrão) | Terraform busca o registry existente e atribui `AcrPull` via Managed Identity |
| **ACR em outro tenant** | preenchido | preenchido | Terraform busca o registry, **sem role assignment** — você fornece `client_id`/`client_secret` manualmente para autenticar as Function Apps |

**Cenários 1 e 2:** as Function Apps puxam a imagem usando a Managed Identity, sem
segredo.

**Cenário 3:** se o ACR estiver em outro tenant, o role assignment cross-tenant não
funciona com Managed Identity nativa. Solução: você cria manualmente um Service
Principal no tenant do ACR com `AcrPull`, e passa `client_id`/`client_secret` das
Function Apps via `DOCKER_REGISTRY_SERVER_USERNAME`/`PASSWORD` nos app_settings.
A ordem de subida (Passo 1) mostra onde informar essas credenciais.

---

## Ordem de subida

### Por que existe uma ordem

O `terraform apply` cria **caixas vazias**. Ele não coloca a imagem dentro da
Function App, não cria as tabelas no banco, não dá permissão de escrita para
ninguém e não guarda senha em cofre nenhum. Cada uma dessas quatro coisas tem
**dono diferente** e **momento diferente** — e três delas só podem acontecer
*depois* que o Terraform criou o recurso que elas configuram.

Pense em três camadas:

| Camada | Quem cria | Depende de |
|---|---|---|
| **Fundação** — onde o Terraform guarda a memória do que criou | você, **uma vez**, na mão | nada |
| **Infra** — grupo de recursos, filas, apps, cofre, identidade | `terraform apply` | a fundação existir |
| **Conteúdo** — imagem, tabelas, permissões, segredos | CI e Felipe | a infra existir |

A ordem abaixo é a única em que cada passo encontra pronto o que precisa. Pular
um não dá erro na hora — dá erro **depois**, e num lugar que não aponta para a
causa. A tabela de sintomas no fim da seção existe por isso.

---

### Passo 0 · Bootstrap do state — **antes de tudo, uma única vez**

**O que é.** O Terraform guarda num arquivo (`state`) o mapa do que ele criou:
qual recurso tem qual id, o que já existe, o que mudou. Sem esse arquivo ele fica
cego — não sabe se deve criar ou atualizar.

**Por que primeiro.** Se você rodar `apply` sem configurar onde o state mora, ele
nasce **na sua máquina**, num arquivo local. A partir daí: quem rodar de outro
computador cria tudo de novo em duplicata, e se o arquivo se perder o Terraform
esquece o que existe — recuperar vira trabalho manual no portal.

O state precisa morar num lugar compartilhado. Mas esse lugar é ele próprio um
recurso da Azure — daí o ovo e a galinha: **cria-se na mão, uma vez, fora do
Terraform.**

```bash
az login
az account set --subscription "<SUBSCRIPTION_ID>"

# 1. grupo de recursos só para o state (nome livre, mas combine com o Felipe)
az group create --name rg-tfstate --location brazilsouth

# 2. conta de armazenamento — o nome é GLOBAL, precisa ser único no mundo
az storage account create \
  --name sttfstateburiti --resource-group rg-tfstate \
  --location brazilsouth --sku Standard_LRS \
  --min-tls-version TLS1_2 --allow-blob-public-access false

# 3. o contêiner onde os arquivos de state ficam
az storage container create \
  --name tfstate --account-name sttfstateburiti --auth-mode login
```

Depois, **descomente** o bloco `backend "azurerm"` em `versions.tf` (linhas 16-21)
e ajuste os nomes se você usou outros. Então:

```bash
terraform init -backend-config="key=aprecamento-dev.tfstate"
```

> **Um state por ambiente.** A chave (`key`) é o nome do arquivo dentro do
> contêiner. `aprecamento-dev.tfstate` e `aprecamento-prod.tfstate` são arquivos
> separados — é isso que impede um `apply` em dev de mexer em prod.

**Como saber que deu certo:** o `init` responde
`Successfully configured the backend "azurerm"`. Se ele disser
`Terraform has been successfully initialized` **sem** mencionar backend, o bloco
continua comentado — o state ainda é local.

---

### Passo 1 · Preencher os parâmetros do ambiente

Abra `environments/dev.tfvars` e substitua todo `<ASSIM>` por valor real. São
sete informações, e **cinco delas vêm do Felipe**:

| Parâmetro | De onde vem |
|---|---|
| `subscription_id` | Felipe — junto com o acesso |
| `sql_server_host` / `sql_server_db` | Felipe — é o mesmo banco que o ETL usa hoje |
| `functions_subnet_id` | Felipe — **só se** o SQL estiver atrás de rede privada; senão deixe vazio |
| `acr_name` / `acr_resource_group_name` | Jefferson — reusar o registry existente evita criar outro |
| `acr_tenant_id` | Felipe — **só se** o ACR estiver em outro tenant; senão deixe vazio (padrão = tenant atual) |
| `acr_tenant_subscription_id` | Felipe — **só se** o ACR estiver em outro tenant/subscription; senão deixe vazio (padrão = subscription atual) |
| `alert_emails` | vocês — **lista vazia não cria alerta nenhum** |

> ⚠️ **Deixe `sql_auth_enabled = false` neste primeiro momento.** Ele liga
> referências de segredo que ainda não existem — o passo 5 explica.

---

### Passo 2 · Plan — ler antes de criar

```bash
terraform plan -var-file=environments/dev.tfvars
```

Isso **não cria nada**. Mostra a lista do que seria criado, recurso por recurso.
É o primeiro contato real com o ambiente deles, e é onde aparece o que nenhuma
validação local antecipa: política de nomenclatura da empresa, região bloqueada,
permissão que falta na sua conta.

São **23 blocos de recurso** declarados, mas o plan mostra mais linhas do que
isso: `azurerm_storage_queue` vira 6 (as 3 filas + as 3 poison) e os 5 alertas só
aparecem se `alert_emails` não estiver vazio. Não decore o número — confira o
que importa:

- **tudo com `+ create`.** Qualquer `~ update` ou `- destroy` no *primeiro* plan
  significa que o state não está vazio: ou o backend aponta para o state de outro
  ambiente, ou alguém já aplicou aqui. Pare e investigue.
- **os alertas estão na lista?** Se não, `alert_emails` ficou vazio e você vai
  subir sem monitoramento nenhum.
- **o ACR aparece como `create`?** Então `acr_name` ficou vazio e ele vai criar um
  registry novo em vez de reusar o existente. Confirme com o Jefferson se é isso
  mesmo.
- **o role_assignment `azurerm_role_assignment.acr_pull` aparece?** Se sim,
  `acr_tenant_id` está vazio (padrão) — ACR será criado ou reutilizado no tenant
  atual, e a autenticação é automática. Se o ACR é cross-tenant e o role assignment
  **não** aparece, está correto: credenciais manuais são necessárias (Passo 1).

---

### Passo 3 · Apply — criar as caixas

```bash
terraform apply -var-file=environments/dev.tfvars
```

Leva alguns minutos (o plano de Functions é o mais demorado). Ao fim ele imprime
os **outputs**, e você vai precisar de três deles nos passos seguintes:

```bash
terraform output identity_client_id      # p/ o script de permissões do SQL
terraform output key_vault_name          # p/ gravar os segredos de dev
terraform output url_backfill            # p/ disparar retroativo depois
```

> **O que você tem agora:** as duas Function Apps existem, as filas existem, o
> cofre existe. **Nada roda ainda** — não há imagem publicada, não há permissão
> no banco, e as tabelas de destino podem não existir.

---

### Passo 4 · Permissões no banco — **Felipe executa**

**O que é.** A identidade gerenciada criada no passo 3 é um "usuário" da Azure.
Do ponto de vista do SQL Server ela ainda é uma desconhecida: existe, mas não tem
permissão para ler nem escrever nada.

**Por que só agora.** O script precisa do `identity_client_id`, que só existe
depois do apply.

A Anka entrega o `.sql`; o Felipe roda no banco dele. O princípio é o menor
privilégio possível:

- `SELECT` no cadastro de ativos e nas séries de índice — o que a etapa 1 lê
- `INSERT/UPDATE/DELETE` **apenas** nas três tabelas de resultado — o que a
  etapa 3 escreve

Nada além disso. Se um dia o job tentar escrever fora dessas três tabelas, ele
falha por permissão — e isso é proteção, não obstáculo.

---

### Passo 5 · Migrations — **Felipe executa**

As colunas e tabelas que o gravador usa (versão de cálculo, data de referência,
marca d'água, as colunas de PU de mercado, PDD e ágio) entram por migration
Alembic, no repositório do ETL.

**Por que depois do apply e antes de rodar o lote:** o Terraform não cria tabela
— ele não sabe nada de schema. Se o lote rodar antes, a infra sobe bonita, o
cálculo acontece e a escrita falha na última etapa.

---

### Passo 6 · Segredos de dev — **só se for usar usuário e senha**

Em **produção não existe este passo**: a autenticação é AAD pela identidade
gerenciada, sem senha nenhuma.

Em **dev**, se o banco só aceitar usuário e senha, é aqui que eles entram — e
entram **no cofre, nunca no Terraform**. Valor em variável de Terraform vira
texto puro dentro do arquivo de state.

```bash
az keyvault secret set --vault-name <key_vault_name> \
  --name sql-server-user --value '...'
az keyvault secret set --vault-name <key_vault_name> \
  --name sql-server-pwd  --value '...'
```

Quem executa precisa da role **Key Vault Secrets Officer** no cofre.

**Só então** vire `sql_auth_enabled = true` no tfvars e rode `apply` de novo — é
esse segundo apply que injeta nas Function Apps a *referência* aos segredos.

> **A ordem aqui é a armadilha clássica.** Se `sql_auth_enabled = true` já no
> primeiro apply, a app é criada apontando para um segredo que não existe. A
> referência não resolve, a variável de conexão chega vazia, e a app sobe sem
> conseguir falar com o banco — com um erro que fala de conexão, não de cofre.

---

### Passo 7 · Primeira imagem — o CI publica

Até aqui as duas Function Apps existem mas **não têm o que executar**: elas
apontam para uma imagem que ainda não foi publicada no registry.

O CI do `buriti.backend.aprecamento` faz o build, empurra para o ACR e aponta as
duas apps para a tag nova. Um push na `main` basta.

> **As duas apps recebem a MESMA tag, sempre.** Se divergirem, a etapa 2 calcula
> com um código e a etapa 3 grava com outro.

**Como conferir:**
```bash
az functionapp show -g <RESOURCE_GROUP> -n <func-...-io>   --query state
az functionapp show -g <RESOURCE_GROUP> -n <func-...-calc> --query state
```

---

### Passo 8 · Um fundo só, conferido contra o administrador

Não solte o diário inteiro de primeira. Dispare o retroativo para **um fundo e
um dia**, e compare o preço com o que o administrador publicou.

```bash
curl -X POST "$(terraform output -raw url_backfill)?code=<function-key>" \
  -H "Content-Type: application/json" \
  -d '{"de":"2026-08-01","ate":"2026-08-01","fundos":[5]}'
```

O motor já bate ao centavo localmente. Este passo prova que ele bate também
**lendo o banco real deles** — que é onde moram as diferenças de dado que
nenhum teste local encontra.

---

### Passo 9 · Cutover — desligar o antigo no mesmo dia

O apreçamento antigo continua agendado dentro do ETL, num jobstore **persistente**
— ou seja, sobrevive a restart. Ele precisa sair no dia da virada.

**Se ficar:** os dois rodam, os dois escrevem na mesma tabela, na mesma data. Não
dá erro; dá número duplicado com versões concorrentes, e ninguém percebe até
alguém conferir.

---

### Se pular um passo, o sintoma é este

| Pulou | O que você vê | O que realmente aconteceu |
|---|---|---|
| **0** bootstrap | tudo funciona… até outra pessoa rodar e criar duplicata | state ficou local, na sua máquina |
| **1** tfvars | `apply` falha pedindo `subscription_id` | falta parâmetro obrigatório |
| **4** permissões | job termina "ok" mas nada aparece no banco, ou erro de permissão na etapa 3 | a identidade não tem grant |
| **5** migrations | erro de coluna inexistente na hora de gravar | tabela de destino não tem o schema novo |
| **6** segredos | app sobe mas não conecta; erro fala de conexão | referência de cofre não resolveu |
| **7** imagem | app existe, aparece parada, nada é processado | não há imagem para puxar |
| **8** validação | descobre divergência de preço semanas depois | ninguém confrontou com o administrador |
| **9** cutover | linhas duplicadas na tabela de resultado | os dois agendamentos rodando juntos |

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
