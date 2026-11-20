output "instance_id" {
  value = aws_instance.app.id
}

output "ip_publico" {
  description = "IP público da EC2 (muda a cada start se criar_eip = false)"
  value       = var.criar_eip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip
}

output "api_url" {
  value = "http://${var.criar_eip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip}:3000"
}

output "grafana_url" {
  value = "http://${var.criar_eip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip}:3001"
}

output "grafana_admin_user" {
  value = "admin"
}

output "grafana_admin_password" {
  value     = random_password.grafana.result
  sensitive = true
}

output "sns_topic_arn" {
  value = aws_sns_topic.enquetes.arn
}

output "sqs_queue_url" {
  value = aws_sqs_queue.tally.id
}

output "lambda_nome" {
  value = aws_lambda_function.close_expired.function_name
}

output "internal_token" {
  value     = random_password.internal_token.result
  sensitive = true
}

output "comandos_uteis" {
  value = <<-EOT
    Ligar:   aws ec2 start-instances --instance-ids ${aws_instance.app.id}
    Parar:   aws ec2 stop-instances  --instance-ids ${aws_instance.app.id}
    SSH:     aws ssm start-session --target ${aws_instance.app.id}
    Logs:    aws logs tail /votacao/votes-api --follow
    Destroy: terraform destroy   (apaga o EBS configurado como delete_on_termination=false? veja README)
  EOT
}
