# Route 53 — gerenciado apenas quando enable_route53 = true.
# No bootstrap IP-only sem dominio, este arquivo nao cria nada e o acesso
# e direto via http://<static_ip>/.
#
# Quando enable_route53 = true, criamos a hosted zone como `resource`
# (nao data source) — o dominio foi registrado em registrar externo
# (ex: Cloudflare) e a zone NAO existe na AWS antes do apply. Apos o
# apply, copiar os 4 NS do output `route53_nameservers` e configurar
# como nameservers no painel do registrar para delegar a zona.

resource "aws_route53_zone" "primary" {
  count = var.enable_route53 ? 1 : 0
  name  = var.route53_zone_name

  comment = "cpt_bet — gerenciado por terraform/cpt-infra"
}

resource "aws_route53_record" "apex" {
  count   = var.enable_route53 ? 1 : 0
  zone_id = aws_route53_zone.primary[0].zone_id
  name    = var.domain
  type    = "A"
  ttl     = 300
  records = [aws_lightsail_static_ip.cpt.ip_address]
}
