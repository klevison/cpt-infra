# cpt_bet infra

Infraestrutura da stack `cpt_bet` (Phoenix LiveView + Publisher Python WS→Redis Streams) num único host AWS Lightsail London.

## Topologia

```
                ┌───── DNS Cloudflare (free) ─────┐
cptlive.com ───►│  A @  → 35.178.28.41 (DNS only) │
                │  A www → 35.178.28.41 (DNS only)│
                └─────────────────────────────────┘
                              │
        ┌─────── AWS Lightsail (eu-west-2, medium_3_0) ─────────┐
        │                                                       │
        │  :80/:443 → ┌────────┐                                │
        │             │ caddy  │  TLS auto Let's Encrypt        │
        │             └───┬────┘  reverse_proxy → phoenix:4000  │
        │                 │                                     │
        │  ┌──────────────┴┐  ┌───────────┐  ┌──────────┐  ┌──┐ │
        │  │   phoenix     │  │ publisher │  │ postgres │  │rd│ │
        │  │ :4000 (force_ │  │           │  │          │  │  │ │
        │  │  ssl, X-Fwd-  │  │           │  │          │  │  │ │
        │  │   Proto)      │  │           │  │          │  │  │ │
        │  └────┬──────────┘  └─────┬─────┘  └────┬─────┘  └┬─┘ │
        │       │                   │             │          │  │
        │       └───────────────────┴─────────────┴──────────┘  │
        │                       (bridge net)                    │
        └───────────────────────────────────────────────────────┘
                                                          │
                                                    cron 04:00 UTC
                                                          │
                                          pg_dump → S3 (Glacier IR 30d)
```

> **Produção:** [`https://cptlive.com/`](https://cptlive.com/) (Let's Encrypt cert, HTTP→HTTPS 308 redirect via Caddy + Phoenix `force_ssl`).
>
> **DNS:** Cloudflare Registrar + Cloudflare DNS (conta free do CF exige uso do CF DNS, não permite custom NS — Route 53 não foi adotado). Dois A records `@` e `www` apontam pro static IP `35.178.28.41`, ambos em modo "DNS only" (proxy Cloudflare desativado pra não interferir no ACME).
>
> **Sem auto-deploy.** Após `git push main` em `cpt/` ou `wh-publisher/`, build GHA
> publica nova imagem em GHCR e o operador roda `docker compose pull && up -d` via
> SSH (vide `docs/runbook.md`). Watchtower foi removido (projeto upstream
> abandonado, incompatível com Docker daemon moderno).

Pipeline: `git push main` em [klevison/cpt](https://github.com/klevison/cpt) ou [klevison/wh-publisher](https://github.com/klevison/wh-publisher) → GHA build → push GHCR → operador roda `docker compose pull && up -d` via SSH no host (vide [`docs/runbook.md`](docs/runbook.md)).

## Estrutura

| Diretório | Conteúdo |
|---|---|
| `terraform/` | Provisionamento AWS (Lightsail, IAM, SSM, S3, Route 53) |
| `compose/` | `docker-compose.prod.yml`, `Caddyfile`, `.env.example` |
| `scripts/` | `backup.sh`, `restore.sh`, `refresh-env.sh`, `bootstrap-secrets.sh`, `ssh.sh` |
| `docs/` | `deploy.md` (provisionar), `runbook.md` (operar), `secrets.md` (rotacionar) |
| `docs/handoff/` | Instruções standalone para os repos `cpt/` e `wh-publisher/` |
| `.claude/` | Slash commands operacionais + subagente validador |

## Custo mensal

~$25.30 USD: Lightsail medium_3_0 $24 + S3 backups $0.50 + Cloudflare Registrar `cptlive.com` ~$0.83 (~$10/ano amortizado) + IAM/SSM/KMS/Cloudflare DNS $0. Cloudflare absorve DNS/registry sem cobrança adicional. Sem Route 53 (CF Registrar exige CF DNS na conta free).

## Como começar

- **Provisionar do zero:** [`docs/deploy.md`](docs/deploy.md)
- **Operar dia-a-dia:** [`docs/runbook.md`](docs/runbook.md)
- **Rotacionar segredos:** [`docs/secrets.md`](docs/secrets.md)
- **Mudanças nos repos de app:** [`docs/handoff/cpt.md`](docs/handoff/cpt.md), [`docs/handoff/wh-publisher.md`](docs/handoff/wh-publisher.md)

## Constraints duras (não ignorar)

1. **Publisher é singleton hard.** Nunca rodar 2 réplicas — duplicaria gols nos streams.
2. **Phoenix `terminate/2` faz `XGROUP DELCONSUMER`.** `stop_grace_period: 60s` no compose é obrigatório.
3. **Postgres é fonte de verdade.** Backup `pg_dump` diário não pode falhar silenciosamente.
4. **TinyProxy não existe mais.** Publisher conecta direto na WH via IP UK do Lightsail.
5. **Lightsail Instance NÃO tem IAM role nativo.** Acesso a SSM via IAM user dedicado com access key.

## Contribuindo

- Convenções em [`CLAUDE.md`](CLAUDE.md). Idioma PT-BR para docs/comentários/commits.
- Antes de qualquer `terraform apply`: rodar `/cpt-tf-plan` (slash command) ou manualmente `terraform fmt && terraform validate && terraform plan`.
- PRs disparam `.github/workflows/validate.yml` (fmt check + validate + compose config + gitleaks).
