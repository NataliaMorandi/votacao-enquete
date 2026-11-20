#!/usr/bin/env bash
# ------------------------------------------------------------------
# demo.sh — gera carga para demonstrar logs e dashboard
# Cria uma enquete, injeta N votos e imprime o resultado.
# Uso: ./scripts/demo.sh [API_URL] [NUM_VOTOS]
# ------------------------------------------------------------------
set -euo pipefail

API="${1:-http://localhost:3000}"
N="${2:-30}"

echo "==> Criando enquete em $API"
ENQUETE=$(curl -sS -X POST "$API/enquetes" \
  -H 'Content-Type: application/json' \
  -d '{
        "titulo": "Onde vamos almoçar?",
        "descricao": "Enquete de demonstração do trabalho",
        "duracao_minutos": 30,
        "opcoes": ["Opção A - Pizza", "Opção B - Japonês", "Opção C - Vegetariano"]
      }')

echo "$ENQUETE" | head -c 400; echo

ID=$(echo "$ENQUETE" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
OPCOES=$(echo "$ENQUETE" | grep -o '"id":"[^"]*"' | tail -n +2 | sed 's/"id":"//;s/"//')

echo "==> Enquete: $ID"
echo "==> Enviando $N votos (CPFs distintos)"

i=0
for OPCAO in $OPCOES; do
  for j in 1 2 3 4 5 6 7 8 9 10; do
    i=$((i+1))
    [ "$i" -gt "$N" ] && break 2
    CPF=$(printf '1234567%04d' "$i")
    curl -sS -o /dev/null -w "%{http_code} " -X POST "$API/enquetes/$ID/votos" \
      -H 'Content-Type: application/json' \
      -d "{\"cpf\":\"$CPF\",\"opcao_id\":\"$OPCAO\"}"
  done
done
echo ""

echo "==> Aguardando o worker contabilizar..."
sleep 3

echo "==> Resultado:"
curl -sS "$API/enquetes/$ID/resultado"
echo
