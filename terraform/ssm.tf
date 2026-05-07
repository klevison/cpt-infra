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

# Bootstrap inicial via var.brevo_api_key. Rotacao posterior eh manual
# (painel Brevo gera key nova) — `ignore_changes = [value]` evita que
# `terraform apply` reverta a key rotada quando tfvars ficar defasado.
resource "aws_ssm_parameter" "brevo_api_key" {
  name  = "${local.ssm_prefix}/brevo_api_key"
  type  = "SecureString"
  value = var.brevo_api_key
  tier  = "Standard"

  lifecycle {
    ignore_changes = [value]
  }
}

# Configs gerenciados (Terraform reconcilia se mudar)

# Em bootstrap sem dominio (var.domain = ""), o IP estatico do Lightsail
# eh usado como PHX_HOST e Phoenix gera URLs http://<ip>/. Quando dominio
# for setado (independente de quem hospeda DNS — Route 53 OU Cloudflare/etc),
# Phoenix gera URLs https://<dominio>/ e Caddy faz TLS automatico ACME.
#
# var.enable_route53 controla apenas se o Terraform GERENCIA a hosted zone
# Route 53 (zone + A record). Quando false e dominio setado, esperamos que
# DNS esteja apontando pra static IP via outro provider (Cloudflare/etc).
locals {
  has_domain     = var.domain != ""
  effective_host = local.has_domain ? var.domain : aws_lightsail_static_ip.cpt.ip_address
}

resource "aws_ssm_parameter" "phx_host" {
  name  = "${local.ssm_prefix}/phx_host"
  type  = "SecureString"
  value = local.effective_host
  tier  = "Standard"
}

# Espelha phx_host como DOMAIN — usado pelo Caddyfile via {$DOMAIN} para
# TLS automatico Let's Encrypt. Caddy precisa do dominio em compile-time
# da config; phx_host servidor mesmo proposito mas em namespace Phoenix.
resource "aws_ssm_parameter" "domain" {
  name  = "${local.ssm_prefix}/domain"
  type  = "SecureString"
  value = local.effective_host
  tier  = "Standard"
}

# Sem dominio: Phoenix expoe :4000 -> compose mapeia :80 do host (sem Caddy).
# URLs geradas: http://<ip>/.
# Com dominio: Caddy a frente (vide docs/caddy-reintro.md), TLS automatico.
# URLs geradas: https://<dominio>/.
resource "aws_ssm_parameter" "phx_scheme" {
  name  = "${local.ssm_prefix}/phx_scheme"
  type  = "SecureString"
  value = local.has_domain ? "https" : "http"
  tier  = "Standard"
}

resource "aws_ssm_parameter" "phx_port_url" {
  name  = "${local.ssm_prefix}/phx_port_url"
  type  = "SecureString"
  value = local.has_domain ? "443" : "80"
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
