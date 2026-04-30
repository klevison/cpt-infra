#!/usr/bin/env bash
# Rotação manual de secrets em SSM (opcional após o terraform apply inicial,
# que já gera todos os secrets via random_password com lifecycle ignore_changes).
#
# Uso:
#   scripts/bootstrap-secrets.sh rotate <secret_name>
#
# secret_name aceitos:
#   secret_key_base       (Phoenix — restart phoenix após)
#   internal_token        (Phoenix + Publisher — restart ambos)
#   postgres_password     (Postgres — atenção: aplicação destrutiva — vide docs/secrets.md)
#   ghcr_token            (GHCR PAT — após rotação, refazer docker login na instância)
#
# Após rodar, SSH na instância e executar:
#   /opt/cpt/infra/scripts/refresh-env.sh
#   cd /opt/cpt && docker compose up -d <serviço afetado>

set -euo pipefail

AWS_REGION="${AWS_REGION:-eu-west-2}"
SSM_PREFIX="/cpt/prod"

usage() {
  cat <<EOF
uso: $0 rotate <secret_name>

secret_name: secret_key_base | internal_token | postgres_password | ghcr_token

Exemplo:
  $0 rotate secret_key_base
EOF
  exit 64
}

[ "$#" -eq 2 ] || usage
[ "$1" = "rotate" ] || usage

SECRET_NAME="$2"

case "$SECRET_NAME" in
  secret_key_base)
    NEW_VALUE=$(openssl rand -base64 64 | tr -d '\n=' | head -c 64)
    AFFECTED="phoenix"
    ;;
  internal_token)
    NEW_VALUE=$(openssl rand -base64 48 | tr -d '\n=' | head -c 48)
    AFFECTED="phoenix publisher"
    ;;
  postgres_password)
    cat <<'EOF' >&2
ATENÇÃO: rotacionar postgres_password requer ALTER USER no banco antes de
sobrescrever o SSM, senão o Phoenix perde acesso. Veja docs/secrets.md
para o procedimento manual. Abortando.
EOF
    exit 1
    ;;
  ghcr_token)
    read -r -s -p "Cole o novo PAT GitHub (read:packages): " NEW_VALUE
    echo
    [ -n "$NEW_VALUE" ] || { echo "vazio, abortando." >&2; exit 1; }
    AFFECTED="docker login (refazer manualmente após refresh-env)"
    ;;
  *)
    echo "secret_name inválido: $SECRET_NAME" >&2
    usage
    ;;
esac

cat <<EOF
Rotacionar /cpt/prod/${SECRET_NAME}
   afeta: ${AFFECTED}
EOF
read -r -p "Digite 'rotacionar' para prosseguir: " CONFIRM
[ "${CONFIRM:-}" = "rotacionar" ] || { echo "abortado." >&2; exit 1; }

aws ssm put-parameter \
  --name "${SSM_PREFIX}/${SECRET_NAME}" \
  --type SecureString \
  --value "${NEW_VALUE}" \
  --overwrite \
  --region "${AWS_REGION}" >/dev/null

# Caso especial: database_url embute postgres_password — não tratado aqui
# porque postgres_password rotation já abortou acima.

echo "[$(date -u +%FT%TZ)] /cpt/prod/${SECRET_NAME} atualizado em SSM."
echo "Próximos passos na instância:"
echo "  scripts/ssh.sh '/opt/cpt/infra/scripts/refresh-env.sh && cd /opt/cpt && docker compose up -d ${AFFECTED}'"
