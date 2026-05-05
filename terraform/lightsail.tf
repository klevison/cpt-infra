# Instância Lightsail London + static IP + portas públicas + auto snapshot.
# user-data renderizado por cloudinit_config (cloud-config + script Bash).

resource "aws_lightsail_static_ip" "cpt" {
  name = "${var.instance_name}-ip"
}

# Importa public key gerada localmente (~/.ssh/cpt-lightsail.pub).
# Lightsail `create-key-pair` (sem public key) gera uma chave com privada
# nao recuperavel — se a privada local corromper, sem volta. Importando
# nossa publica, controlamos a privada e podemos rotacionar quando precisar.
resource "aws_lightsail_key_pair" "cpt" {
  name       = var.ssh_key_name
  public_key = file(pathexpand("~/.ssh/cpt-lightsail.pub"))
}

resource "aws_lightsail_instance" "cpt" {
  name              = var.instance_name
  availability_zone = "${var.aws_region}a"
  bundle_id         = var.lightsail_bundle_id
  blueprint_id      = var.lightsail_blueprint_id
  key_pair_name     = aws_lightsail_key_pair.cpt.name

  # Lightsail prepende seu proprio shell script ao user_data (configura
  # TrustedUserCAKeys pro Browser SSH). Isso impede usar multipart MIME
  # (cloudinit_config) -- cloud-init detecta como shell script unico e
  # nao parseia o MIME. Solucao: user_data eh um shell script direto que
  # cria /etc/cpt/aws_credentials no proprio bash (em vez de cloud-config
  # write_files).
  user_data = templatefile("${path.module}/user_data.sh", {
    aws_region            = var.aws_region
    ssm_prefix            = local.ssm_prefix
    infra_repo_url        = var.infra_repo_url
    infra_repo_ref        = var.infra_repo_ref
    aws_access_key_id     = aws_iam_access_key.bootstrap.id
    aws_secret_access_key = aws_iam_access_key.bootstrap.secret
  })

  add_on {
    type          = "AutoSnapshot"
    snapshot_time = var.snapshot_time_of_day_utc
    status        = "Enabled"
  }

  tags = {
    Name = var.instance_name
  }

  lifecycle {
    # `user_data` no schema do provider eh ForceNew — qualquer mudanca
    # destruiria a instancia (perda de pg_data, redis_data). Como user_data
    # so roda em first-boot mesmo, ignorar e semanticamente correto.
    # Recriacao consciente: `terraform apply -replace=aws_lightsail_instance.cpt`
    # (apenas com backup recente do pg_dump).
    ignore_changes = [user_data]

    # TEMPORARIAMENTE desabilitado para permitir replace da instance via
    # mudanca em key_pair_name (chave SSH antiga foi corrompida, recriacao
    # com nova chave ed25519 importada). Restaurar para `true` em commit
    # dedicado apos o apply OK.
    prevent_destroy = false
  }
}

resource "aws_lightsail_static_ip_attachment" "cpt" {
  static_ip_name = aws_lightsail_static_ip.cpt.name
  instance_name  = aws_lightsail_instance.cpt.name
}

resource "aws_lightsail_instance_public_ports" "cpt" {
  instance_name = aws_lightsail_instance.cpt.name

  port_info {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"
    cidrs     = var.allowed_ssh_cidrs
  }

  port_info {
    from_port = 80
    to_port   = 80
    protocol  = "tcp"
    cidrs     = ["0.0.0.0/0"]
  }

  # 443 fica aberta sem listener atual (Caddy removido do MVP IP-only).
  # Lightsail nao cobra por porta sem trafego e a abertura ja pronta deixa o
  # caminho livre quando Caddy voltar com `cpt.bet` (vide docs/caddy-reintro.md).
  port_info {
    from_port = 443
    to_port   = 443
    protocol  = "tcp"
    cidrs     = ["0.0.0.0/0"]
  }
}

# NOTA: data "cloudinit_config" foi removido. Lightsail injeta seu proprio
# shell script no user_data, e cloud-init nao consegue parsear multipart
# MIME quando ha esse prefixo shell. Solucao: passar user_data.sh direto
# como shell script unico (vide user_data acima em aws_lightsail_instance).
