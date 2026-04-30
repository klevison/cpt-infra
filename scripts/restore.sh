#!/usr/bin/env bash
# Restore destrutivo — substitui o conteúdo do banco cpt pelo dump informado.
# Uso: scripts/restore.sh s3://cpt-backups-XXXX/pg/cpt-YYYYMMDDTHHMMSSZ.dump.gz
#
# Pede confirmação humana antes de aplicar.

set -euo pipefail

export AWS_SHARED_CREDENTIALS_FILE=/etc/cpt/aws_credentials

if [ "$#" -ne 1 ]; then
  echo "uso: $0 s3://<bucket>/pg/cpt-<stamp>.dump.gz" >&2
  exit 64
fi

S3_URI="$1"

cd /opt/cpt
set -a
# shellcheck disable=SC1091
. ./.env
set +a

cat <<EOF
ATENÇÃO: operação DESTRUTIVA.
   - banco: cpt (dentro do container postgres)
   - origem: ${S3_URI}
   - tabelas existentes serão DROPADAS antes do restore (--clean --if-exists).
EOF

read -r -p "Digite 'restaurar' para prosseguir: " CONFIRM
if [ "${CONFIRM:-}" != "restaurar" ]; then
  echo "abortado." >&2
  exit 1
fi

echo "[$(date -u +%FT%TZ)] baixando dump..."
aws s3 cp "${S3_URI}" - --region "${AWS_REGION}" \
  | gunzip \
  | docker compose exec -T postgres pg_restore -U cpt -d cpt --clean --if-exists --no-owner

echo "[$(date -u +%FT%TZ)] restore concluído. Reiniciando phoenix para limpar conexões/cache."
docker compose restart phoenix
