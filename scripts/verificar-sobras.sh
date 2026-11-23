#!/usr/bin/env bash
# ------------------------------------------------------------------
# verificar-sobras.sh — lista recursos do projeto que ainda existem
# Uso: AWS_PROFILE=lab2 ./scripts/verificar-sobras.sh [prefixo]
# Retorna código 1 se sobrar algo (útil para automação)
# ------------------------------------------------------------------
set -uo pipefail

PREFIXO="${1:-votacao}"
REGIAO="${AWS_REGION:-us-east-1}"

aws_() { aws --region "$REGIAO" "$@"; }

CONTA=$(aws_ sts get-caller-identity --query Account --output text 2>/dev/null) || {
  echo "Credenciais inválidas/expiradas."; exit 2;
}

echo "Conta: $CONTA · região: $REGIAO · prefixo: $PREFIXO"
echo

SOBROU=0
mostrar() {
  local titulo="$1"; shift
  local saida
  saida=$("$@" 2>/dev/null)
  if [ -z "$saida" ] || [ "$saida" = "None" ]; then
    printf '  %-28s %s\n' "$titulo" "ok (nenhum)"
  else
    printf '  %-28s %s\n' "$titulo" "ENCONTRADO"
    echo "$saida" | sed 's/^/      /'
    SOBROU=1
  fi
}

mostrar "EC2 instâncias" aws_ ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PREFIXO}-app" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[].Instances[].InstanceId" --output text

mostrar "EBS volumes (available)" aws_ ec2 describe-volumes \
  --filters "Name=status,Values=available" \
  --query "Volumes[].[VolumeId,Size]" --output text

mostrar "Elastic IPs" aws_ ec2 describe-addresses \
  --query "Addresses[].[PublicIp,AllocationId]" --output text

mostrar "Security Groups" aws_ ec2 describe-security-groups \
  --filters "Name=group-name,Values=${PREFIXO}-sg" \
  --query "SecurityGroups[].[GroupId,GroupName]" --output text

mostrar "SNS topics" aws_ sns list-topics \
  --query "Topics[?contains(TopicArn,'${PREFIXO}')].TopicArn" --output text

mostrar "SQS queues" aws_ sqs list-queues \
  --query "QueueUrls[?contains(@,'${PREFIXO}')]" --output text

mostrar "Lambda functions" aws_ lambda list-functions \
  --query "Functions[?contains(FunctionName,'${PREFIXO}')].FunctionName" --output text

mostrar "EventBridge rules" aws_ events list-rules \
  --query "Rules[?contains(Name,'${PREFIXO}')].Name" --output text

mostrar "Log groups" aws_ logs describe-log-groups \
  --query "logGroups[?contains(logGroupName,'${PREFIXO}')].logGroupName" --output text

mostrar "CloudWatch alarms" aws_ cloudwatch describe-alarms \
  --query "MetricAlarms[?contains(AlarmName,'${PREFIXO}')].AlarmName" --output text

echo
if [ "$SOBROU" -eq 0 ]; then
  echo "Limpo: nenhum recurso do projeto encontrado."
  exit 0
else
  echo "ATENÇÃO: há recursos acima que ainda podem estar cobrando."
  exit 1
fi
