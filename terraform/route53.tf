# Route 53 — gerenciado apenas quando enable_route53 = true.
# No bootstrap inicial sem dominio, este arquivo nao cria nada e o acesso
# e direto via http://<static_ip>/ (Phoenix expoe :4000 mapeado pra :80
# do host pelo Compose, sem reverse proxy a frente).

data "aws_route53_zone" "primary" {
  count = var.enable_route53 ? 1 : 0
  name  = var.route53_zone_name
}

resource "aws_route53_record" "apex" {
  count   = var.enable_route53 ? 1 : 0
  zone_id = data.aws_route53_zone.primary[0].zone_id
  name    = var.domain
  type    = "A"
  ttl     = 300
  records = [aws_lightsail_static_ip.cpt.ip_address]
}
