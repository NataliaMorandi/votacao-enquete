#!/usr/bin/env bash
# ==================================================================
# deploy-cli.sh — sobe TODA a infraestrutura usando apenas AWS CLI
# (equivalente ao Terraform, para aprender os comandos por baixo)
#
# Uso:
#   ./scripts/deploy-cli.sh            # cria tudo (idempotente)
#   ./scripts/deploy-cli.sh destroy    # apaga tudo
#
# Variáveis (opcionais):
#   AWS_PROFILE=lab2                 perfil do ~/.aws/config
#   AWS_REGION=us-east-1
#   PROJETO=votacao
#   REPO_URL=https://github.com/USUARIO/votacao-enquete.git
#   INSTANCE_PROFILE=LabInstanceProfile
#   LAMBDA_ROLE_ARN=arn:aws:iam::123:role/LabRole
#   CIDR_GRAFANA=177.9.113.167/32
#   TIPO_INSTANCIA=t3.micro
# ==================================================================
set -euo pipefail

REGIAO="${AWS_REGION:-us-east-1}"
PROJETO="${PROJETO:-votacao}"
REPO_URL="${REPO_URL:-https://github.com/NataliaMorandi/votacao-enquete.git}"
INSTANCE_PROFILE="${INSTANCE_PROFILE:-LabInstanceProfile}"
CIDR_GRAFANA="${CIDR_GRAFANA:-0.0.0.0/0}"
TIPO_INSTANCIA="${TIPO_INSTANCIA:-t3.micro}"
# Alarme de fila: produção 100/5 min; demo na sala 5/1 min
ALARME_THRESHOLD="${ALARME_THRESHOLD:-100}"
ALARME_PERIODOS="${ALARME_PERIODOS:-5}"

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
SAIDA_DIR="$RAIZ/infra/aws-cli"
SAIDA="$SAIDA_DIR/lab-outputs.env"

