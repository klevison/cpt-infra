# Runbook operacional — cpt_bet em produção

Operações dia-a-dia. Para provisionar do zero veja [`deploy.md`](deploy.md).
Para rotacionar segredos veja [`secrets.md`](secrets.md).

## SSH

```bash
./scripts/ssh.sh                                       # shell interativo
./scripts/ssh.sh "cd /opt/cpt && sudo docker compose ps"   # comando único
```

Slash command: `/cpt-ssh "comando"`.

**Convenções operacionais críticas** (vide `CLAUDE.md` § "Acesso à instância"):

- Wrapper procura chave em `$CPT_SSH_KEY` → `~/.ssh/cpt-lightsail.pem` → `~/.ssh/cpt-lightsail`.
- Todo `docker`/`docker compose` no host exige **`sudo`** — usuário `ubuntu` não está no grupo `docker`.
- Compose só funciona com **`cd /opt/cpt &&`** antes — `.env` é `root:600` lido relativo ao dir.
- **Nunca** usar `-f /opt/cpt/docker-compose.prod.yml` — esse path não existe. O entrypoint é `/opt/cpt/docker-compose.yml` (symlink para `infra/compose/docker-compose.prod.yml`).
- Container names: `cpt-{caddy,phoenix,postgres,publisher,redis}-1`.

## Ver logs

```bash
./scripts/ssh.sh "cd /opt/cpt && sudo docker compose logs --tail=200 -f phoenix"
./scripts/ssh.sh "cd /opt/cpt && sudo docker compose logs --tail=200 -f publisher"
./scripts/ssh.sh "cd /opt/cpt && sudo docker compose logs --tail=200 -f caddy"
```

Slash command: `/cpt-logs <service>`.

Limite de retenção: `json-file max-size: 10m, max-file: 5` por container (50 MB cada).

## Restart manual

```bash
# Phoenix — leva 60s pelo stop_grace_period (XGROUP DELCONSUMER no Redis)
./scripts/ssh.sh "cd /opt/cpt && sudo docker compose restart phoenix"

# Publisher — perda de eventos durante ~30s de reconnect com WH. Evitar em horário de jogo.
./scripts/ssh.sh "cd /opt/cpt && sudo docker compose restart publisher"
```

## Deploy de imagem nova

**Não há auto-deploy.** Watchtower foi removido (projeto upstream abandonado, cliente Docker API 1.25 incompatível com daemon moderno >= 1.40 — vide commit que removeu pra contexto). Pipeline atual:

1. `git push main` em `klevison/cpt` ou `klevison/wh-publisher`
2. GHA `build.yml` builda + publica em `ghcr.io/klevison/<repo>:latest` (~3-5 min)
3. Operador roda na instância:

```bash
# Deploy de tudo que tem imagem nova
./scripts/ssh.sh "cd /opt/cpt && sudo docker compose pull && sudo docker compose up -d"

# OU deploy de service especifico (mais cirurgico)
./scripts/ssh.sh "cd /opt/cpt && sudo docker compose pull phoenix && sudo docker compose up -d phoenix"
./scripts/ssh.sh "cd /opt/cpt && sudo docker compose pull publisher && sudo docker compose up -d publisher"
```

`docker compose pull` traz só layers diferentes (rápido). `up -d` re-cria container que mudou; outros ficam intactos. Phoenix tem `stop_grace_period: 60s` — restart leva ~60s respeitando `XGROUP DELCONSUMER` em `terminate/2`.

> **Atenção quando a imagem nova exige uma env var nova** (ex: `BREVO_API_KEY` adicionada
> via `System.fetch_env!` no `runtime.exs`). Sequência obrigatória:
>
> 1. Garantir o param em SSM (geralmente `terraform apply` adicionando `aws_ssm_parameter`).
> 2. `./scripts/ssh.sh "sudo /opt/cpt/infra/scripts/refresh-env.sh"` — popular `/opt/cpt/.env`.
> 3. **Só então** `docker compose pull <serviço> && up -d <serviço>`.
>
> Inverter os passos 2 e 3 = Phoenix em crash loop (release `bin/cpt start` falha em
> `fetch_env!` antes de abrir a porta 4000). Verificar com `sudo docker compose logs phoenix`
> — `RuntimeError` mencionando o nome da var.

Quando `infra/` mudar (ex: ajuste no `docker-compose.prod.yml`), também sincronizar o repo na instância antes do `up -d`:

```bash
./scripts/ssh.sh "sudo git -C /opt/cpt/infra fetch --depth=1 origin main && sudo git -C /opt/cpt/infra reset --hard origin/main"
./scripts/ssh.sh "cd /opt/cpt && sudo docker compose pull && sudo docker compose up -d"
```

## Verificar saúde dos Redis Streams

```bash
./scripts/ssh.sh "cd /opt/cpt && sudo docker compose exec redis redis-cli XLEN wh_soccer_events"
./scripts/ssh.sh "cd /opt/cpt && sudo docker compose exec redis redis-cli XINFO GROUPS wh_soccer_events"
```

