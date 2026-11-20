#!/usr/bin/env bash
# ------------------------------------------------------------------
# down.sh — desliga a EC2 (dados persistem no EBS)
# Custo com a instância parada: apenas o volume EBS (~US$1,60/mês)
# ------------------------------------------------------------------
set -euo pipefail

TF_DIR="$(cd "$(dirname "$0")/../infra/terraform" && pwd)"
REGION="${AWS_REGION:-us-east-1}"

INSTANCE_ID=$(terraform -chdir="$TF_DIR" output -raw instance_id)

echo "==> Parando instância $INSTANCE_ID"
aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$INSTANCE_ID"

echo "Instância parada. Compute = US$0,00. EBS continua cobrando centavos."
echo "Para voltar: ./scripts/up.sh"
