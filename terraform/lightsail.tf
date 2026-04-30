# Instância Lightsail London + static IP + portas públicas + auto snapshot.
# user-data renderizado por cloudinit_config (cloud-config + script Bash).

resource "aws_lightsail_static_ip" "cpt" {
  name = "${var.instance_name}-ip"
}

resource "aws_lightsail_instance" "cpt" {
  name              = var.instance_name
  availability_zone = "${var.aws_region}a"
  bundle_id         = var.lightsail_bundle_id
  blueprint_id      = var.lightsail_blueprint_id
  key_pair_name     = var.ssh_key_name

  user_data = data.cloudinit_config.user_data.rendered

  add_on {
    type          = "AutoSnapshot"
    snapshot_time = var.snapshot_time_of_day_utc
    status        = "Enabled"
  }

  tags = {
    Name = var.instance_name
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

  port_info {
    from_port = 443
    to_port   = 443
    protocol  = "tcp"
    cidrs     = ["0.0.0.0/0"]
  }
}

# Cloud-init em duas partes:
# 1. cloud-config para gravar /etc/cpt/aws_credentials antes do script rodar.
# 2. Script Bash que instala Docker, puxa SSM e sobe o compose.
data "cloudinit_config" "user_data" {
  gzip          = false
  base64_encode = false

  part {
    filename     = "00-aws-credentials.yaml"
    content_type = "text/cloud-config"
    content = yamlencode({
      write_files = [
        {
          path        = "/etc/cpt/aws_credentials"
          owner       = "root:root"
          permissions = "0600"
          content     = <<-EOT
            [default]
            aws_access_key_id = ${aws_iam_access_key.bootstrap.id}
            aws_secret_access_key = ${aws_iam_access_key.bootstrap.secret}
            region = ${var.aws_region}
          EOT
        },
      ]
    })
  }

  part {
    filename     = "10-bootstrap.sh"
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/user_data.sh", {
      aws_region     = var.aws_region
      ssm_prefix     = local.ssm_prefix
      infra_repo_url = var.infra_repo_url
      infra_repo_ref = var.infra_repo_ref
    })
  }
}
