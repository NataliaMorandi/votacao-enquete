# DEPLOY — como construir tudo na AWS

Duas formas. **Caminho A** (Terraform, ~10 min, recomendado). **Caminho B** (console,
passo a passo, para entender e/ou fazer na mão). Ambos chegam ao mesmo resultado.

---

# PARTE 0 — Pré-requisitos (5 min)

1. Conta AWS ativa (free tier).
2. Região escolhida — use **us-east-1 (N. Virginia)** em todos os passos.
3. Repositório no GitHub com este projeto (o `main` precisa existir).
4. AWS CLI instalado na sua máquina e configurado: `aws configure` (access key + secret + região).
5. Conta **sem** carga de trabalho antiga na VPC default (ou adapte).

---

# CAMINHO A — Terraform (o jeito rápido)

```bash
cd infra/terraform
terraform init
terraform apply \
  -var="repo_url=https://github.com/SEU-USUARIO/votacao-enquete.git" \
  -var="allowed_cidr=SEU.IP.PUBLICO/32" \
  -var="alarm_email=seu@email.com"

# saída: ip_publico, api_url, grafana_url, senha do Grafana
terraform output
```

A EC2 sobe, instala Docker, clona o repo, gera o `.env` e roda `docker-compose up -d --build`.
Em ~2 min: `http://IP:3000/health` responde `{"status":"ok"}`.

Rotina diária:
```bash
./scripts/up.sh      # liga, atualiza URL da Lambda, mostra endereços
./scripts/down.sh    # para (EBS continua, compute vai a zero)
```

---

# CAMINHO B — Console AWS, recurso por recurso

> Siga na ordem. Cada passo depende do anterior (nomes e ARNs).

## Passo 1 — IAM: use o que o laboratório já oferece

> ⚠️ **Em laboratório Vocareum / AWS Academy a criação de IAM é bloqueada.**
> O erro `not authorized to perform: iam:CreateRole` é esperado e **não é falha sua**.
> Não tente criar usuário, role ou policy — use o que já existe.

1. Console → **IAM** → *Roles* → confirme que existe **`LabRole`**.
2. Console → **IAM** → *Instance profiles* → confirme **`LabInstanceProfile`**.
3. Anote o nome do instance profile — ele será usado no **Passo 8** (Launch instance → IAM instance profile).
4. Pronto. Sem policy inline: a `LabRole` já tem as permissões de SNS, SQS, Lambda e CloudWatch.

Confirme pela CLI (opcional):

```bash
aws iam list-instance-profiles --query "InstanceProfiles[].InstanceProfileName" --output table
aws iam get-role --role-name LabRole --query "Role.AssumeRolePolicyDocument.Statement[].Principal.Service[]" --output text \
  | tr '\t' '\n' | grep -Ei 'lambda|ec2'
```

<details>
<summary>Se você estiver numa conta AWS própria (não-laboratório): criar a role</summary>

1. **IAM → Roles → Create role** → *AWS service* → **EC2** → *Next* → *Next*.
2. Role name: `votacao-ec2-app` → **Create role**.
3. Na role → **Add permissions** → **Create inline policy** → aba **JSON**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicarEventos",
      "Effect": "Allow",
      "Action": ["sns:Publish"],
      "Resource": ["arn:aws:sns:REGIAO:CONTA:votacao-enquetes-eventos"]
    },
    {
      "Sid": "ConsumirFila",
      "Effect": "Allow",
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:ChangeMessageVisibility"
      ],
      "Resource": ["arn:aws:sqs:REGIAO:CONTA:votacao-tally-queue"]
    },
    {
      "Sid": "Logs",
      "Effect": "Allow",
      "Action": ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"],
      "Resource": [
        "arn:aws:logs:REGIAO:CONTA:log-group:/votacao/votes-api:*",
        "arn:aws:logs:REGIAO:CONTA:log-group:/votacao/tally-worker:*"
      ]
    }
  ]
}
```

4. Policy name: `votacao-ec2-app-policy` → **Create policy**.

</details>

## Passo 2 — SNS (tópico)

1. Console → **SNS** → *Topics* → **Create topic**.
2. Type: **Standard**. Name: `votacao-enquetes-eventos`.
3. **Create topic**.
4. **Copie o ARN** (aparece no topo) — será usado no `.env` e na policy IAM.

## Passo 3 — SQS (fila)

1. Console → **SQS** → **Create queue**.
2. Type: **Standard**. Name: `votacao-tally-queue`.
3. Configuration:
   - **Visibility timeout**: `60` segundos
   - **Message retention period**: `4` dias
   - **Delivery delay**: `0`
   - **Receive message wait time**: `20` segundos (long polling)
   - **Maximum message size**: `256 KB`
4. Deixe o resto no padrão → **Create queue**.
5. **Copie a URL da fila** (ex.: `https://sqs.us-east-1.amazonaws.com/123456789012/votacao-tally-queue`).

## Passo 4 — Assinatura SNS → SQS (fan-out)

