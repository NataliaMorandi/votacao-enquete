#!/usr/bin/env bash
# ------------------------------------------------------------------
# lab-power.sh — liga/desliga a EC2 criada pelo deploy-cli.sh
#
# Uso:
#   AWS_PROFILE=lab2 ./scripts/lab-power.sh start
#   AWS_PROFILE=lab2 ./scripts/lab-power.sh stop
#
# Lê os IDs de infra/aws-cli/lab-outputs.env (gerado pelo deploy-cli.sh)
# e, ao ligar, atualiza a URL da Lambda (o IP público muda a cada start).
# ------------------------------------------------------------------
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
ARQ="$RAIZ/infra/aws-cli/lab-outputs.env"
REGIAO="${AWS_REGION:-us-east-1}"

[ -f "$ARQ" ] || { echo "Não encontrei $ARQ. Rode ./scripts/deploy-cli.sh primeiro."; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ARQ"; set +a

aws_() { aws --region "$REGIAO" "$@"; }
ACAO="${1:-}"

case "$ACAO" in
  start)
    echo "Ligando $INSTANCE_ID..."
    aws_ ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
    aws_ ec2 wait instance-running --instance-ids "$INSTANCE_ID"

    IP=$(aws_ ec2 describe-instances --instance-ids "$INSTANCE_ID" \
      --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

    echo "IP público: $IP — atualizando a Lambda"
    aws_ lambda update-function-configuration \
      --function-name "votacao-close-expired-polls" \
      --environment "Variables={API_URL=http://$IP:3000,INTERNAL_TOKEN=$INTERNAL_TOKEN}" >/dev/null

    echo "Aguardando a API responder..."
    for i in $(seq 1 30); do
      if curl -fsS -m 5 "http://$IP:3000/health" >/dev/null 2>&1; then
        echo "API ok após ~$((i * 5))s"
        break
      fi
      sleep 5
    done

    # atualiza o arquivo de saída com o IP novo
    sed -i "s|^IP_PUBLICO=.*|IP_PUBLICO=$IP|; s|^API_URL=.*|API_URL=http://$IP:3000|; s|^GRAFANA_URL=.*|GRAFANA_URL=http://$IP:3001|" "$ARQ"

    echo
    echo "App     : http://$IP:3000"
    echo "Grafana : http://$IP:3001"
    echo "(se o Grafana não abrir: ./scripts/liberar-meu-ip.sh)"
    ;;

  stop)
    echo "Parando $INSTANCE_ID..."
    aws_ ec2 stop-instances --instance-ids "$INSTANCE_ID" >/dev/null
    aws_ ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
    echo "Parada. Compute = US$ 0,00 (EBS continua cobrando centavos)."
    ;;

  *)
    echo "Uso: AWS_PROFILE=lab2 $0 {start|stop}"
    exit 1
    ;;
esac
