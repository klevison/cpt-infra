# Route 53 — domínio registrado na própria AWS, então a hosted zone já existe
# após o registro. Apenas referenciamos via data source e criamos o A record apex.

data "aws_route53_zone" "primary" {
  name = var.route53_zone_name
}

resource "aws_route53_record" "apex" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = var.domain
  type    = "A"
  ttl     = 300
  records = [aws_lightsail_static_ip.cpt.ip_address]
}
