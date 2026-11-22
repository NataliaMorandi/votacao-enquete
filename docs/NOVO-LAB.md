# Trocar de laboratório / recriar do zero

Este guia cobre três coisas:

- **A)** limpar o laboratório atual (o que já usamos)
- **B)** subir tudo em **outro** laboratório usando **AWS CLI** (`scripts/deploy-cli.sh`)
- **C)** recriar os mesmos recursos **manualmente no console**, para aprender

---

# A) Limpar o laboratório atual

## A.1 Renovar credenciais

A sessão do Vocareum dura ~4h. Em **AWS Details → Show**, copie as três linhas:

```bash
aws configure set aws_access_key_id     ASIA...
aws configure set aws_secret_access_key ...
aws configure set aws_session_token     IQoJ...
aws sts get-caller-identity     # deve mostrar a conta que queremos limpar
```

> ⚠️ Confira o `Account` na saída. `terraform destroy` apaga tudo o que está no
> **state local** (`infra/terraform/terraform.tfstate`), que hoje é da conta do lab 1.

## A.2 Ver o que será apagado

```bash
cd ~/votacao-enquete/infra/terraform
terraform plan -destroy
```

Esperado: ~16 recursos (EC2, SNS, SQS, Lambda, EventBridge, log groups, alarme, SG).
**Nenhum** `aws_iam_role` (usamos o `LabRole` do lab).

## A.3 Apagar

```bash
terraform destroy
```

Depois disso, estes **não** são removidos automaticamente e precisam de limpeza manual:

### Elastic IP (criado à mão, fora do Terraform)

```bash
aws ec2 describe-addresses --query "Addresses[].[PublicIp,AllocationId,InstanceId]" --output table
# desassociar e liberar (troque o ID):
aws ec2 disassociate-address --association-id eipassoc-XXXX
aws ec2 release-address --allocation-id eipalloc-XXXX
```

### Volume EBS (o disco raiz foi criado com `delete_on_termination = false`)

```bash
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query "Volumes[].[VolumeId,Size,Tags[?Key=='Name'].Value|[0]]" --output table
aws ec2 delete-volume --volume-id vol-XXXX
```

### Verificação final (não deve sobrar nada)

```bash
aws ec2 describe-instances --filters "Name=instance-state-name,Values=pending,running,stopped" \
  --query "Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key=='Name'].Value|[0]]" --output table
aws sns list-topics
aws sqs list-queues
aws lambda list-functions --query "Functions[?contains(FunctionName,'votacao')].FunctionName"
aws events list-rules --query "Rules[?contains(Name,'votacao')].Name"
aws logs describe-log-groups --query "logGroups[?contains(logGroupName,'votacao')].logGroupName"
aws cloudwatch describe-alarms --query "MetricAlarms[?contains(AlarmName,'votacao')].AlarmName"
aws ec2 describe-addresses --query "Addresses[].PublicIp"
```

Tudo deve retornar lista vazia (`[]`) ou tabela sem linhas.

---

# B) Subir tudo no novo laboratório (AWS CLI)

## B.1 Criar um perfil separado (evita misturar com o lab 1)

```bash
aws configure --profile lab2 set aws_access_key_id     ASIA...        # do lab 2
aws configure --profile lab2 set aws_secret_access_key ...
aws configure --profile lab2 set aws_session_token     IQoJ...
aws configure --profile lab2 set region us-east-1
aws configure --profile lab2 set output json

aws sts get-caller-identity --profile lab2
```

Anote o `Account` (será diferente do lab 1).

> Usar `--profile` é o que garante que você não vai rodar comando no lab errado.
> Dele, vale sempre exportar: `export AWS_PROFILE=lab2`.

## B.2 Descobrir o instance profile do novo lab

```bash
export AWS_PROFILE=lab2
aws iam list-instance-profiles --query "InstanceProfiles[].InstanceProfileName" --output table
aws iam get-role --role-name LabRole \
  --query "Role.AssumeRolePolicyDocument.Statement[].Principal.Service[]" --output text \
  | tr '\t' '\n' | grep -Ei 'lambda|ec2'
```

Esperado: `LabInstanceProfile` e `LabRole` (com `lambda.amazonaws.com` e `ec2.amazonaws.com`).

## B.3 Rodar o deploy por CLI

```bash
cd ~/votacao-enquete

export AWS_PROFILE=lab2
export AWS_REGION=us-east-1
export INSTANCE_PROFILE=LabInstanceProfile
export REPO_URL=https://github.com/NataliaMorandi/votacao-enquete.git
export CIDR_GRAFANA=$(curl -s https://checkip.amazonaws.com)/32

./scripts/deploy-cli.sh
```

O script faz, em ordem (idempotente — pode rodar de novo):

| Passo | Recurso | Equivalente console |
|---|---|---|
| 1 | SNS topic `votacao-enquetes-eventos` | SNS → Create topic |
| 2 | SQS `votacao-tally-queue` + policy | SQS → Create queue + Access policy |
| 3 | Subscription SNS→SQS (raw delivery) | SNS → Create subscription |
| 4 | Log groups `/votacao/*` | CloudWatch → Log groups |
| 5 | Security Group (3000 aberto, 3001 restrito) | EC2 → Security Groups |
| 6 | EC2 + user-data (Docker, clone, `.env`, compose up) | EC2 → Launch instance |
| 7 | Lambda (zip do repo, Node 20, com `LabRole`) | Lambda → Create function |
| 8 | EventBridge `rate(1 minute)` + permissão | EventBridge → Rules |
| 9 | Alarme de fila no CloudWatch | CloudWatch → Alarms |

