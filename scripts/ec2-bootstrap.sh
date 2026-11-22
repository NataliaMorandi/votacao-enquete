#!/usr/bin/env bash
# ------------------------------------------------------------------
# ec2-bootstrap.sh — prepara a EC2 e sobe os containers
#
# Executado pelo user-data da instância. Lê as configurações de
# /etc/votacao-bootstrap.env (gerado pelo deploy-cli.sh ou pelo Terraform).
#
# Pode ser rodado de novo na mão para reaplicar:
#   sudo bash /opt/votacao/scripts/ec2-bootstrap.sh
# ------------------------------------------------------------------
set -euo pipefail

exec > >(tee -a /var/log/votacao-boot.log | logger -t votacao-boot) 2>&1

ARQ_ENV=/etc/votacao-bootstrap.env
if [ ! -f "$ARQ_ENV" ]; then
  echo "ERRO: $ARQ_ENV não encontrado"
  exit 1
fi

# shellcheck disable=SC1090
set -a; source "$ARQ_ENV"; set +a

: "${REPO_URL:?REPO_URL não definido}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD não definido}"
: "${SNS_TOPIC_ARN:?SNS_TOPIC_ARN não definido}"
: "${SQS_QUEUE_URL:?SQS_QUEUE_URL não definido}"
: "${INTERNAL_TOKEN:?INTERNAL_TOKEN não definido}"
: "${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD não definido}"
AWS_REGION="${AWS_REGION:-us-east-1}"

echo "==> [1/6] Pacotes base (docker + git)"
dnf install -y docker git
systemctl enable --now docker
usermod -aG docker ec2-user || true

echo "==> [2/6] Swap 2 GB"
if [ ! -f /swapfile ]; then
  dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "==> [3/6] docker compose v2 + buildx"
ARQ=$(uname -m)
case "$ARQ" in
  x86_64)  COMPOSE_ARQ=x86_64 ;;
  aarch64) COMPOSE_ARQ=aarch64 ;;
  *) echo "arquitetura não suportada: $ARQ"; exit 1 ;;
esac

curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$COMPOSE_ARQ" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

mkdir -p /usr/local/lib/docker/cli-plugins
BUILDX_TAG=$(curl -fsSL https://api.github.com/repos/docker/buildx/releases/latest \
  | grep -m1 '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
curl -fSL "https://github.com/docker/buildx/releases/download/v${BUILDX_TAG}/buildx-v${BUILDX_TAG}.linux-$COMPOSE_ARQ" \
  -o /usr/local/lib/docker/cli-plugins/docker-buildx
chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx
docker buildx version

echo "==> [4/6] Clonando a aplicação"
rm -rf /opt/votacao
git clone "$REPO_URL" /opt/votacao
cd /opt/votacao

echo "==> [5/6] Gerando .env"
umask 077
cat > .env <<ENV
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
REDIS_URL=redis://redis:6379
AWS_REGION=$AWS_REGION
SNS_TOPIC_ARN=$SNS_TOPIC_ARN
SQS_QUEUE_URL=$SQS_QUEUE_URL
INTERNAL_TOKEN=$INTERNAL_TOKEN
GRAFANA_ADMIN_PASSWORD=$GRAFANA_ADMIN_PASSWORD
ENV
chmod 600 .env

echo "==> [6/6] Subindo containers"
/usr/local/bin/docker-compose up -d --build

echo "==> Bootstrap concluído"
