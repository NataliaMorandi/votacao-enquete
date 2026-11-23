#!/usr/bin/env bash
# ------------------------------------------------------------------
# liberar-meu-ip.sh — atualiza a regra do Grafana (porta 3001) para o
# seu IP público atual. Útil porque o IP da operadora muda.
#
# Uso: AWS_PROFILE=lab2 ./scripts/liberar-meu-ip.sh [nova-ip]
# ------------------------------------------------------------------
set -euo pipefail

REGIAO="${AWS_REGION:-us-east-1}"
PROJETO="${PROJETO:-votacao}"
CIDR="${1:-}"

aws_() { aws --region "$REGIAO" "$@"; }

if [ -z "$CIDR" ]; then
  IP=$(curl -fsS https://checkip.amazonaws.com)
  CIDR="$IP/32"
fi

SG=$(aws_ ec2 describe-security-groups --filters "Name=group-name,Values=${PROJETO}-sg" \
  --query "SecurityGroups[0].GroupId" --output text)

[ -n "$SG" ] && [ "$SG" != "None" ] || { echo "Security group ${PROJETO}-sg não encontrado"; exit 1; }

echo "SG: $SG · liberando 3001 para $CIDR"

# remove regras antigas da 3001 e adiciona a nova
ATUAIS=$(aws_ ec2 describe-security-groups --group-ids "$SG" \
  --query "SecurityGroups[0].IpPermissions[?FromPort==\`3001\`].IpRanges[].CidrIp" --output text)

for ANTIGO in $ATUAIS; do
  [ "$ANTIGO" = "0.0.0.0/0" ] && continue
  aws_ ec2 revoke-security-group-ingress --group-id "$SG" \
    --ip-permissions "IpProtocol=tcp,FromPort=3001,ToPort=3001,IpRanges=[{CidrIp=$ANTIGO}]" >/dev/null 2>&1 || true
  echo "  removida: $ANTIGO"
done

aws_ ec2 authorize-security-group-ingress --group-id "$SG" \
  --ip-permissions "IpProtocol=tcp,FromPort=3001,ToPort=3001,IpRanges=[{CidrIp=$CIDR,Description=Grafana}]" >/dev/null 2>&1 || true

echo "Pronto. Acesse: http://<IP-DA-EC2>:3001"
