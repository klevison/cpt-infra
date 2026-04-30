# Todos os secrets e configs em SSM Parameter Store.
# SecureString criptografado pela chave gerenciada AWS (alias/aws/ssm).
# random_password gera valores estáveis (ficam no state); ignore_changes em [value]
# permite rotação manual via aws ssm put-parameter --overwrite sem reverter no apply.

resource "random_password" "secret_key_base" {
  length  = 64
  special = false
}

resource "random_password" "internal_token" {
  length  = 48
  special = false
}

resource "random_password" "postgres_password" {
  length  = 32
  special = false
}

# Segredos rotacionáveis (ignore_changes pra não reverter rotação manual)

resource "aws_ssm_parameter" "secret_key_base" {
  name  = "${local.ssm_prefix}/secret_key_base"
  type  = "SecureString"
  value = random_password.secret_key_base.result
  tier  = "Standard"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "internal_token" {
  name  = "${local.ssm_prefix}/internal_token"
  type  = "SecureString"
  value = random_password.internal_token.result
  tier  = "Standard"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "postgres_password" {
  name  = "${local.ssm_prefix}/postgres_password"
  type  = "SecureString"
  value = random_password.postgres_password.result
  tier  = "Standard"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "database_url" {
  name  = "${local.ssm_prefix}/database_url"
  type  = "SecureString"
  value = "ecto://cpt:${random_password.postgres_password.result}@postgres:5432/cpt"
  tier  = "Standard"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "ghcr_token" {
  name  = "${local.ssm_prefix}/ghcr_token"
  type  = "SecureString"
  value = var.ghcr_token
  tier  = "Standard"
}

# Configs gerenciados (Terraform reconcilia se mudar)

# Em bootstrap sem dominio (var.enable_route53 = false ou var.domain = ""),
# o IP estatico do Lightsail e usado como PHX_HOST. Phoenix gera URLs com IP
# (http://<ip>/) em vez de https://cpt.bet/. Quando dominio for registrado:
# `terraform apply -var domain=cpt.bet -var enable_route53=true` reconcilia.
locals {
  effective_host = var.domain != "" && var.enable_route53 ? var.domain : aws_lightsail_static_ip.cpt.ip_address
}

resource "aws_ssm_parameter" "phx_host" {
  name  = "${local.ssm_prefix}/phx_host"
  type  = "SecureString"
  value = local.effective_host
  tier  = "Standard"
}

resource "aws_ssm_parameter" "domain" {
  name  = "${local.ssm_prefix}/domain"
  type  = "SecureString"
  value = local.effective_host
  tier  = "Standard"
}

# Em IP-only (enable_route53 = false), Caddy escuta em :80 sem TLS e
# Phoenix gera URLs com scheme http e porta 80. Quando enable_route53 = true,
# Caddy reativa TLS e Phoenix volta para o default https/443.
resource "aws_ssm_parameter" "phx_scheme" {
  name  = "${local.ssm_prefix}/phx_scheme"
  type  = "SecureString"
  value = var.enable_route53 ? "https" : "http"
  tier  = "Standard"
}

resource "aws_ssm_parameter" "phx_port_url" {
  name  = "${local.ssm_prefix}/phx_port_url"
  type  = "SecureString"
  value = var.enable_route53 ? "443" : "80"
  tier  = "Standard"
}

resource "aws_ssm_parameter" "redis_url" {
  name  = "${local.ssm_prefix}/redis_url"
  type  = "SecureString"
  value = "redis://redis:6379/0"
  tier  = "Standard"
}

resource "aws_ssm_parameter" "cpt_image" {
  name  = "${local.ssm_prefix}/cpt_image"
  type  = "SecureString"
  value = "ghcr.io/${var.ghcr_owner}/cpt:${var.cpt_image_tag}"
  tier  = "Standard"
}

resource "aws_ssm_parameter" "publisher_image" {
  name  = "${local.ssm_prefix}/publisher_image"
  type  = "SecureString"
  value = "ghcr.io/${var.ghcr_owner}/wh-publisher:${var.publisher_image_tag}"
  tier  = "Standard"
}

resource "aws_ssm_parameter" "ghcr_user" {
  name  = "${local.ssm_prefix}/ghcr_user"
  type  = "SecureString"
  value = var.ghcr_owner
  tier  = "Standard"
}

resource "aws_ssm_parameter" "s3_backups_bucket" {
  name  = "${local.ssm_prefix}/s3_backups_bucket"
  type  = "SecureString"
  value = aws_s3_bucket.backups.bucket
  tier  = "Standard"
}

resource "aws_ssm_parameter" "aws_region" {
  name  = "${local.ssm_prefix}/aws_region"
  type  = "SecureString"
  value = var.aws_region
  tier  = "Standard"
}
