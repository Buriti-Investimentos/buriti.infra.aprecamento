#!/usr/bin/env bash
#
# Põe no Key Vault os segredos que o Terraform NÃO escreve — e confere que
# entraram.
#
# ── POR QUE ISTO NÃO ESTÁ NO TERRAFORM ─────────────────────────────────────
# Um `azurerm_key_vault_secret` com o argumento `value` grava o segredo em
# TEXTO CLARO no arquivo de state, e o nosso state mora num storage account.
# O provider tem o argumento write-only `value_wo` (Terraform >= 1.11), que
# resolve isso — mas aí o valor teria de chegar até o Terraform por tfvars ou
# variável de ambiente, e estes três segredos vêm de TRÊS pessoas em momentos
# diferentes (banco: Felipe; ACR: Jefferson). Enquanto for assim, eles entram
# por aqui: o valor existe no cofre e em nenhum outro lugar.
#
# ── O QUE ESTE SCRIPT RESOLVE ──────────────────────────────────────────────
# Antes ele era três comandos `az keyvault secret set` soltos no README, em
# três parágrafos diferentes. Passo espalhado é passo que alguém pula — e pular
# é caro: a app sobe, não acha o segredo, e o erro aparece longe da causa (um
# 401 no pull da imagem manda procurar defeito no registry, não no cofre).
#
# Aqui é um comando só, idempotente, que CONFERE cada gravação lendo de volta.
#
# ── USO ────────────────────────────────────────────────────────────────────
#   ./scripts/subir-segredos.sh                    # pergunta o que faltar
#   ./scripts/subir-segredos.sh -v kv-aprec-dev    # cofre explícito
#
# Sem `-v`, o nome do cofre sai do `terraform output`.
#
# Os valores podem vir por variável de ambiente, para automação:
#   SQL_SERVER_USER, SQL_SERVER_PWD, ACR_CLIENT_SECRET
# O que não vier por ambiente é perguntado, sem eco na tela. Dar ENTER em
# branco PULA aquele segredo — é assim que se roda só o do ACR, por exemplo.
#
set -euo pipefail

COFRE=""
while getopts "v:h" opt; do
  case "$opt" in
    v) COFRE="$OPTARG" ;;
    h) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "uso: $0 [-v <nome-do-cofre>]" >&2; exit 2 ;;
  esac
done

# ── o cofre ────────────────────────────────────────────────────────────────
if [ -z "$COFRE" ]; then
  COFRE="$(terraform output -raw key_vault_name 2>/dev/null || true)"
fi
if [ -z "$COFRE" ]; then
  echo "ERRO: não achei o nome do cofre." >&2
  echo "  Rode de dentro do diretório do Terraform (para eu ler do \`terraform output\`)" >&2
  echo "  ou passe explicitamente:  $0 -v <nome-do-cofre>" >&2
  exit 1
fi
echo "cofre: $COFRE"

# ── a permissão, ANTES de tentar ───────────────────────────────────────────
# Escrever segredo é operação de PLANO DE DADOS. Ser Owner da subscription NÃO
# dá esse direito (o papel Owner tem `dataActions` vazio). Conferir agora troca
# um 403 no meio da execução por uma frase que diz o que pedir a quem.
if ! az keyvault secret list --vault-name "$COFRE" --maxresults 1 >/dev/null 2>&1; then
  echo "ERRO: a sua conta não consegue LER os segredos de '$COFRE'." >&2
  echo "  Escrever exige o papel 'Key Vault Secrets Officer' NO COFRE (plano de" >&2
  echo "  dados). Owner da subscription não cobre isso. Peça:" >&2
  echo >&2
  echo "    az role assignment create --role 'Key Vault Secrets Officer' \\" >&2
  echo "      --assignee <seu-usuario-ou-sp> \\" >&2
  echo "      --scope \$(az keyvault show -n $COFRE --query id -o tsv)" >&2
  exit 1
fi

