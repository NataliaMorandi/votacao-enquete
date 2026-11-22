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

if echo "$ENQUETE" | grep -q '"error"'; then
  echo "Erro ao criar enquete: $ENQUETE"
  exit 1
fi

# Extrai id da enquete e ids das opções com Python (parsing confiável de JSON)
read -r ID OPT1 OPT2 OPT3 <<< "$(echo "$ENQUETE" | python3 -c '
import json, sys
d = json.load(sys.stdin)
ids = [o["id"] for o in d["opcoes"]]
while len(ids) < 3:
    ids.append(ids[0])
print(d["id"], *ids[:3])
')"

echo "==> Enquete: $ID"
echo "==> Opções: $OPT1 | $OPT2 | $OPT3"
echo "==> Enviando $N votos (CPFs distintos)"

OPCOES=("$OPT1" "$OPT2" "$OPT3")
i=0
while [ "$i" -lt "$N" ]; do
  OPCAO="${OPCOES[$((i % 3))]}"
  CPF=$(printf '1234567%04d' "$i")
  CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$API/enquetes/$ID/votos" \
    -H 'Content-Type: application/json' \
    -d "{\"cpf\":\"$CPF\",\"opcao_id\":\"$OPCAO\"}")
  printf "%s " "$CODE"
  i=$((i + 1))
done
echo ""

echo "==> Aguardando o worker contabilizar..."
sleep 3

echo "==> Resultado:"
curl -sS "$API/enquetes/$ID/resultado" | python3 -m json.tool
