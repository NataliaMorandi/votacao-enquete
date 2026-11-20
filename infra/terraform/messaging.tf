# ------------------------------------------------------------------
# Tópico SNS — barramento de eventos da aplicação
# ------------------------------------------------------------------
resource "aws_sns_topic" "enquetes" {
  name = "${var.project}-enquetes-eventos"
}

# ------------------------------------------------------------------
# Fila SQS — consumida pelo tally-worker
# Sem DLQ (decisão documentada no README): volume baixo + consumer idempotente
# ------------------------------------------------------------------
resource "aws_sqs_queue" "tally" {
  name                       = "${var.project}-tally-queue"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 345600 # 4 dias
  receive_wait_time_seconds  = 20     # long polling (reduz custo)
  delay_seconds              = 0
  max_message_size           = 262144
}

# Permite que o SNS entregue mensagens na fila (com verificação de origem)
resource "aws_sqs_queue_policy" "allow_sns" {
  queue_url = aws_sqs_queue.tally.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PermitirSNS"
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.tally.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.enquetes.arn }
      }
    }]
  })
}

# Fan-out: SNS -> SQS (raw delivery = o worker recebe o JSON puro)
resource "aws_sns_topic_subscription" "tally" {
  topic_arn            = aws_sns_topic.enquetes.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.tally.arn
  raw_message_delivery = true
}