verde()   { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
amarelo() { printf '\033[1;33m!! %s\033[0m\n' "$*"; }
erro()    { printf '\033[1;31mERRO: %s\033[0m\n' "$*" >&2; exit 1; }

aws_() { aws --region "$REGIAO" "$@"; }

CONTA=$(aws_ sts get-caller-identity --query Account --output text) \
  || erro "credenciais inválidas/expiradas. Renove no Vocareum e rode 'aws configure set aws_session_token ...'"

LAMBDA_ROLE_ARN="${LAMBDA_ROLE_ARN:-arn:aws:iam::${CONTA}:role/LabRole}"

# ==================================================================
# DESTROY
# ==================================================================
destruir() {
  amarelo "Apagando recursos do projeto '$PROJETO' na conta $CONTA ($REGIAO)"
  echo "Isso remove EC2, SNS, SQS, Lambda, EventBridge, log groups e alarme."
  read -r -p "Digite 'apagar' para confirmar: " RESPOSTA
  [ "$RESPOSTA" = "apagar" ] || erro "cancelado"

  verde "EventBridge"
  aws_ events remove-targets --rule "${PROJETO}-cron-1min" --ids "1" >/dev/null 2>&1 || true
  aws_ events delete-rule --name "${PROJETO}-cron-1min" >/dev/null 2>&1 || true

  verde "Lambda"
  aws_ lambda delete-function --function-name "${PROJETO}-close-expired-polls" >/dev/null 2>&1 || true

  verde "SNS/SQS"
  TOPIC_ARN=$(aws_ sns list-topics --query "Topics[?contains(TopicArn,'${PROJETO}-enquetes-eventos')].TopicArn | [0]" --output text)
  if [ -n "${TOPIC_ARN:-}" ] && [ "$TOPIC_ARN" != "None" ]; then
    for SUB in $(aws_ sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" \
                 --query "Subscriptions[].SubscriptionArn" --output text); do
      [ "$SUB" = "PendingConfirmation" ] || aws_ sns unsubscribe --subscription-arn "$SUB" || true
    done
    aws_ sns delete-topic --topic-arn "$TOPIC_ARN" || true
  fi
  QUEUE_URL=$(aws_ sqs get-queue-url --queue-name "${PROJETO}-tally-queue" --query QueueUrl --output text 2>/dev/null || true)
  [ -z "${QUEUE_URL:-}" ] || aws_ sqs delete-queue --queue-url "$QUEUE_URL" || true

  verde "CloudWatch"
  aws_ cloudwatch delete-alarms --alarm-names "${PROJETO}-fila-acumulando" >/dev/null 2>&1 || true
  aws_ logs delete-log-group --log-group-name /votacao/votes-api >/dev/null 2>&1 || true
  aws_ logs delete-log-group --log-group-name /votacao/tally-worker >/dev/null 2>&1 || true

  verde "EC2"
  IDS=$(aws_ ec2 describe-instances \
    --filters "Name=tag:Name,Values=${PROJETO}-app" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" --output text)
  if [ -n "$IDS" ]; then
    aws_ ec2 terminate-instances --instance-ids $IDS >/dev/null
    echo "terminando: $IDS (aguardando...)"
    aws_ ec2 wait instance-terminated --instance-ids $IDS
  fi

  # Volume EBS fica órfão (delete_on_termination=false) — apaga também
  sleep 5
  VOLS=$(aws_ ec2 describe-volumes --filters "Name=tag:Name,Values=${PROJETO}-app" "Name=status,Values=available" \
    --query "Volumes[].VolumeId" --output text)
  [ -z "$VOLS" ] || aws_ ec2 delete-volume --volume-ids $VOLS

  verde "Security Group"
  SG=$(aws_ ec2 describe-security-groups --filters "Name=group-name,Values=${PROJETO}-sg" \
        --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
  if [ -n "${SG:-}" ] && [ "$SG" != "None" ]; then
    aws_ ec2 delete-security-group --group-id "$SG" >/dev/null 2>&1 || amarelo "SG $SG em uso; tente de novo em 1 min"
  fi

  verde "Elastic IP (se existir, associado a esta conta)"
  aws_ ec2 describe-addresses --query "Addresses[].[PublicIp,AllocationId,InstanceId]" --output table || true
  amarelo "Se sobrar EIP na lista acima, libere: aws ec2 release-address --allocation-id eipalloc-... "

  rm -f "$SAIDA"
  verde "Destruição concluída"
}

if [ "${1:-}" = "destroy" ]; then
  destruir
  exit 0
fi

# ==================================================================
# CREATE
# ==================================================================
verde "Conta $CONTA · região $REGIAO · projeto $PROJETO"
mkdir -p "$SAIDA_DIR"

# ---------------------------------------------------------------- SNS
verde "[1/9] SNS topic"
TOPIC_ARN=$(aws_ sns create-topic --name "${PROJETO}-enquetes-eventos" --query TopicArn --output text)
echo "    $TOPIC_ARN"

# ---------------------------------------------------------------- SQS
verde "[2/9] SQS queue"
QUEUE_URL=$(aws_ sqs create-queue \
  --queue-name "${PROJETO}-tally-queue" \
  --attributes VisibilityTimeout=60,MessageRetentionPeriod=345600,ReceiveMessageWaitTimeSeconds=20,MaximumMessageSize=262144 \
  --query QueueUrl --output text)
QUEUE_ARN=$(aws_ sqs get-queue-attributes --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn --query "Attributes.QueueArn" --output text)
echo "    $QUEUE_URL"

POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "PermitirSNS",
    "Effect": "Allow",
    "Principal": { "Service": "sns.amazonaws.com" },
    "Action": "sqs:SendMessage",
    "Resource": "$QUEUE_ARN",
    "Condition": { "ArnEquals": { "aws:SourceArn": "$TOPIC_ARN" } }
  }]
}
JSON
)
aws_ sqs set-queue-attributes --queue-url "$QUEUE_URL" \
  --attributes "{\"Policy\":$(printf '%s' "$POLICY" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}" >/dev/null

