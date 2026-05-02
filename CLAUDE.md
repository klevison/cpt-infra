# Convenções para Claude operar este repo

Este arquivo é instrução durável para qualquer instância do Claude Code que opere o repo `infra/` da stack `cpt_bet`.

## Idioma e estilo

- **Documentação, comentários, commits, PRs:** PT-BR.
- **Identifiers** (variáveis, recursos Terraform, nomes de containers, paths): inglês.
- **Commits:** mensagem foca no _porquê_, não no _quê_. Sem co-author. Sem citação a IA/Claude.

## Contexto da stack (resumo)

- 1 host AWS Lightsail London (`eu-west-2`, plano `medium_2_0`, $20/mês).
- 5 containers num único `docker-compose.prod.yml`: phoenix, publisher, postgres, redis, watchtower. Phoenix expõe `host:80 → container:4000` direto, sem reverse proxy à frente.
- Phoenix consome 5 Redis Streams via `XREADGROUP` em consumer groups dedicados (`cpt_phoenix_soccer*`).
- Publisher Python lê WS Diffusion da William Hill, publica em 8 streams + 2 pub/sub channels.
- Postgres é fonte de verdade. Backup `pg_dump` diário 04:00 UTC → S3 com lifecycle Glacier IR 30d.
- **MVP IP-only:** sem domínio. Acesso por `http://<static_ip>/`. Quando `cpt.bet` for registrado, Caddy volta com TLS automático — vide `docs/caddy-reintro.md`.

## Constraints duras (gotchas que matam silenciosamente)

1. **Publisher é singleton hard.** Nunca escalar para 2 réplicas — duplicaria entradas em todos os streams. Compose tem `restart: unless-stopped` e zero `--scale`.
2. **Phoenix `terminate/2` faz `XGROUP DELCONSUMER`.** Compose precisa `stop_grace_period: 60s` (já configurado). Sem isso, restart deixa consumers fantasmas e XAUTOCLAIM briga.
3. **Cada GenServer consumer Redix mantém conexão dedicada** (XREADGROUP BLOCK ocupa conexão inteira). Default `maxclients` Redis (10000) cobre.
4. **`XACK` SEMPRE pós-commit Postgres.** Crash entre `XADD` e commit = entrada no stream sem dados em Postgres.
5. **Postgres `on_conflict: :nothing` em match upsert.** Nunca `:replace_all` (sobrescreveria `event_name` etc).
6. **Streams têm MAXLEN ~ próprio.** Redis `--maxmemory-policy noeviction` evita evicção arbitrária quebrando sessões.
7. **TinyProxy não existe mais.** Publisher conecta direto `wss://scoreboards-push.williamhill.com/diffusion` via IP UK do Lightsail.

## Onde estão os segredos

- **SSM Parameter Store** path `/cpt/prod/*` — SecureString com KMS `alias/aws/ssm`.
- **NUNCA** commitar: `terraform.tfvars` (gitignored), `.env` real (montado na instância via SSM), chaves SSH `*.pem`.
- Acesso da instância ao SSM: IAM user `cpt-instance-bootstrap` com policy mínima (`ssm:GetParameter*` + `kms:Decrypt`). Access key gravada em `/etc/cpt/aws_credentials` no boot via cloud-init.

## Ordem segura para Terraform

```bash
cd terraform/
terraform fmt -check -recursive   # se falha, rodar `terraform fmt` e revisar
terraform validate
terraform plan -out=tfplan -lock-timeout=60s
# revisar plan com humano
terraform apply tfplan
```

Atalho: `/cpt-tf-plan` (slash command).

## Comandos seguros (read-only — pode rodar sem confirmação)

- `terraform plan`, `terraform validate`, `terraform fmt -check`
- `aws ssm get-parameter --name /cpt/prod/<x>` (com `--with-decryption` se SecureString)
- `aws s3 ls s3://cpt-backups-*/`
- `aws lightsail get-instance --instance-name cpt-prod`
- `docker compose ps`, `docker compose logs --tail=N <service>` (via `/cpt-ssh`)
- `gh api /user/packages/container/cpt/versions`

## Ações que EXIGEM confirmação humana

- `terraform apply` (qualquer mudança em prod)
- `terraform destroy` (catastrófico — derruba prod inteira)
- `aws ssm put-parameter --overwrite` (rotaciona secret)
- `docker compose down`, `docker compose stop` na instância
- `aws lightsail delete-instance` ou `delete-static-ip`
- `aws s3 rm` em qualquer prefixo
- `git push origin main` no `infra/`
- Restart do `publisher` em horário de jogo (perda de eventos durante ~30s)

## Apontadores rápidos

- Provisionar do zero: [`docs/deploy.md`](docs/deploy.md)
- Operar dia-a-dia: [`docs/runbook.md`](docs/runbook.md)
- Rotacionar segredos: [`docs/secrets.md`](docs/secrets.md)
- Mudanças nos repos de app: [`docs/handoff/cpt.md`](docs/handoff/cpt.md), [`docs/handoff/wh-publisher.md`](docs/handoff/wh-publisher.md)
- Slash commands: `.claude/commands/cpt-*.md`
