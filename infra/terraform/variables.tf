variable "aws_region" {
  description = "Região AWS"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Prefixo dos nomes dos recursos"
  type        = string
  default     = "votacao"
}

variable "instance_type" {
  description = "Tipo da EC2 (t3.micro é free tier)"
  type        = string
  default     = "t3.micro"
}

variable "repo_url" {
  description = "URL do repositório Git que a EC2 vai clonar no boot"
  type        = string
  default     = "https://github.com/SEU-USUARIO/votacao-enquete.git"
}

variable "key_name" {
  description = "Key pair SSH (deixe vazio para não abrir SSH e usar SSM Session Manager)"
  type        = string
  default     = ""
}

variable "allowed_cidr" {
  description = "CIDR autorizado a acessar API (3000) e Grafana (3001). Use SEU_IP/32 em produção."
  type        = string
  default     = "0.0.0.0/0"
}

variable "alarm_email" {
  description = "E-mail para alarme de fila (deixe vazio para não criar)"
  type        = string
  default     = ""
}

variable "criar_eip" {
  description = "Criar Elastic IP (IP fixo). Custa ~US$3,60/mês mesmo com a instância parada."
  type        = bool
  default     = false
}
