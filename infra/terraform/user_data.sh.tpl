#!/bin/bash
# ------------------------------------------------------------------
# user-data da EC2: instala Docker e sobe o docker-compose
# Gerado pelo Terraform (templatefile) — NÃO editar na instância
# ------------------------------------------------------------------
set -e
# Log direto em arquivo (sem pipe)
exec >> /var/log/votacao-boot.log 2>&1

echo "==> [1/6] Instalando pacotes base"
dnf update -y
# curl NÃO entra na lista: na AL2023 ele conflita com o curl-minimal já instalado
dnf install -y docker git

systemctl enable --now docker
usermod -aG docker ec2-user

echo "==> [2/6] Configurando swap (2 GB) para caber tudo em t3.micro"
if [ ! -f /swapfile ]; then
  dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "==> [3/6] Instalando docker compose v2 + buildx"
ARQ=$(uname -m)
case "$ARQ" in
  x86_64)  COMPOSE_ARQ=x86_64;  BUILDX_ARQ=amd64 ;;
  aarch64) COMPOSE_ARQ=aarch64; BUILDX_ARQ=arm64 ;;
  *) echo "arquitetura nao suportada: $ARQ"; exit 1 ;;
esac
curl -fsSL --retry 5 --retry-delay 2 "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$COMPOSE_ARQ" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# buildx >= 0.17 é exigido pelo compose v2 para buildar imagens
mkdir -p /usr/local/lib/docker/cli-plugins
# Versão do buildx pelo redirect de "releases/latest" (evita rate limit da API do GitHub)
BUILDX_TAG=$(curl -fsSLI -o /dev/null -w '%%{url_effective}' \
  https://github.com/docker/buildx/releases/latest | sed 's|.*/tag/v||')
[ -n "$BUILDX_TAG" ] || { echo "ERRO: nao foi possivel descobrir a versao do buildx"; exit 1; }
curl -fsSL --retry 5 --retry-delay 2 "https://github.com/docker/buildx/releases/download/v$${BUILDX_TAG}/buildx-v$${BUILDX_TAG}.linux-$BUILDX_ARQ" \
  -o /usr/local/lib/docker/cli-plugins/docker-buildx
chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx
docker buildx version

echo "==> [4/6] Clonando aplicação"
rm -rf /opt/votacao
if ! git clone ${repo_url} /opt/votacao; then
  echo "AVISO: clone falhou. Envie os arquivos via 'scp -r ./ usuario@IP:/opt/votacao' e rode docker-compose up -d"
  mkdir -p /opt/votacao
fi
cd /opt/votacao

echo "==> [5/6] Gerando .env"
cat > .env <<'ENVEOF'
POSTGRES_PASSWORD=${db_password}
REDIS_URL=redis://redis:6379
AWS_REGION=${aws_region}
SNS_TOPIC_ARN=${sns_topic_arn}
SQS_QUEUE_URL=${sqs_queue_url}
INTERNAL_TOKEN=${internal_token}
GRAFANA_ADMIN_PASSWORD=${grafana_pass}
ENVEOF
chmod 600 .env

echo "==> [6/6] Subindo containers"
if [ -f docker-compose.yml ]; then
  /usr/local/bin/docker-compose up -d --build
else
  echo "AVISO: docker-compose.yml não encontrado em /opt/votacao"
fi

echo "==> Boot finalizado"
