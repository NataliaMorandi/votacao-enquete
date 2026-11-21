# ------------------------------------------------------------------
# Credenciais geradas automaticamente (nada de senha no código)
# ------------------------------------------------------------------
resource "random_password" "db" {
  length  = 24
  special = false
}

resource "random_password" "grafana" {
  length  = 20
  special = false
}

resource "random_password" "internal_token" {
  length  = 48
  special = false
}

locals {
  # Se um instance profile existente foi informado (laboratório),
  # não criamos role/profile — apenas usamos o que já existe.
  criar_iam_ec2 = var.instance_profile_name == ""
  criar_iam_lambda = var.lambda_role_arn == ""
}

# ------------------------------------------------------------------
# Caminho A: criar IAM Role da EC2 (conta normal)
# ------------------------------------------------------------------
resource "aws_iam_role" "ec2_app" {
  count = local.criar_iam_ec2 ? 1 : 0
  name  = "${var.project}-ec2-app"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ec2_app" {
  count = local.criar_iam_ec2 ? 1 : 0
  name  = "${var.project}-ec2-app-policy"
  role  = aws_iam_role.ec2_app[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PublicarEventos"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [aws_sns_topic.enquetes.arn]
      },
      {
        Sid    = "ConsumirFila"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = [aws_sqs_queue.tally.arn]
      },
      {
        Sid    = "LogsCloudWatch"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = ["${aws_cloudwatch_log_group.api.arn}:*", "${aws_cloudwatch_log_group.worker.arn}:*"]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_app" {
  count = local.criar_iam_ec2 ? 1 : 0
  name  = "${var.project}-ec2-app"
  role  = aws_iam_role.ec2_app[0].name
}

# ------------------------------------------------------------------
# Caminho B: usar instance profile já existente (laboratório)
# ------------------------------------------------------------------
data "aws_iam_instance_profile" "existente" {
  count = local.criar_iam_ec2 ? 0 : 1
  name  = var.instance_profile_name
}

# ------------------------------------------------------------------
# IAM Role da Lambda
# ------------------------------------------------------------------
resource "aws_iam_role" "lambda" {
  count = local.criar_iam_lambda ? 1 : 0
  name  = "${var.project}-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  count      = local.criar_iam_lambda ? 1 : 0
  role       = aws_iam_role.lambda[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
