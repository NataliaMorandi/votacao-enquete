# ------------------------------------------------------------------
# Lambda serverless: fecha enquetes vencidas (chamada pelo EventBridge)
# ------------------------------------------------------------------
data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda/close-expired-polls"
  output_path = "${path.module}/.build/close-expired-polls.zip"
}

resource "aws_lambda_function" "close_expired" {
  function_name    = "${var.project}-close-expired-polls"
  description      = "Fecha enquetes com prazo vencido e publica enquete.encerrada"
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  role             = local.criar_iam_lambda ? aws_iam_role.lambda[0].arn : var.lambda_role_arn
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      API_URL        = "http://${aws_instance.app.public_ip}:3000"
      INTERNAL_TOKEN = random_password.internal_token.result
    }
  }

  # O IP público da EC2 muda a cada start (sem EIP): evita drift no plan
  lifecycle {
    ignore_changes = [environment]
  }
}

# Regra de agendamento: a cada 1 minuto
resource "aws_cloudwatch_event_rule" "cron" {
  name                = "${var.project}-cron-1min"
  description         = "Dispara a Lambda de encerramento a cada minuto"
  schedule_expression = "rate(1 minute)"
  state               = "ENABLED"
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule = aws_cloudwatch_event_rule.cron.name
  arn  = aws_lambda_function.close_expired.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "PermitirEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.close_expired.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cron.arn
}