# ------------------------------------------------------- subscription
verde "[3/9] SNS -> SQS (fan-out)"
JA_EXISTE=$(aws_ sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" \
  --query "Subscriptions[?Endpoint=='$QUEUE_ARN'].SubscriptionArn" --output text)
if [ -z "$JA_EXISTE" ]; then
  aws_ sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs \
    --notification-endpoint "$QUEUE_ARN" --attributes RawMessageDelivery=true >/dev/null
  echo "    subscription criada"
else
  echo "    subscription já existia"
fi

# ------------------------------------------------------------ log groups
verde "[4/9] CloudWatch Log Groups"
for GRUPO in /votacao/votes-api /votacao/tally-worker; do
  aws_ logs create-log-group --log-group-name "$GRUPO" 2>/dev/null || true
  aws_ logs put-retention-policy --log-group-name "$GRUPO" --retention-in-days 7 || true
  echo "    $GRUPO"
done

# ------------------------------------------------------------ security group
verde "[5/9] Security Group"
VPC=$(aws_ ec2 describe-vpcs --filters Name=isDefault,Values=true --query "Vpcs[0].VpcId" --output text)
SG_ID=$(aws_ ec2 describe-security-groups \
  --filters Name=group-name,Values="${PROJETO}-sg" Name=vpc-id,Values="$VPC" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)

if [ -z "${SG_ID:-}" ] || [ "$SG_ID" = "None" ]; then
  SG_ID=$(aws_ ec2 create-security-group --group-name "${PROJETO}-sg" \
    --description "API e Grafana do sistema de enquetes" --vpc-id "$VPC" \
    --query GroupId --output text)
  echo "    criado: $SG_ID"
else
  echo "    já existia: $SG_ID"
fi

aws_ ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --ip-permissions 'IpProtocol=tcp,FromPort=3000,ToPort=3000,IpRanges=[{CidrIp=0.0.0.0/0,Description="API - Lambda precisa alcancar"}]' >/dev/null 2>&1 || true
aws_ ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=3001,ToPort=3001,IpRanges=[{CidrIp=$CIDR_GRAFANA,Description=\"Grafana\"}]" >/dev/null 2>&1 || true

# ------------------------------------------------------------ senhas
POSTGRES_PASSWORD=$(openssl rand -hex 16)
GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 10)
INTERNAL_TOKEN=$(openssl rand -hex 24)

# ------------------------------------------------------------ EC2
verde "[6/9] EC2 + user-data"
AMI=$(aws_ ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query "Parameters[0].Value" --output text)
SUBNET=$(aws_ ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" \
  --query "Subnets[0].SubnetId" --output text)

USERDATA=/tmp/votacao-user-data.sh
{
  echo '#!/bin/bash'
  echo 'set -e'
  echo "cat > /etc/votacao-bootstrap.env <<'ENVEOF'"
  printf 'REPO_URL=%s\n'              "$REPO_URL"
  printf 'POSTGRES_PASSWORD=%s\n'     "$POSTGRES_PASSWORD"
  printf 'GRAFANA_ADMIN_PASSWORD=%s\n' "$GRAFANA_ADMIN_PASSWORD"
  printf 'INTERNAL_TOKEN=%s\n'        "$INTERNAL_TOKEN"
  printf 'SNS_TOPIC_ARN=%s\n'         "$TOPIC_ARN"
  printf 'SQS_QUEUE_URL=%s\n'         "$QUEUE_URL"
  printf 'AWS_REGION=%s\n'            "$REGIAO"
  echo 'ENVEOF'
  echo 'chmod 600 /etc/votacao-bootstrap.env'
  echo 'dnf install -y git'
  echo "git clone $REPO_URL /tmp/votacao-repo || true"
  echo 'bash /tmp/votacao-repo/scripts/ec2-bootstrap.sh'
} > "$USERDATA"

INSTANCE_ID=$(aws_ ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PROJETO}-app" "Name=instance-state-name,Values=pending,running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text 2>/dev/null || true)

if [ -z "${INSTANCE_ID:-}" ] || [ "$INSTANCE_ID" = "None" ]; then
  INSTANCE_ID=$(aws_ ec2 run-instances \
    --image-id "$AMI" \
    --instance-type "$TIPO_INSTANCIA" \
    --subnet-id "$SUBNET" \
    --security-group-ids "$SG_ID" \
    --associate-public-ip-address \
    --iam-instance-profile "Name=$INSTANCE_PROFILE" \
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled" \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":20,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":false}}]' \
    --user-data "file://$USERDATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJETO}-app}]" \
    --query "Instances[0].InstanceId" --output text)
  echo "    criada: $INSTANCE_ID"
else
  echo "    já existia: $INSTANCE_ID"
fi

aws_ ec2 wait instance-running --instance-ids "$INSTANCE_ID"
IP=$(aws_ ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
echo "    IP público: $IP"

echo "    aguardando a aplicação subir (até 8 min)..."
for i in $(seq 1 48); do
  if curl -fsS -m 5 "http://$IP:3000/health" >/dev/null 2>&1; then
    echo "    API respondeu após ~$((i * 10))s"
    break
  fi
  [ "$i" -eq 48 ] && amarelo "API ainda não respondeu. Veja: aws ssm start-session --target $INSTANCE_ID"
  sleep 10
done

# ------------------------------------------------------------ Lambda
verde "[7/9] Lambda"
ZIP=/tmp/votacao-lambda.zip
python3 -c "import shutil; shutil.make_archive('/tmp/votacao-lambda','zip','$RAIZ/lambda/close-expired-polls')"

if aws_ lambda get-function --function-name "${PROJETO}-close-expired-polls" >/dev/null 2>&1; then
  aws_ lambda update-function-code --function-name "${PROJETO}-close-expired-polls" \
    --zip-file "fileb://$ZIP" >/dev/null
  aws_ lambda wait function-updated --function-name "${PROJETO}-close-expired-polls"
  aws_ lambda update-function-configuration --function-name "${PROJETO}-close-expired-polls" \
    --environment "Variables={API_URL=http://$IP:3000,INTERNAL_TOKEN=$INTERNAL_TOKEN}" >/dev/null
  echo "    atualizada"
else
  aws_ lambda create-function \
    --function-name "${PROJETO}-close-expired-polls" \
    --description "Fecha enquetes com prazo vencido" \
    --runtime nodejs20.x --handler index.handler \
    --role "$LAMBDA_ROLE_ARN" \
    --zip-file "fileb://$ZIP" \
    --timeout 30 --memory-size 128 \
    --environment "Variables={API_URL=http://$IP:3000,INTERNAL_TOKEN=$INTERNAL_TOKEN}" >/dev/null
  echo "    criada"
fi
LAMBDA_ARN=$(aws_ lambda get-function --function-name "${PROJETO}-close-expired-polls" \
  --query "Configuration.FunctionArn" --output text)

# ------------------------------------------------------------ EventBridge
verde "[8/9] EventBridge (cron 1 min)"
aws_ events put-rule --name "${PROJETO}-cron-1min" \
  --schedule-expression "rate(1 minute)" \
  --state ENABLED --description "Dispara a Lambda de encerramento" >/dev/null
aws_ events put-targets --rule "${PROJETO}-cron-1min" \
  --targets "Id=1,Arn=$LAMBDA_ARN" >/dev/null
aws_ lambda add-permission --function-name "${PROJETO}-close-expired-polls" \
  --statement-id PermitirEventBridge --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "arn:aws:events:${REGIAO}:${CONTA}:rule/${PROJETO}-cron-1min" >/dev/null 2>&1 \
  || echo "    (permissão já existia)"

# ------------------------------------------------------------ Alarme
verde "[9/9] Alarme de fila"
aws_ cloudwatch put-metric-alarm \
  --alarm-name "${PROJETO}-fila-acumulando" \
  --alarm-description "Mais de 100 mensagens na fila por 5 minutos" \
  --namespace AWS/SQS --metric-name ApproximateNumberOfMessagesVisible \
  --dimensions "Name=QueueName,Value=${PROJETO}-tally-queue" \
  --statistic Maximum --period 60 --evaluation-periods "$ALARME_PERIODOS" --threshold "$ALARME_THRESHOLD" \
  --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching >/dev/null

# ------------------------------------------------------------ saída
cat > "$SAIDA" <<ENV
# Gerado por scripts/deploy-cli.sh em $(date -Iseconds)
CONTA=$CONTA
REGIAO=$REGIAO
INSTANCE_ID=$INSTANCE_ID
IP_PUBLICO=$IP
API_URL=http://$IP:3000
GRAFANA_URL=http://$IP:3001
GRAFANA_ADMIN_PASSWORD=$GRAFANA_ADMIN_PASSWORD
TOPIC_ARN=$TOPIC_ARN
QUEUE_URL=$QUEUE_URL
QUEUE_ARN=$QUEUE_ARN
LAMBDA_ARN=$LAMBDA_ARN
SG_ID=$SG_ID
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
INTERNAL_TOKEN=$INTERNAL_TOKEN
ENV
chmod 600 "$SAIDA"

verde "TUDO PRONTO"
cat <<TXT

  API      : http://$IP:3000
  Grafana  : http://$IP:3001  (admin / $GRAFANA_ADMIN_PASSWORD)
  Lambda   : ${PROJETO}-close-expired-polls
  SNS      : $TOPIC_ARN
  SQS      : $QUEUE_URL

  Senhas e IDs salvos em: $SAIDA

  Testar:  ./scripts/demo.sh http://$IP:3000 30
  Apagar:  ./scripts/deploy-cli.sh destroy

TXT

amarelo "Para IP fixo: aloque um Elastic IP no console e associe à instância $INSTANCE_ID,"
amarelo "depois rode: aws lambda update-function-configuration --function-name ${PROJETO}-close-expired-polls \\"
amarelo "  --environment Variables={API_URL=http://IP_FIXO:3000,INTERNAL_TOKEN=$INTERNAL_TOKEN}"
