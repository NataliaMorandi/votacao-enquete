#!/usr/bin/env bash
# ------------------------------------------------------------------
# nova-enquete.sh — cria uma enquete e imprime tudo para votar/consultar
#
# Uso:
#   ./scripts/nova-enquete.sh "Título" "Descrição" <duração_min> "Opção 1" "Opção 2" ["Opção 3"...]
#
# Exemplo:
#   ./scripts/nova-enquete.sh "Onde almoçar?" "Sexta, 12h" 30 "Pizza" "Japonês" "Vegetariano"
#
# A URL da API é pega do Terraform (ou use API_URL=http://IP:3000 ./scripts/nova-enquete.sh ...)
# ------------------------------------------------------------------
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$#" -lt 4 ]; then
  echo "Uso: $0 \"Título\" \"Descrição\" <duração_min> \"Opção 1\" \"Opção 2\" [\"Opção 3\"...]"
  exit 1
fi

TITULO="$1"
DESCRICAO="$2"
DURACAO="$3"
shift 3
OPCOES=("$@")

if [ "${#OPCOES[@]}" -lt 2 ]; then
  echo "Informe pelo menos 2 opções."
  exit 1
fi

if [ -z "${API_URL:-}" ]; then
  if ! API_URL=$(terraform -chdir="$RAIZ/infra/terraform" output -raw api_url 2>/dev/null); then
    echo "Não consegui obter a URL via Terraform. Use: API_URL=http://IP:3000 $0 ..."
    exit 1
  fi
fi

echo "==> Criando enquete em $API_URL"

BODY=$(python3 - "$TITULO" "$DESCRICAO" "$DURACAO" "${OPCOES[@]}" <<'PY'
import json, sys
titulo, descricao, duracao = sys.argv[1], sys.argv[2], int(sys.argv[3])
opcoes = sys.argv[4:]
print(json.dumps({
    "titulo": titulo,
    "descricao": None if descricao in ("-", "") else descricao,
    "duracao_minutos": duracao,
    "opcoes": opcoes,
}, ensure_ascii=False))
PY
)

RESP=$(curl -sS -X POST "$API_URL/enquetes" -H 'Content-Type: application/json' -d "$BODY")

if echo "$RESP" | grep -q '"error"'; then
  echo "Erro ao criar: $RESP"
  exit 1
fi

echo "$RESP" > /tmp/ultima-enquete.json

printf '%s' "" >/dev/null
python3 - "$API_URL" "$RESP" <<'PY'
import json, sys
api = sys.argv[1]
d = json.loads(sys.argv[2])

print()
print("ENQUETE CRIADA")
print("  id      :", d["id"])
print("  titulo  :", d["titulo"])
print("  status  :", d["status"])
print("  abertura:", d["abertura"])
print("  prazo   :", d["prazo"])
print()
print("  Opcoes:")
for o in d["opcoes"]:
    print(f'   {o["ordem"]}) {o["rotulo"]}')
    print(f'      id: {o["id"]}')

primeira = d["opcoes"][0]["id"]
print()
print("Resultado:")
print(f'  curl -s {api}/enquetes/{d["id"]}/resultado | python3 -m json.tool')
print()
print("Votar (troque o CPF; use o id da opcao desejada):")
print(f'  curl -s -X POST {api}/enquetes/{d["id"]}/votos \\')
print('    -H "Content-Type: application/json" \\')
print(f'    -d \'{{"cpf":"11122233344","opcao_id":"{primeira}"}}\'')
print()
print("Resultado no navegador (JSON):")
print(f'  {api}/enquetes/{d["id"]}/resultado')
PY

echo
echo "(resposta completa salva em /tmp/ultima-enquete.json)"
