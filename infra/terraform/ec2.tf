# ------------------------------------------------------------------
# Security Group
#   - 3000: API (pública)
#   - 3001: Grafana (pública, protegida por senha)
#   - 22:   SSH (opcional — só se key_name for informado)
#   Postgres (5432) e Redis (6379) NÃO são expostos.
# ------------------------------------------------------------------
resource "aws_security_group" "app" {
  name        = "${var.project}-sg"
  description = "Acesso a API e Grafana do sistema de enquetes"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "API votes-api"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  ingress {
    description = "Grafana"
    from_port   = 3001
    to_port     = 3001
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  dynamic "ingress" {
    for_each = var.key_name == "" ? [] : [1]
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [var.allowed_cidr]
    }
  }

  egress {
    description = "Saída (AWS SDK, dnf, docker pull)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-sg" }
}

# ------------------------------------------------------------------
# Instância única com Docker Compose
# ------------------------------------------------------------------
resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = tolist(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_app.name
  associate_public_ip_address = true
  key_name                    = var.key_name == "" ? null : var.key_name

  # IMDSv2 obrigatório + hop limit 2 (necessário para os containers
  # acessarem o metadata e obterem as credenciais do IAM Role)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = false # protege os dados: EBS sobrevive ao terminate
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    repo_url        = var.repo_url
    aws_region      = var.aws_region
    db_password     = random_password.db.result
    grafana_pass    = random_password.grafana.result
    internal_token  = random_password.internal_token.result
    sns_topic_arn   = aws_sns_topic.enquetes.arn
    sqs_queue_url   = aws_sqs_queue.tally.id
  })

  # Se o user_data mudar, cria instância nova para aplicar
  user_data_replace_on_change = false

  tags = { Name = "${var.project}-app" }
}

# Elastic IP opcional (IP fixo custa ~US$3,60/mês mesmo com a instância parada)
resource "aws_eip" "app" {
  count    = var.criar_eip ? 1 : 0
  instance = aws_instance.app.id
  domain   = "vpc"

  tags = { Name = "${var.project}-eip" }
}
