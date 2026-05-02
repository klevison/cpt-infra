# Reintroduzir Caddy + TLS quando `cpt.bet` for registrado

Playbook para reverter o adendum 2026-04-30 (que removeu Caddy do MVP IP-only)
quando o domínio `cpt.bet` estiver registrado em Route 53. Trabalho mecânico, ~15
min, dividido em 4 arquivos do `infra/` + 1 `terraform apply`.

## Pré-requisitos

1. `cpt.bet` registrado em Route 53 da mesma conta AWS (~$26 USD via console
   AWS — vide [`deploy.md`](deploy.md) seção "Registrar `cpt.bet` em Route 53").
2. Hosted zone `cpt.bet` existe (criada automaticamente após registro):
   ```bash
   aws route53 list-hosted-zones --query 'HostedZones[?Name==`cpt.bet.`]'
   ```
3. `terraform.tfvars` aceita os novos valores (vide passo 4 abaixo).

## Passo 1 — Recriar `compose/Caddyfile`

Conteúdo (snapshot do que estava antes da remoção, ajustado para apex `cpt.bet`):

```caddy
# Caddy — TLS automático Let's Encrypt + reverse proxy → phoenix:4000.
# Pré-requisito: A record do {$DOMAIN} apontando pro IP estático ANTES do primeiro start
# (LE rate-limita 5 falhas/hora por host).

{$DOMAIN} {
    encode gzip zstd

    # WebSocket LiveView funciona com reverse_proxy direto (Caddy 2 detecta
    # Upgrade: websocket). Phoenix em prod aplica Plug.RewriteOn nesses headers
    # se configurado.
    reverse_proxy phoenix:4000 {
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For   {remote_host}
        header_up Host              {host}
    }

    log {
        output stdout
        format console
    }
}
```

Recuperação alternativa via histórico git (caso a versão acima fique
desatualizada): `git log --diff-filter=D --all -- compose/Caddyfile` lista o
último commit onde o arquivo existia; depois `git show <sha>:compose/Caddyfile
> compose/Caddyfile`.

## Passo 2 — Atualizar `compose/docker-compose.prod.yml`

Re-adicionar service `caddy` no topo de `services:` (antes de `phoenix:`):

```yaml
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    environment:
      DOMAIN: "${DOMAIN}"
    depends_on:
      phoenix:
        condition: service_healthy
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
```

E em `phoenix:`, trocar `ports: ["80:4000"]` por `expose: ["4000"]` (Phoenix
volta a ser interno-only; quem expõe pra internet é o Caddy).

E na seção `volumes:` no fim do arquivo, re-adicionar:
```yaml
  caddy_data:
  caddy_config:
```

## Passo 3 — Restaurar `DOMAIN` em `compose/.env.example`

Adicionar uma linha (a partir de `cpt.bet`):
```
DOMAIN=cpt.bet
```

E adicionar `aws_ssm_parameter "domain"` de volta em `terraform/ssm.tf`:
```hcl
resource "aws_ssm_parameter" "domain" {
  name  = "${local.ssm_prefix}/domain"
  type  = "SecureString"
  value = local.effective_host
  tier  = "Standard"
}
```

## Passo 4 — Restaurar `cp Caddyfile` em `terraform/user_data.sh`

Na seção "8. symlink do compose YAML", adicionar a linha de cópia de volta:
```bash
# 8. symlinks compose + Caddyfile
ln -sf /opt/cpt/infra/compose/docker-compose.prod.yml /opt/cpt/docker-compose.yml
cp /opt/cpt/infra/compose/Caddyfile /opt/cpt/Caddyfile
```

## Passo 5 — `terraform apply`

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # se ainda não existe
# Editar terraform.tfvars:
#   enable_route53    = true
#   domain            = "cpt.bet"
#   route53_zone_name = "cpt.bet"
terraform plan -out=tfplan
terraform apply tfplan
```

O apply vai:
- Criar A record `cpt.bet → <static_ip>` em Route 53
- Atualizar SSM `phx_host` = `cpt.bet`, `phx_scheme` = `https`, `phx_port_url` = `443`, `domain` = `cpt.bet`
- Não toca instância (mas user-data novo já está disponível para próximo recreate)

## Passo 6 — Aplicar mudanças no host

```bash
./scripts/ssh.sh "/opt/cpt/infra/scripts/refresh-env.sh && cd /opt/cpt && docker compose up -d"
```

Isso re-puxa SSM (pega `phx_host`/`scheme`/`port_url` atualizados), aplica o
compose novo (Caddy entra, Phoenix muda `ports → expose`), Caddy emite cert
ACME no primeiro request HTTP (60–90s).

## Verificação

1. **DNS resolve:**
   ```bash
   dig cpt.bet A +short   # deve retornar o static IP
   ```
2. **HTTP redirect → HTTPS** (Caddy faz por default):
   ```bash
   curl -I http://cpt.bet/   # 308 → https://cpt.bet/
   ```
3. **TLS funcional, cert Let's Encrypt:**
   ```bash
   curl -I https://cpt.bet/live-events   # 200, sem warning
   openssl s_client -connect cpt.bet:443 < /dev/null 2>/dev/null \
     | openssl x509 -noout -issuer
   # issuer=C = US, O = Let's Encrypt, CN = R3 (ou variante)
   ```
4. **WebSocket LiveView:**
   - Browser DevTools → `wss://cpt.bet/live/websocket` conecta sem erro
5. **Containers:**
   ```bash
   ./scripts/ssh.sh "cd /opt/cpt && docker compose ps"
   # Deve listar 6 services: caddy, phoenix, publisher, postgres, redis, watchtower
   ```

## Rollback (se algo der errado)

Reverter as 4 mudanças de arquivo via `git revert <sha-do-commit>` e:
```bash
terraform apply -var enable_route53=false
./scripts/ssh.sh "/opt/cpt/infra/scripts/refresh-env.sh && cd /opt/cpt && docker compose up -d"
```
Volta pra MVP IP-only sem perder dados.

## Custos pós-reintro

- Route 53 hosted zone: $0.50/mês
- (Caddy não cobra extra — usa porta 80/443 já abertas no Lightsail)
- ACME Let's Encrypt: gratuito
