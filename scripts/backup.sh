#!/usr/bin/env bash
# Backup diário pg_dump → S3.
# Invocado por /etc/cron.d/cpt-backup às 04:00 UTC (root).
# pg_dump roda dentro do container postgres via `docker compose exec -T`.

set -euo pipefail

export AWS_SHARED_CREDENTIALS_FILE=/etc/cpt/aws_credentials

cd /opt/cpt

# Cron não herda /etc/environment de forma confiável — exportar tudo do .env.
set -a
# shellcheck disable=SC1091
. ./.env
set +a

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
KEY="pg/cpt-${STAMP}.dump.gz"

echo "[$(date -u +%FT%TZ)] iniciando backup → s3://${S3_BACKUPS_BUCKET}/${KEY}"

docker compose exec -T postgres pg_dump -U cpt -Fc cpt \
  | gzip -9 \
  | aws s3 cp - "s3://${S3_BACKUPS_BUCKET}/${KEY}" \
      --region "${AWS_REGION}"

aws ssm put-parameter \
  --name /cpt/prod/last_backup_at \
  --type String \
  --value "${STAMP}" \
  --overwrite \
  --region "${AWS_REGION}" >/dev/null

echo "[$(date -u +%FT%TZ)] backup concluído"