# ── os três segredos ───────────────────────────────────────────────────────
# nome-no-cofre | variável de ambiente | o que é, para o prompt
SEGREDOS=(
  "sql-server-user|SQL_SERVER_USER|usuário do SQL Server (só se sql_auth_enabled = true)"
  "sql-server-pwd|SQL_SERVER_PWD|senha do SQL Server (só se sql_auth_enabled = true)"
  "acr-client-secret|ACR_CLIENT_SECRET|client secret do Service Principal do ACR (só se acr_tenant_id preenchido)"
)

gravados=(); pulados=(); falhos=()

for linha in "${SEGREDOS[@]}"; do
  IFS='|' read -r nome var descricao <<< "$linha"
  valor="${!var:-}"

  if [ -z "$valor" ]; then
    echo
    echo "── $nome"
    echo "   $descricao"
    printf "   valor (ENTER em branco pula): "
    read -rs valor
    echo
  else
    echo
    echo "── $nome  (valor veio de \$$var)"
  fi

  if [ -z "$valor" ]; then
    echo "   pulado."
    pulados+=("$nome")
    continue
  fi

  az keyvault secret set --vault-name "$COFRE" --name "$nome" --value "$valor" \
      --output none 2>/dev/null || {
    echo "   FALHOU ao gravar." >&2
    falhos+=("$nome")
    continue
  }

  # A CONFERÊNCIA É O PONTO DO SCRIPT. `secret set` pode sair 0 e o valor não
  # ser o que se pensa (espaço no fim colado de um copiar-colar é o caso
  # clássico). Comparo o SHA-256 dos dois lados: prova que bate sem imprimir o
  # segredo em lugar nenhum.
  volta="$(az keyvault secret show --vault-name "$COFRE" --name "$nome" \
             --query value -o tsv 2>/dev/null || true)"
  h_local="$(printf '%s' "$valor"  | sha256sum | cut -c1-16)"
  h_cofre="$(printf '%s' "$volta"  | sha256sum | cut -c1-16)"

  if [ "$h_local" = "$h_cofre" ]; then
    echo "   gravado e conferido (sha256 $h_local)."
    gravados+=("$nome")
  else
    echo "   GRAVOU MAS NÃO CONFERE — local $h_local, cofre $h_cofre." >&2
    echo "   Suspeite de espaço em branco no fim do valor colado." >&2
    falhos+=("$nome")
  fi
  unset valor volta
done

# ── o placar ───────────────────────────────────────────────────────────────
echo
echo "─────────────────────────────────────────────"
[ ${#gravados[@]} -gt 0 ] && echo "gravados e conferidos: ${gravados[*]}"
[ ${#pulados[@]}  -gt 0 ] && echo "pulados:               ${pulados[*]}"
[ ${#falhos[@]}   -gt 0 ] && echo "FALHARAM:              ${falhos[*]}"

if [ ${#falhos[@]} -gt 0 ]; then
  echo
  echo "Saindo com erro: um segredo que não entrou vira falha de runtime, e o" >&2
  echo "sintoma aparece longe daqui." >&2
  exit 1
fi

echo
echo "Pronto."

# REINICIAR NÃO É OPCIONAL. A referência de cofre é resolvida quando a app
# INICIA; um segredo gravado depois disso não chega sozinho na app rodando.
RG="$(terraform output -raw resource_group 2>/dev/null || true)"
IO="$(terraform output -raw function_app_io 2>/dev/null || true)"
CALC="$(terraform output -raw function_app_calc 2>/dev/null || true)"
if [ -n "$RG" ] && [ -n "$IO" ]; then
  echo
  echo "Reinicie as duas apps para elas relerem o cofre — a referência só é"
  echo "resolvida no boot, então segredo gravado depois não chega sozinho:"
  echo
  echo "  az functionapp restart -g $RG -n $IO"
  echo "  az functionapp restart -g $RG -n $CALC"
else
  echo
  echo "Reinicie as duas Function Apps (a referência de cofre só é resolvida no"
  echo "boot): az functionapp restart -g <rg> -n <app>"
fi