Streams existentes: `wh_soccer_events`, `wh_soccer_incidents`, `wh_soccer_event_states`,
`wh_soccer_event_settled`, `wh_soccer_event_metadata`, `wh_soccer_lineups`,
`wh_soccer_stats`, `wh_soccer_upcoming_matches`.

Slash command: `/cpt-redis-streams`.

## Backup — verificar frescor

```bash
aws ssm get-parameter --name /cpt/prod/last_backup_at --query Parameter.Value --output text
aws s3 ls s3://$(aws ssm get-parameter --name /cpt/prod/s3_backups_bucket --with-decryption --query Parameter.Value --output text)/pg/ | tail -5
```

Backup atrasado > 36h é problema. Investigar:
```bash
./scripts/ssh.sh "tail -100 /var/log/cpt-backup.log"
```

Slash command: `/cpt-backup-status`.

## Backup manual (forçar agora)

```bash
./scripts/ssh.sh "sudo /opt/cpt/infra/scripts/backup.sh"
```

`sudo` necessário porque o script chama `docker compose exec postgres pg_dump` e usuário `ubuntu` não está no grupo docker. (Quando rodado pelo cron diário, já é como root.)

## Rodar SQL ad-hoc na produção

Read-only (SELECT/EXPLAIN) é seguro. DDL/DML em prod **exige confirmação humana**.

```bash
./scripts/ssh.sh 'sudo docker exec -i cpt-postgres-1 psql -U cpt -d cpt -c "SELECT count(*) FROM soccer_matches;"'
```

- Container: `cpt-postgres-1` — User: `cpt` — DB: **`cpt`** (não `cpt_prod`).
- Aspas simples no SQL? Escapar como `'"'"'` dentro do quote externo.
- Para query multilinha, gravar arquivo e fazer pipe: `./scripts/ssh.sh 'sudo docker exec -i cpt-postgres-1 psql -U cpt -d cpt' < query.sql`.

`docker exec` direto é preferido em vez de `docker compose exec` — dispensa `cd /opt/cpt` e a leitura de `.env` (que é `root:600`).

Slash command: `/cpt-psql "<sql>"`.

## Restore

DESTRUTIVO. Veja [`scripts/restore.sh`](../scripts/restore.sh) — pede confirmação.

```bash
# 1. listar dumps disponíveis
aws s3 ls s3://cpt-backups-XXXXXXXX/pg/

# 2. SSH no host e rodar restore (sudo: o script invoca docker compose)
./scripts/ssh.sh
cd /opt/cpt
sudo ./infra/scripts/restore.sh s3://cpt-backups-XXXXXXXX/pg/cpt-20260430T040000Z.dump.gz
```

## Snapshot Lightsail (manual, fora do auto-snapshot diário)

```bash
aws lightsail create-instance-snapshot \
  --instance-name cpt-prod \
  --instance-snapshot-name cpt-prod-manual-$(date -u +%Y%m%d-%H%M%S) \
  --region eu-west-2
```

Listar:
```bash
aws lightsail get-instance-snapshots --region eu-west-2 \
  --query 'instanceSnapshots[].{name:name,createdAt:createdAt,sizeInGb:sizeInGb}' \
  --output table
```

## Postgres major upgrade (manual)

Postgres não tem label Watchtower de propósito. Roteiro 16 → 17 (todos os comandos `docker` no host levam `sudo`):

1. backup pg_dump completo (`sudo /opt/cpt/infra/scripts/backup.sh`)
2. `cd /opt/cpt && sudo docker compose stop phoenix publisher` (parar leitores)
3. snapshot Lightsail (recovery point)
4. atualizar imagem em `compose/docker-compose.prod.yml`: `postgres:16-alpine` → `postgres:17-alpine`
5. `cd /opt/cpt && sudo docker compose down postgres`
6. **NÃO** apagar volume `pg_data` — Postgres faz upgrade automático em alguns saltos; em outros (16→17 é OK) pode requerer `pg_upgrade` manual via container intermediário
7. `cd /opt/cpt && sudo docker compose up -d postgres`
8. validar `cd /opt/cpt && sudo docker compose logs postgres`
9. `cd /opt/cpt && sudo docker compose up -d phoenix publisher`

Em caso de falha: restore do snapshot Lightsail + dump do passo 1.

## Capacity / sizing

Lightsail medium_3_0 = 4 GB RAM. Distribuição esperada:
- BEAM (phoenix): ~800 MB
- Postgres: ~256 MB (`shared_buffers` default 128 MB + work_mem)
- Redis: até 1 GB (`maxmemory 1gb`)
- Publisher Python: ~150 MB
- Caddy: ~20–40 MB (TLS termination + reverse proxy)
- SO base + Docker: ~200 MB

Margem fina — monitorar:
```bash
./scripts/ssh.sh "free -h && sudo docker stats --no-stream"
```

Se RAM apertar persistentemente, considerar plano `large_3_0` ($44, 8 GB).

## Apagar instância (catastrófico)

