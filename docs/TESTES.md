# Como testar

Todos os comandos abaixo assumem que você está na raiz do projeto e que a
infraestrutura está de pé (`./scripts/up.sh`).

```bash
cd ~/votacao-enquete
IP=$(terraform -chdir=infra/terraform output -raw ip_publico)
ID_INSTANCIA=$(terraform -chdir=infra/terraform output -raw instance_id)
echo "API: http://$IP:3000 | Grafana: http://$IP:3001"
```

---

## 1. Aplicação está viva?

```bash
curl http://$IP:3000/health
# {"status":"ok","service":"votes-api"}

curl http://$IP:3000/health/ready
# {"status":"ready"}     (confirma que o Postgres respondeu)

curl -s http://$IP:3000/metrics | head -5
# métricas Prometheus
```

## 2. Criar uma enquete

```bash
ENQ=$(curl -s -X POST http://$IP:3000/enquetes \
  -H 'Content-Type: application/json' \
  -d '{
    "titulo": "Onde vamos almoçar?",
    "descricao": "Teste manual",
    "duracao_minutos": 30,
    "opcoes": ["Opção A", "Opção B", "Opção C"]
  }')

echo "$ENQ" | python3 -m json.tool

ID=$(echo "$ENQ"   | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
OPT_A=$(echo "$ENQ"| python3 -c 'import json,sys;print(json.load(sys.stdin)["opcoes"][0]["id"])')
echo "enquete=$ID opcaoA=$OPT_A"
```

Esperado: HTTP 201, `status: "aberta"`, `prazo` = agora + 30 min.

## 3. Votar

```bash
curl -i -X POST http://$IP:3000/enquetes/$ID/votos \
  -H 'Content-Type: application/json' \
  -d "{\"cpf\":\"11122233344\",\"opcao_id\":\"$OPT_A\"}"
```

Esperado: **201** com `voto_id` e **sem** o campo `aviso`
(se aparecer `"aviso":"voto_salvo_mas_evento_nao_publicado"`, o SNS falhou).

## 4. Resultado (prova da mensageria)

```bash
sleep 2
curl -s http://$IP:3000/enquetes/$ID/resultado | python3 -m json.tool
```

O campo decisivo:

- **`"fonte_contagem": "redis"`** → o voto percorreu API → SNS → SQS → worker → Redis ✅
- `"fonte_contagem": "postgres"` → Redis vazio; a API recontou do banco

## 5. Testes negativos (regras de negócio)

```bash
# mesmo CPF votando 2x -> 409
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://$IP:3000/enquetes/$ID/votos \
  -H 'Content-Type: application/json' \
  -d "{\"cpf\":\"11122233344\",\"opcao_id\":\"$OPT_A\"}"
# esperado: 409  ({"error":"cpf_ja_votou"})

# CPF inválido -> 400
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://$IP:3000/enquetes/$ID/votos \
  -H 'Content-Type: application/json' -d "{\"cpf\":\"123\",\"opcao_id\":\"$OPT_A\"}"

# opção que não pertence à enquete -> 400
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://$IP:3000/enquetes/$ID/votos \
  -H 'Content-Type: application/json' \
  -d '{"cpf":"55566677788","opcao_id":"00000000-0000-0000-0000-000000000000"}'

# endpoint interno sem token -> 401
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://$IP:3000/internal/close-expired
```

## 6. Carga (para o dashboard ficar bonito)

```bash
./scripts/demo.sh http://$IP:3000 30
```

## 7. A fila está sendo consumida?

```bash
aws sqs get-queue-attributes \
  --queue-url $(terraform -chdir=infra/terraform output -raw sqs_queue_url) \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --output json
# esperado depois de alguns segundos: "0" e "0"
```

## 8. Logs (CloudWatch)

```bash
aws logs tail /votacao/votes-api      --since 10m --format short | tail -20
aws logs tail /votacao/tally-worker   --since 10m --format short | tail -20
aws logs tail /aws/lambda/votacao-close-expired-polls --since 10m --format short | tail -10
```

Procure por: `"msg":"voto_registrado"`, `"msg":"sns_publicado"`,
`"msg":"voto_contabilizado"`, `"msg":"close_expired_executado"`.

## 9. Encerramento automático (Lambda)

```bash
ENQ2=$(curl -s -X POST http://$IP:3000/enquetes -H 'Content-Type: application/json' \
  -d '{"titulo":"Prazo de 1 minuto","duracao_minutos":1,"opcoes":["A","B"]}')
ID2=$(echo "$ENQ2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')

echo "aguardando 90s (prazo + cron)..."
sleep 90

curl -s http://$IP:3000/enquetes/$ID2/resultado \
  | python3 -c 'import json,sys;print("status:",json.load(sys.stdin)["status"])'
# esperado: status: fechada
```

## 10. Resiliência da mensageria (o melhor teste para a apresentação)

```bash
# 1) para o worker
aws ssm send-command --instance-ids $ID_INSTANCIA --document-name AWS-RunShellScript \
  --parameters 'commands=["cd /opt/votacao && docker compose stop tally-worker"]' \
  --query "Command.CommandId" --output text

# 2) gere votos com o worker parado
ENQ3=$(curl -s -X POST http://$IP:3000/enquetes -H 'Content-Type: application/json' \
  -d '{"titulo":"Teste de fila","duracao_minutos":30,"opcoes":["A","B"]}')
ID3=$(echo "$ENQ3" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
OPT3=$(echo "$ENQ3"| python3 -c 'import json,sys;print(json.load(sys.stdin)["opcoes"][0]["id"])')
for i in 1 2 3 4 5; do
  curl -s -o /dev/null -X POST http://$IP:3000/enquetes/$ID3/votos \
    -H 'Content-Type: application/json' -d "{\"cpf\":\"7778889990$i\",\"opcao_id\":\"$OPT3\"}"
done

# 3) a fila deve ter mensagens acumuladas
aws sqs get-queue-attributes \
  --queue-url $(terraform -chdir=infra/terraform output -raw sqs_queue_url) \
  --attribute-names ApproximateNumberOfMessages --output json

# 4) religue o worker
aws ssm send-command --instance-ids $ID_INSTANCIA --document-name AWS-RunShellScript \
  --parameters 'commands=["cd /opt/votacao && docker compose start tally-worker"]' \
  --query "Command.CommandId" --output text

# 5) em ~30s a fila zerou e o resultado tem os votos
sleep 30
curl -s http://$IP:3000/enquetes/$ID3/resultado \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print("votos:",d["total_votos"],"fonte:",d["fonte_contagem"])'
```

Esse teste prova: **nenhum voto foi perdido com o consumidor fora do ar**.

## 11. Grafana

1. Abra `http://$IP:3001` (usuário `admin`, senha em
   `terraform -chdir=infra/terraform output -raw grafana_admin_password`).
2. Dashboards → pasta **Votação** → *Votação — Visão Geral*.
3. Rode `./scripts/demo.sh http://$IP:3000 30` e observe:
   - "Votos por minuto" (API vs worker)
   - "Votos contabilizados por opção" (barras)
   - latência p50/p95/p99
   - CPU/memória por container
4. **Tire o print** (item 5 do trabalho).

## 12. Teste local (sem AWS)

```bash
docker compose up -d --build
./scripts/demo.sh http://localhost:3000 10
docker compose down
```

Funciona, exceto a publicação no SNS (sem credenciais), que aparece no campo `aviso`.
