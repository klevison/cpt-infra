#!/usr/bin/env bash
# Re-puxa params SSM /cpt/prod/* → /opt/cpt/.env (modo 0600).
# Usar após rotacionar um secret no SSM:
#   1. aws ssm put-parameter --overwrite ...
#   2. ssh ... "/opt/cpt/infra/scripts/refresh-env.sh"
#   3. cd /opt/cpt && docker compose up -d   (re-cria containers afetados)

set -euo pipefail

export AWS_SHARED_CREDENTIALS_FILE=/etc/cpt/aws_credentials
AWS_REGION="${AWS_REGION:-eu-west-2}"
SSM_PREFIX="/cpt/prod"
ENV_FILE=/opt/cpt/.env

echo "[$(date -u +%FT%TZ)] refresh: pull SSM ${SSM_PREFIX} → ${ENV_FILE}"

install -m 0600 /dev/null "${ENV_FILE}"
aws ssm get-parameters-by-path \
  --path "${SSM_PREFIX}" \
  --with-decryption \
  --recursive \
  --region "${AWS_REGION}" \
  --output json \
  | jq -r '.Parameters[] | "\(.Name | split("/") | last | ascii_upcase)=\(.Value)"' \
  > "${ENV_FILE}"

chmod 0600 "${ENV_FILE}"
echo "[$(date -u +%FT%TZ)] refresh concluído. Para aplicar: cd /opt/cpt && docker compose up -d"
