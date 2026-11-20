#!/usr/bin/env bash
# ------------------------------------------------------------------
# up.sh — liga a EC2, atualiza a URL da Lambda e mostra os endereços
# Uso: ./scripts/up.sh
# ------------------------------------------------------------------
set -euo pipefail

TF_DIR="$(cd "$(dirname "$0")/../infra/terraform" && pwd)"
REGION="${AWS_REGION:-us-east-1}"

INSTANCE_ID=$(terraform -chdir="$TF_DIR" output -raw instance_id)
LAMBDA=$(terraform -chdir="$TF_DIR" output -raw lambda_nome)

echo "==> Ligando instância $INSTANCE_ID"
aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo "==> IP público: $IP"
echo "==> Atualizando API_URL da Lambda ($LAMBDA)"
aws lambda update-function-configuration --region "$REGION" \
  --function-name "$LAMBDA" \
  --environment "Variables={API_URL=http://$IP:3000,INTERNAL_TOKEN=$(terraform -chdir="$TF_DIR" output -raw internal_token)}" \
  >/dev/null

echo ""
echo "Aguardando a aplicação responder (~60s no primeiro boot)..."
for i in $(seq 1 30); do
  if curl -fsS "http://$IP:3000/health" >/dev/null 2>&1; then
    echo "API OK após ${i}0s"
    break
  fi
  sleep 10
done

GRAFANA_PASS=$(terraform -chdir="$TF_DIR" output -raw grafana_admin_password)

echo ""
echo "-----------------------------------------------"
echo " API     : http://$IP:3000"
echo " Grafana : http://$IP:3001   (admin / $GRAFANA_PASS)"
echo "-----------------------------------------------"
