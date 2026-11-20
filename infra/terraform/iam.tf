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

# ------------------------------------------------------------------
# IAM Role da EC2 (instance profile)
# O SDK da AWS pega credenciais temporárias via metadata — sem access key
# ------------------------------------------------------------------
resource "aws_iam_role" "ec2_app" {
  name = "${var.project}-ec2-app"

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
  name = "${var.project}-ec2-app-policy"
  role = aws_iam_role.ec2_app.id

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
  name = "${var.project}-ec2-app"
  role = aws_iam_role.ec2_app.name
}

# ------------------------------------------------------------------
# IAM Role da Lambda (só precisa escrever logs)
# ------------------------------------------------------------------
resource "aws_iam_role" "lambda" {
  name = "${var.project}-lambda"

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
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