Ao final ele imprime **API**, **Grafana** e salva tudo em
`infra/aws-cli/lab-outputs.env` (senhas incluídas, `chmod 600`).

## B.4 Validar

```bash
source ~/votacao-enquete/infra/aws-cli/lab-outputs.env
echo "$API_URL"

curl "$API_URL/health"
~/votacao-enquete/scripts/demo.sh "$API_URL" 30

# encerramento automático
ENQ=$(curl -s -X POST "$API_URL/enquetes" -H 'Content-Type: application/json' \
  -d '{"titulo":"Teste 1 min","duracao_minutos":1,"opcoes":["A","B"]}')
ID=$(echo "$ENQ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
sleep 90
curl -s "$API_URL/enquetes/$ID/resultado" | python3 -c 'import json,sys;print("status:",json.load(sys.stdin)["status"])'
```

## B.5 IP fixo (opcional)

```bash
ALLOC=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
aws ec2 associate-address --instance-id "$INSTANCE_ID" --allocation-id "$ALLOC"
IP_FIXO=$(aws ec2 describe-addresses --allocation-ids "$ALLOC" --query "Addresses[0].PublicIp" --output text)

aws lambda update-function-configuration --function-name votacao-close-expired-polls \
  --environment "Variables={API_URL=http://$IP_FIXO:3000,INTERNAL_TOKEN=$INTERNAL_TOKEN}"

echo "novo link: http://$IP_FIXO:3000"
```

## B.6 Apagar o lab novo no fim

```bash
AWS_PROFILE=lab2 ./scripts/deploy-cli.sh destroy
```

---

# C) Recriar manualmente no console (modo aprendizado)

A ordem importa: cada recurso referencia o anterior (ARN/ID).
O passo a passo completo, com os valores de cada campo, está em
**[`DEPLOY.md`](../DEPLOY.md)** — use a "PARTE B".

## Checklist enxuto (para ir marcando)

| # | Recurso | O que observar |
|---|---|---|
| 1 | **IAM → Role** | `LabRole` + `LabInstanceProfile` já existem no lab; você só *usa*, não cria |
| 2 | **SNS → Topic** | tipo *Standard*; copie o ARN |
| 3 | **SQS → Queue** | `VisibilityTimeout=60`, retenção **4 dias**, `ReceiveMessageWaitTime=20` — entenda por que: visibilidade = tempo que a mensagem fica "invisível" após ser lida |
| 4 | **SNS → Subscription** | protocolo SQS + **Raw message delivery = true** (senão o worker recebe envelope extra) |
| 5 | **SQS → Access policy** | liberar `sns.amazonaws.com` **com condição `aws:SourceArn`** (evita que outro tópico grave na sua fila) |
| 6 | **CloudWatch → Log groups** | `/votacao/votes-api` e `/votacao/tally-worker` (o driver `awslogs` exige que existam) |
| 7 | **EC2 → Security group** | 3000 aberto (a Lambda chama de IPs da AWS!), 3001 só do seu IP |
| 8 | **EC2 → Launch** | AL2023, t3.micro, **IMDSv2 + hop limit 2**, IAM profile `LabInstanceProfile` |
| 9 | **Na instância** | `scripts/ec2-bootstrap.sh` faz tudo: docker, compose, buildx, clone, `.env`, `up -d --build` — leia o arquivo, é o "user-data" de forma legível |
| 10 | **Lambda** | Node 20, role `LabRole`, env `API_URL` + `INTERNAL_TOKEN`, timeout 30s |
| 11 | **EventBridge** | `rate(1 minute)` → target Lambda (a permissão de invoke é criada junto) |
| 12 | **CloudWatch Alarm** | `ApproximateNumberOfMessagesVisible > 100` por 5 min |
| 13 | **Grafana** | `http://IP:3001` → dashboard provisionado na pasta *Votação* |

## Dica de aprendizado

Depois de criar cada recurso manualmente, compare com o que o script faria:

```bash
grep -n "create-topic\|create-queue\|run-instances\|create-function" ~/votacao-enquete/scripts/deploy-cli.sh
```

Assim você vê o comando CLI equivalente ao clique que acabou de dar no console.

---

# Observações importantes

1. **O state do Terraform é do lab 1.** Não rode `terraform destroy` no lab 2 — o state aponta para recursos de outra conta. No lab 2, use apenas `deploy-cli.sh`.
2. Se quiser voltar a usar Terraform em outro lab, crie um workspace novo:
   ```bash
   cd infra/terraform
   terraform workspace new lab2
   terraform apply -var-file=lab2.tfvars
   ```
   Cada workspace tem state próprio (`terraform.tfstate.d/<workspace>/`).
3. **Credenciais expiram** (~4h). Quando der `ExpiredToken`, repita o passo A.1 / B.1.
4. `deploy-cli.sh` **não** cria nem apaga IAM (usa o que o lab oferece) — igual ao modo laboratório do Terraform.
5. Custos no lab: EC2 + EBS + eventual EIP. Rode `destroy` no fim.
