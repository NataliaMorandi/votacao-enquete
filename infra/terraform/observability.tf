# ------------------------------------------------------------------
# CloudWatch Logs — item 4 do enunciado (registros de logs)
# ------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "api" {
  name              = "/votacao/votes-api"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/votacao/tally-worker"
  retention_in_days = 7
}

# ------------------------------------------------------------------
# Alarme: fila acumulando (o worker pode estar parado/atrasado)
# ------------------------------------------------------------------
resource "aws_sns_topic" "alarmes" {
  count = var.alarm_email == "" ? 0 : 1
  name  = "${var.project}-alarmes"
}

resource "aws_sns_topic_subscription" "alarmes_email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarmes[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "fila_acumulando" {
  alarm_name          = "${var.project}-fila-acumulando"
  alarm_description   = "Mais de 100 mensagens na fila por 5 minutos — verificar tally-worker"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 100
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.tally.name
  }

  alarm_actions = var.alarm_email == "" ? [] : [aws_sns_topic.alarmes[0].arn]
  ok_actions    = var.alarm_email == "" ? [] : [aws_sns_topic.alarmes[0].arn]
}