1. Console → **SNS** → *Topics* → clique em `votacao-enquetes-eventos`.
2. Aba **Subscriptions** → **Create subscription**.
3. Protocol: **Amazon SQS**. Endpoint: **cole o ARN da fila** (`arn:aws:sqs:...`).
4. **Enable raw message delivery** ✔ (importante: o worker recebe o JSON puro).
5. **Create subscription**.

## Passo 5 — Policy da fila (permitir o SNS entregar)

1. Console → **SQS** → `votacao-tally-queue` → aba **Access policy** → **Edit**.
2. **Advanced** → cole (trocando REGIAO/CONTA/ARN do tópico):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PermitirSNS",
      "Effect": "Allow",
      "Principal": { "Service": "sns.amazonaws.com" },
      "Action": "sqs:SendMessage",
      "Resource": "arn:aws:sqs:REGIAO:CONTA:votacao-tally-queue",
      "Condition": {
        "ArnEquals": { "aws:SourceArn": "arn:aws:sns:REGIAO:CONTA:votacao-enquetes-eventos" }
      }
    }
  ]
}
```

3. **Save**.

## Passo 6 — Log Groups (CloudWatch)

1. Console → **CloudWatch** → *Logs* → **Log groups** → **Create log group**.
2. Crie dois:
   - `/votacao/votes-api` — retention **7 days**
   - `/votacao/tally-worker` — retention **7 days**

> O driver `awslogs` do Docker exige que o grupo já exista.

## Passo 7 — Security Group e EC2

1. Console → **EC2** → *Security Groups* → **Create security group**.
2. Name: `votacao-sg`. VPC: **default**.
3. Inbound rules:

| Type | Port | Source |
|---|---|---|
| Custom TCP | 3000 | **Anywhere-IPv4 (0.0.0.0/0)** — a Lambda chama a API a partir de IPs da AWS |
| Custom TCP | 3001 | My IP (Grafana só para você) |

4. Outbound: **All traffic** (padrão) → **Create security group**.

5. Console → **EC2** → **Launch instance**:
   - **Name**: `votacao-app`
   - **AMI**: Amazon Linux 2023 (x86_64)
   - **Instance type**: `t3.micro`
   - **Key pair**: *Proceed without a key pair* (vamos usar SSM) ou crie um se preferir SSH
   - **Network settings**:
     - VPC: default, Subnet: qualquer (preferir uma pública)
     - **Auto-assign public IP**: **Enable**
     - Firewall: **Select existing security group** → `votacao-sg`
   - **Configure storage**: `20` GiB, **gp3**
   - **Advanced details**:
     - **IAM instance profile**: `votacao-ec2-app`
     - **Metadata accessible**: Enabled
     - **Metadata version**: **V2 only (token required)**
     - **Metadata token response hop limit**: **2** ⚠️ (sem isso os containers não pegam as credenciais)
   - **Launch instance**

## Passo 8 — Conectar na instância

1. Console → **EC2** → instância `votacao-app` → **Connect** → aba **Session Manager** → **Connect**.
   (se o botão estiver cinza: IAM → role `votacao-ec2-app` → adicionar a policy gerenciada `AmazonSSMManagedInstanceCore`)

## Passo 9 — Instalar Docker e subir a aplicação

Dentro do terminal da instância:

```bash
# 1) Docker
sudo dnf update -y
sudo dnf install -y docker git curl
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user

# 2) Swap (2 GB) — importante no t3.micro
sudo dd if=/dev/zero of=/swapfile bs=1M count=2048
sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# 3) Docker Compose v2
sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# 4) Código (escolha UMA opção)
sudo git clone https://github.com/SEU-USUARIO/votacao-enquete.git /opt/votacao
#   ou, da SUA máquina:  scp -r -i chave.pem ./ ec2-user@IP:/tmp/votacao && sudo mv /tmp/votacao /opt

# 5) Variáveis de ambiente
cd /opt/votacao
sudo tee .env > /dev/null <<'EOF'
POSTGRES_PASSWORD=SenhaForteDoBanco123
REDIS_URL=redis://redis:6379
AWS_REGION=us-east-1
SNS_TOPIC_ARN=arn:aws:sns:us-east-1:CONTA:votacao-enquetes-eventos
SQS_QUEUE_URL=https://sqs.us-east-1.amazonaws.com/CONTA/votacao-tally-queue
INTERNAL_TOKEN=token-interno-longo-e-aleatorio
GRAFANA_ADMIN_PASSWORD=admin123
EOF
sudo chmod 600 .env

# 6) Subir
sudo /usr/local/bin/docker-compose up -d --build
sudo /usr/local/bin/docker-compose ps
```

## Passo 10 — Testar

```bash
curl http://localhost:3000/health
# {"status":"ok","service":"votes-api"}

