# cpt_bet infra

Infraestrutura da stack `cpt_bet` (Phoenix LiveView + Publisher Python WS→Redis Streams) num único host AWS Lightsail London.

## Topologia

```
┌─────────────────────────────────────────────────────────────────┐
│  AWS Lightsail (eu-west-2, medium_2_0 — 2 vCPU / 4 GB / 80 GB)  │
│                                                                 │
│  ┌─────────────┐  ┌───────────┐  ┌──────────┐  ┌─────┐          │
│  │ phoenix     │  │ publisher │  │ postgres │  │redis│          │
│  │ host :80 ←  │  │           │  │          │  │     │          │
│  │ container   │  │           │  │          │  │     │          │
│  │ :4000       │  │           │  │          │  │     │          │
│  └─────┬───────┘  └─────┬─────┘  └────┬─────┘  └──┬──┘          │
│        │                │             │           │             │
│        └────────────────┴─────────────┴───────────┘             │
│                       (bridge net)                              │
│  ┌──────────────┐                                               │
│  │  watchtower  │ ← polling 5min, pull GHCR (apenas phoenix +   │
│  └──────────────┘   publisher; postgres/redis manuais)          │
└─────────────────────────────────────────────────────────────────┘
                                                          │
                                                    cron 04:00 UTC
                                                          │
                                          pg_dump → S3 (Glacier IR 30d)
```

> MVP IP-only (sem `cpt.bet` ainda): acesso direto via `http://<static_ip>/`. Caddy
> + TLS Let's Encrypt voltam quando o domínio for registrado — vide
> [`docs/caddy-reintro.md`](docs/caddy-reintro.md).

Pipeline: `git push main` em [klevison/cpt](https://github.com/klevison/cpt) ou [klevison/wh-publisher](https://github.com/klevison/wh-publisher) → GHA build → push GHCR → Watchtower detecta SHA novo → graceful recreate.

## Estrutura

| Diretório | Conteúdo |
|---|---|
| `terraform/` | Provisionamento AWS (Lightsail, IAM, SSM, S3, Route 53) |
| `compose/` | `docker-compose.prod.yml`, `.env.example` (Caddyfile removido — vide `docs/caddy-reintro.md`) |
| `scripts/` | `backup.sh`, `restore.sh`, `refresh-env.sh`, `bootstrap-secrets.sh`, `ssh.sh` |
| `docs/` | `deploy.md` (provisionar), `runbook.md` (operar), `secrets.md` (rotacionar) |
| `docs/handoff/` | Instruções standalone para os repos `cpt/` e `wh-publisher/` |
| `.claude/` | Slash commands operacionais + subagente validador |

## Custo mensal

~$20.50 USD em IP-only: Lightsail $20 + S3 backups $0.50 + IAM/SSM/KMS $0. Quando registrar `cpt.bet`: +$0.50/mês de Route 53 zone (~$22 total) + custo único de registro do domínio.

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
