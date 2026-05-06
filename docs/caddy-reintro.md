# Reintroduzir Caddy + TLS — APLICADO 2026-04-30

> **Status atual:** APLICADO. Caddy está em produção fazendo TLS automático Let's Encrypt
> para `cptlive.com`. O domínio foi registrado via **Cloudflare Registrar** (não Route 53
> — vide [`deploy.md`](deploy.md) passo 2 para a história), DNS hospedado em **Cloudflare**
> com `enable_route53=false`.
>
> Este documento permanece como **playbook histórico de reintrodução** — útil se o Caddy
> precisar ser removido novamente (ex: simplificação extrema do MVP) e depois trazido
> de volta. Os passos abaixo refletem o estado vigente do repo (Caddy presente,
> `cpt/config/prod.exs` com `force_ssl` ativo, `compose/.env.example` com `DOMAIN=cptlive.com`).

Playbook para reverter um adendum hipotético que remova Caddy. Trabalho mecânico, ~15
min, dividido em 4 arquivos do `infra/` + 1 `terraform apply`.

## Pré-requisitos

1. Domínio registrado e DNS apontando pra static IP do Lightsail. Em produção atual:
   `cptlive.com` via Cloudflare (`A @` e `A www` em modo "DNS only", sem proxy laranja).
2. Verificar:
   ```bash
   dig +short A cptlive.com   # deve retornar o static IP
   ```
3. `terraform.tfvars` com `domain = "cptlive.com"` e `enable_route53 = false`.

## Passo 1 — Recriar `compose/Caddyfile`

Conteúdo atual em produção (já presente no repo — este snapshot serve de referência
caso o arquivo precise ser recriado):

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

Adicionar uma linha (já presente no estado atual):
```
DOMAIN=cptlive.com
```

E confirmar `aws_ssm_parameter "domain"` em `terraform/ssm.tf` (já presente):
```hcl
resource "aws_ssm_parameter" "domain" {
  name  = "${local.ssm_prefix}/domain"
  type  = "SecureString"
  value = local.effective_host
  tier  = "Standard"
}
```

## Passo 4 — Re-habilitar `force_ssl` em `cpt/config/prod.exs`

Durante MVP IP-only o `force_ssl` foi removido (Phoenix em compile-time
redireciona HTTP -> HTTPS sem ter TLS pra qual ir). Em produção atual o bloco
está ativo em `cpt/config/prod.exs`:

```elixir
config :cpt, CptWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]
```

`rewrite_on: [:x_forwarded_proto]` faz Phoenix confiar no header
`X-Forwarded-Proto: https` que Caddy injeta. **Necessario** porque sem isso
Phoenix vai entrar em loop de redirect (Caddy faz HTTPS->Phoenix HTTP, Phoenix
tenta forçar HTTPS de novo).

Commit + push em `cpt/`, aguardar build, `docker compose pull phoenix && up -d`.

## Passo 5 — Restaurar `cp Caddyfile` em `terraform/user_data.sh`

Na seção "8. symlink do compose YAML", adicionar a linha de cópia de volta:
```bash
# 8. symlinks compose + Caddyfile
ln -sf /opt/cpt/infra/compose/docker-compose.prod.yml /opt/cpt/docker-compose.yml
cp /opt/cpt/infra/compose/Caddyfile /opt/cpt/Caddyfile
```

## Passo 6 — `terraform apply`

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # se ainda não existe
# Editar terraform.tfvars (estado atual):
#   enable_route53 = false              # Cloudflare Registrar exige CF DNS
#   domain         = "cptlive.com"
terraform plan -out=tfplan
terraform apply tfplan
```

O apply vai:
- Atualizar SSM `phx_host` = `cptlive.com`, `phx_scheme` = `https`, `phx_port_url` = `443`, `domain` = `cptlive.com`
- Não toca instância (mas user-data novo já está disponível para próximo recreate)
- Não cria zone Route 53 (CF DNS gerencia A records via painel CF, fora do Terraform)

## Passo 7 — Aplicar mudanças no host

```bash
./scripts/ssh.sh "/opt/cpt/infra/scripts/refresh-env.sh && cd /opt/cpt && docker compose up -d"
```

Isso re-puxa SSM (pega `phx_host`/`scheme`/`port_url` atualizados), aplica o
compose novo (Caddy entra, Phoenix muda `ports → expose`), Caddy emite cert
ACME no primeiro request HTTP (60–90s).

## Verificação

1. **DNS resolve:**
   ```bash
   dig cptlive.com A +short   # deve retornar o static IP
   ```
2. **HTTP redirect → HTTPS** (Phoenix `force_ssl` injeta 308; Caddy é HTTP→HTTPS-aware):
   ```bash
   curl -I http://cptlive.com/   # 308 → https://cptlive.com/
   ```
3. **TLS funcional, cert Let's Encrypt:**
   ```bash
   curl -I https://cptlive.com/live-events   # 200, sem warning
   openssl s_client -connect cptlive.com:443 < /dev/null 2>/dev/null \
     | openssl x509 -noout -issuer
   # issuer=C = US, O = Let's Encrypt, CN = R3 (ou variante)
   ```
4. **WebSocket LiveView:**
   - Browser DevTools → `wss://cptlive.com/live/websocket` conecta sem erro
5. **Containers:**
   ```bash
   ./scripts/ssh.sh "cd /opt/cpt && docker compose ps"
   # Deve listar 5 services: caddy, phoenix, publisher, postgres, redis
   ```

## Rollback (se algo der errado)

Reverter as 4 mudanças de arquivo via `git revert <sha-do-commit>` e:
```bash
./scripts/ssh.sh "/opt/cpt/infra/scripts/refresh-env.sh && cd /opt/cpt && docker compose up -d"
```
Volta pra MVP IP-only sem perder dados (Phoenix passa a expor `host:80` direto).

## Custos pós-reintro

- Cloudflare Registrar `cptlive.com`: ~$10/ano (~$0.83/mês)
- Cloudflare DNS: gratuito (free tier)
- (Caddy não cobra extra — usa porta 80/443 já abertas no Lightsail)
- ACME Let's Encrypt: gratuito