NUNCA rodar sem confirmação humana e backup recente. Veja `terraform destroy` em [`secrets.md`](secrets.md).

## Recriar static IP (recovery de WAF/IP ban)

**Quando**: o IP do Lightsail (`35.178.28.41`) entra em deny list de algum provider externo (WAF, CloudFront, geo-block) e não relaxa sozinho em 24-72h após reduzir volume de requests. Sintomas: probes diretos do host retornam 403/451 sistemático mesmo com payload normal; outros IPs UK na mesma rede passam.

**Impacto**: ~5-15min de downtime durante propagação DNS Cloudflare + revalidação automática Caddy/ACME. **Programar fora de horário de pico** se possível.

### Pré-requisitos

- TTL Cloudflare DNS apex (`cptlive.com` A `@` e `www`) em ≤300s. Se "Auto" no plano free, é 300s — OK. Idealmente baixar pra 60s 24h antes pra acelerar propagação.
- Backup recente do Postgres (cron 04:00 UTC roda sozinho; verificar `aws s3 ls s3://cpt-backups-*/ | tail -3`).
- Acesso AWS válido: `aws sts get-caller-identity` retorna o perfil esperado.

### Playbook

1. **Aviso ao time** (Slack/canal de ops): "Vou recriar o static IP do Lightsail por motivo X. Janela ~15min começando agora."

2. **Editar `infra/terraform/lightsail.tf`** — comentar `prevent_destroy = true` do `aws_lightsail_static_ip.cpt` (mantém o da `aws_lightsail_instance`):
   ```hcl
   resource "aws_lightsail_static_ip" "cpt" {
     name = "${var.instance_name}-ip"
     lifecycle {
       # TEMPORARIAMENTE desativado pra recreate por WAF ban — restaurar em commit subsequente
       # prevent_destroy = true
     }
   }
   ```

3. **Validar e aplicar**:
   ```bash
   cd terraform/
   terraform fmt -check
   terraform validate
   terraform plan -out=tfplan -replace=aws_lightsail_static_ip.cpt -lock-timeout=60s
   # REVISAR PLAN — deve mostrar 1 destroy + 1 create do static_ip + 1 replace do attachment
   terraform apply tfplan
   ```

4. **Capturar novo IP**:
   ```bash
   aws lightsail get-static-ip --static-ip-name cpt-prod-ip --query 'staticIp.ipAddress' --output text
   ```

5. **Atualizar Cloudflare DNS** (`cptlive.com`):
   - Dashboard ou via API: editar A records `@` e `www` pro novo IP.
   - Setar TTL=60s temporariamente.
   - Confirmar `dig +short cptlive.com @1.1.1.1` retorna o novo IP em ~5min.

6. **Validar do host** (instância mesma; só o IP mudou):
   ```bash
   ./scripts/ssh.sh 'curl -s ifconfig.me'    # deve mostrar novo IP
   ```

7. **Probar endpoint problemático** (ex: NGS William Hill):
   ```bash
   ./scripts/ssh.sh 'curl -sS -o /dev/null -w "HTTP %{http_code}\n" \
     -H "user-agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36" \
     "https://sports.williamhill.com/data/ngs/matches-competitions/matches/en-gb/OB_SP9?sortKey=competition&day=today&marketType=Match+Betting&page=0&availableDays=true"'
   ```
   Esperado **HTTP 200**. Se 403: AWS pode ter reciclado IP previamente banido — repetir passos 3-7 (taint + apply do static_ip pega outro IP do pool).

8. **Caddy + Let's Encrypt**: cert atual válido até expirar (LE 90d, renewal a 30d antes). Sem necessidade de revalidar durante o swap. Caddy revalida automático quando renovação for solicitada e DNS já estará propagado. Para forçar revalidação manual:
   ```bash
   ./scripts/ssh.sh 'cd /opt/cpt && sudo docker compose restart caddy'
   ```

9. **Restaurar `prevent_destroy = true`** em commit dedicado:
   ```bash
   # editar terraform/lightsail.tf descomentando prevent_destroy
   git add terraform/lightsail.tf
   git commit -m "infra(lightsail): restaura prevent_destroy do static_ip pos-recreate"
   git push
   terraform plan   # deve dar "no changes"
   ```

10. **(Opcional)** Pós-validação 24h estável: restaurar TTL Cloudflare pra "Auto".

### Notas

- A **instância** Lightsail **não é tocada** — só o static IP é recriado e re-anexado. Volumes (`pg_data`, `redis_data`), containers, configurações no host permanecem intactos.
- Não há perda de dados em Postgres/Redis.
- Sessões WS Diffusion do publisher cairão durante a janela e reconectam automaticamente (`MAX_RECONNECTS=5` no `.env`).
- Heartbeat de `wh_soccer_matches` (Fase 7 do publisher) pode dar gap de ~5-15min — `EndedSweeper` (cutoff 180s) marcará temporariamente matches como `:ended`. Voltam a `:live` no próximo heartbeat pós-reconnect via `apply_match_list/1`.