./scripts/demo.sh http://localhost:3000 30
```

Se o `resultado` mostrar `fonte_contagem: "redis"` e os votos contabilizados,
o caminho API → SNS → SQS → worker → Redis está funcionando.

## Passo 11 — Lambda (serverless)

1. Console → **Lambda** → **Create function** → **Author from scratch**.
2. Function name: `votacao-close-expired-polls`. Runtime: **Node.js 20.x**. Architecture: x86_64.
3. Permissions: escolha **Use an existing role** → **`LabRole`** → **Create function**.
   *(Em laboratório não é possível criar role nova. Numa conta própria, use "Create a new role with basic Lambda permissions".)*
4. Em **Code source**, apague o conteúdo e cole o arquivo `lambda/close-expired-polls/index.mjs` do repositório → **Deploy**.

   > ⚠️ **Use o `index.mjs` (ESM), não o antigo `index.js`.** O editor do console do Node 22+/26 cria o arquivo como ESM; código CommonJS (`exports.handler`) falha com `exports is not defined in ES module scope`. Se preferir CommonJS, envie um `.zip` com `index.js` (o Lambda trata `.js` como CJS quando não há `package.json`).
5. **Configuration** → **Environment variables** → **Edit** → adicione:
   - `API_URL` = `http://IP-PUBLICO-DA-EC2:3000`
   - `INTERNAL_TOKEN` = o mesmo valor do `.env`
6. **Configuration** → **General configuration** → **Edit** → Timeout: `30` s → **Save**.
7. Teste: aba **Test** → crie um evento `{}` → **Test**.
   No CloudWatch Logs deve aparecer `"msg":"close_expired_executado","status":200`.

## Passo 12 — EventBridge (cron de 1 minuto)

1. Console → **EventBridge** → *Rules* → **Create rule**.
2. Name: `votacao-cron-1min`. Rule type: **Schedule**.
3. Schedule pattern: **A schedule that runs at a regular rate** → rate value `1` → unit **minutes**.
4. **Next** → Target type: **AWS service** → Target: **Lambda function** → `votacao-close-expired-polls`.
5. **Next** → **Next** → **Create rule**.

Pronto: toda enquete cujo `prazo` vencer é fechada em até 1 minuto.

## Passo 13 — Alarme de fila (CloudWatch)

1. Console → **CloudWatch** → *All alarms* → **Create alarm**.
2. **Select metric** → **SQS** → **Per-Queue Metrics** → `votacao-tally-queue` → `ApproximateNumberOfMessagesVisible` → **Select metric**.
3. Statistic: **Maximum**, Period: **1 minute**, Threshold: **Static**, **Greater than** `100`.
4. **Next** → Create new SNS topic `votacao-alarmes` → informe seu e-mail → **Create topic** → **Next**.
5. Alarm name: `votacao-fila-acumulando` → **Create alarm**.
6. Confirme a inscrição no e-mail recebido.

## Passo 14 — Grafana

1. Navegador: `http://IP-PUBLICO:3001` → login `admin` / senha do `.env`.
2. Menu → **Dashboards** → pasta **Votação** → **Votação — Visão Geral**.
3. Já vem com: votos totais, votos/min (API vs worker), latência p50/p95/p99, votos por opção, CPU/memória por container.
4. Rode `./scripts/demo.sh http://IP:3000 30` e veja os gráficos se moverem → **tire o print (item 5 do trabalho)**.

## Passo 15 — Rotina de ligar/desligar

```bash
# parar (compute = US$0)
aws ec2 stop-instances --instance-ids i-XXXX

# ligar
aws ec2 start-instances --instance-ids i-XXXX
aws ec2 wait instance-running --instance-ids i-XXXX
aws ec2 describe-instances --instance-ids i-XXXX \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text

# o IP muda: atualize a Lambda
aws lambda update-function-configuration \
  --function-name votacao-close-expired-polls \
  --environment "Variables={API_URL=http://NOVO_IP:3000,INTERNAL_TOKEN=SEU_TOKEN}"
```

> Se quiser IP fixo: EC2 → *Elastic IPs* → **Allocate** → **Associate** com a instância
> (custa ~US$3,60/mês enquanto existir, mesmo parada).

## Passo 16 — Limpeza total (fim do semestre)

Nesta ordem, para não deixar recurso cobrando:

1. EventBridge → delete rule `votacao-cron-1min`
2. Lambda → delete `votacao-close-expired-polls`
3. SNS → delete subscription, depois o tópico (e `votacao-alarmes`)
4. SQS → delete `votacao-tally-queue`
5. CloudWatch → delete log groups e o alarme
6. EC2 → **Terminate** a instância (o EBS tem `delete_on_termination=false`: delete o volume manualmente em *Volumes*)
7. EC2 → Security Group `votacao-sg` → delete
8. IAM → delete role `votacao-ec2-app` e `votacao-close-expired-polls-role`

---

# Checklist final do enunciado

| # | Item | Onde está no repositório |
|---|---|---|
| 0 | RACI da equipe | *(preencher — `docs/RACI.md`)* |
| 1 | Desenho da arquitetura + HA/observabilidade | `README.md` seções 2, 4 e 5 |
| 2 | Código da aplicação em camadas | `services/votes-api`, `services/tally-worker`, `db/init` |
| 3 | IaC | `infra/terraform` |
| 4 | Logs/eventos da aplicação funcionando | CloudWatch Logs (`/votacao/*`) + `scripts/demo.sh` |
| 5 | Print do dashboard real | Grafana `http://IP:3001` (dashboard provisionado) |
