# Runbook operacional — cpt_bet em produção

Operações dia-a-dia. Para provisionar do zero veja [`deploy.md`](deploy.md).
Para rotacionar segredos veja [`secrets.md`](secrets.md).

## SSH

```bash
./scripts/ssh.sh                            # shell interativo
./scripts/ssh.sh "docker compose ps"        # comando único
```

Slash command: `/cpt-ssh "comando"`.

## Ver logs

```bash
./scripts/ssh.sh "cd /opt/cpt && docker compose logs --tail=200 -f phoenix"
./scripts/ssh.sh "cd /opt/cpt && docker compose logs --tail=200 -f publisher"
./scripts/ssh.sh "cd /opt/cpt && docker compose logs --tail=200 -f watchtower"
```

Slash command: `/cpt-logs <service>`.

Limite de retenção: `json-file max-size: 10m, max-file: 5` por container (50 MB cada).

## Restart manual

```bash
# Phoenix — leva 60s pelo stop_grace_period (XGROUP DELCONSUMER no Redis)
./scripts/ssh.sh "cd /opt/cpt && docker compose restart phoenix"

# Publisher — perda de eventos durante ~30s de reconnect com WH. Evitar em horário de jogo.
./scripts/ssh.sh "cd /opt/cpt && docker compose restart publisher"
```

## Forçar deploy de imagem nova (Watchtower normalmente faz)

Watchtower faz polling a cada 5min. Para forçar agora:

```bash
./scripts/ssh.sh "cd /opt/cpt && docker compose pull phoenix && docker compose up -d phoenix"
```

## Verificar saúde dos Redis Streams

```bash
./scripts/ssh.sh "cd /opt/cpt && docker compose exec redis redis-cli XLEN wh_soccer_events"
./scripts/ssh.sh "cd /opt/cpt && docker compose exec redis redis-cli XINFO GROUPS wh_soccer_events"
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
./scripts/ssh.sh "/opt/cpt/infra/scripts/backup.sh"
```

## Restore

DESTRUTIVO. Veja [`scripts/restore.sh`](../scripts/restore.sh) — pede confirmação.

```bash
# 1. listar dumps disponíveis
aws s3 ls s3://cpt-backups-XXXXXXXX/pg/

# 2. SSH no host e rodar restore
./scripts/ssh.sh
cd /opt/cpt
./infra/scripts/restore.sh s3://cpt-backups-XXXXXXXX/pg/cpt-20260430T040000Z.dump.gz
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

Postgres não tem label Watchtower de propósito. Roteiro 16 → 17:

1. backup pg_dump completo (`scripts/backup.sh`)
2. `docker compose stop phoenix publisher` (parar leitores)
3. snapshot Lightsail (recovery point)
4. atualizar imagem em `compose/docker-compose.prod.yml`: `postgres:16-alpine` → `postgres:17-alpine`
5. `docker compose down postgres`
6. **NÃO** apagar volume `pg_data` — Postgres faz upgrade automático em alguns saltos; em outros (16→17 é OK) pode requerer `pg_upgrade` manual via container intermediário
7. `docker compose up -d postgres`
8. validar `docker compose logs postgres`
9. `docker compose up -d phoenix publisher`

Em caso de falha: restore do snapshot Lightsail + dump do passo 1.

## Capacity / sizing

Lightsail medium_2_0 = 4 GB RAM. Distribuição esperada:
- BEAM (phoenix): ~800 MB
- Postgres: ~256 MB (`shared_buffers` default 128 MB + work_mem)
- Redis: até 1 GB (`maxmemory 1gb`)
- Publisher Python: ~150 MB
- Watchtower + SO: ~250 MB
- (Caddy retornará com ~20–40 MB extra quando reintroduzido com domínio)

Margem fina — monitorar:
```bash
./scripts/ssh.sh "free -h && docker stats --no-stream"
```

Se RAM apertar persistentemente, considerar plano `large_2_0` ($40, 8 GB).

## Apagar instância (catastrófico)

NUNCA rodar sem confirmação humana e backup recente. Veja `terraform destroy` em [`secrets.md`](secrets.md).
