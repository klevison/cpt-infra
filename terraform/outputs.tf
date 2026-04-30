output "instance_public_ip" {
  description = "IP estático atribuído à instância Lightsail. Apontar A record do domínio para este IP."
  value       = aws_lightsail_static_ip.cpt.ip_address
}

output "instance_name" {
  description = "Nome da instância Lightsail."
  value       = aws_lightsail_instance.cpt.name
}

output "s3_backups_bucket" {
  description = "Bucket S3 que recebe os pg_dump diários."
  value       = aws_s3_bucket.backups.bucket
}

output "bootstrap_iam_user_name" {
  description = "IAM user dedicado ao bootstrap da instância (acesso read-only ao SSM /cpt/prod/*)."
  value       = aws_iam_user.bootstrap.name
}

output "bootstrap_aws_access_key_id" {
  description = "Access key ID do IAM user bootstrap (gravado no /etc/cpt/aws_credentials da instância)."
  value       = aws_iam_access_key.bootstrap.id
  sensitive   = true
}

output "bootstrap_aws_secret_access_key" {
  description = "Secret access key do IAM user bootstrap."
  value       = aws_iam_access_key.bootstrap.secret
  sensitive   = true
}

output "ssh_command" {
  description = "Comando SSH pronto para colar (assumindo chave em ~/.ssh/cpt-lightsail.pem)."
  value       = "ssh -i ~/.ssh/cpt-lightsail.pem ubuntu@${aws_lightsail_static_ip.cpt.ip_address}"
}

output "domain_a_record" {
  description = "Domínio apex apontando para o IP estático."
  value       = aws_route53_record.apex.fqdn
}
