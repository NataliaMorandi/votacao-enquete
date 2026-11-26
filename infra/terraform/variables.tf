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
  description = "CIDR autorizado a acessar o Grafana (3001) e SSH. Use SEU_IP/32."
  type        = string
  default     = "0.0.0.0/0"
}

variable "api_cidr" {
  description = "CIDR autorizado a chamar a API (3000). Precisa ser aberto porque a Lambda chama de IPs da AWS."
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

# ------------------------------------------------------------------
# Modo laboratório (Vocareum / AWS Academy)
# Nesses ambientes não é permitido criar usuários/roles IAM.
# Informe o instance profile e a role que o lab já fornece.
# ------------------------------------------------------------------
variable "instance_profile_name" {
  description = "Nome do instance profile existente (ex.: LabInstanceProfile). Vazio = cria um novo."
  type        = string
  default     = ""
}

variable "lambda_role_arn" {
  description = "ARN de uma role existente para a Lambda (ex.: arn:aws:iam::123:role/LabRole). Vazio = cria uma nova."
  type        = string
  default     = ""
}

# ------------------------------------------------------------------
# Alarme de fila (CloudWatch)
# Em produção: 100 mensagens por 5 minutos.
# Em demonstração (sala de aula, poucos votos): -var="alarme_threshold=5" -var="alarme_periodos=1"
# ------------------------------------------------------------------
variable "alarme_threshold" {
  description = "Mensagens visíveis na fila para disparar o alarme"
  type        = number
  default     = 100
}

variable "alarme_periodos" {
  description = "Quantos períodos consecutivos (1 min) acima do limiar disparam o alarme"
  type        = number
  default     = 5
}
