variable "aws_region" {
  description = "Região AWS — Lightsail London = mesma região da WH (eu-west-2)."
  type        = string
  default     = "eu-west-2"
}

variable "domain" {
  description = <<-EOT
    Dominio publico que serve o Phoenix. Pode ficar vazio em bootstrap inicial
    sem DNS — neste caso o IP estatico do Lightsail e usado como host (PHX_HOST,
    URLs do Phoenix). Quando registrar dominio depois, setar aqui + ativar
    enable_route53.
  EOT
  type        = string
  default     = ""
}

variable "enable_route53" {
  description = <<-EOT
    Quando true, gerencia o A record apex em Route 53 apontando para o static IP.
    Requer route53_zone_name + domain preenchidos. Default false (bootstrap MVP
    sem dominio — acesso via http://<ip>/ ate dominio ser registrado).
  EOT
  type        = bool
  default     = false
}

variable "route53_zone_name" {
  description = "Nome da hosted zone Route 53 (igual ao domain quando apex). Ignorado se enable_route53 = false."
  type        = string
  default     = ""
}

variable "lightsail_bundle_id" {
  description = "Plano Lightsail. medium_2_0 = 2 vCPU / 4 GB / 80 GB / 3 TB / $20."
  type        = string
  default     = "medium_2_0"
}

variable "lightsail_blueprint_id" {
  description = "Imagem base Lightsail. Ubuntu 24.04 LTS."
  type        = string
  default     = "ubuntu_24_04"
}

variable "instance_name" {
  description = "Nome da instância Lightsail."
  type        = string
  default     = "cpt-prod"
}

variable "ssh_key_name" {
  description = "Nome do key pair Lightsail (criado fora do Terraform via aws lightsail create-key-pair)."
  type        = string
}

variable "infra_repo_url" {
  description = "URL público do repo infra/ — clonado no boot pelo user-data para subir o compose."
  type        = string
  default     = "https://github.com/klevison/cpt-infra.git"
}

variable "infra_repo_ref" {
  description = "Branch/tag/sha do infra-repo a usar no boot. Pin a sha em produção crítica."
  type        = string
  default     = "main"
}

variable "ghcr_owner" {
  description = "GitHub owner que hospeda as imagens (ghcr.io/<owner>/cpt e wh-publisher)."
  type        = string
  default     = "klevison"
}

variable "ghcr_token" {
  description = "PAT GitHub escopo read:packages. NUNCA commitar — preencher em terraform.tfvars (gitignored)."
  type        = string
  sensitive   = true
}

variable "cpt_image_tag" {
  description = "Tag da imagem Phoenix puxada pelo Watchtower."
  type        = string
  default     = "latest"
}

variable "publisher_image_tag" {
  description = "Tag da imagem Publisher puxada pelo Watchtower."
  type        = string
  default     = "latest"
}

variable "allowed_ssh_cidrs" {
  description = "CIDRs autorizados a SSH (porta 22). Default aberto — restringir após bootstrap."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "snapshot_time_of_day_utc" {
  description = "Horário UTC do snapshot diário automático (formato HH:00 — Lightsail aceita só horas inteiras em alguns regiões)."
  type        = string
  default     = "03:00"
}
