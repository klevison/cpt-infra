#!/usr/bin/env bash
# Bootstrap da instância Lightsail cpt-prod.
# Renderizado por terraform via templatefile().
# Convenção: variáveis interpoladas por Terraform aparecem sem escape (aws_region, ssm_prefix, etc).
# Variáveis bash que devem chegar literais ao shell usam $${VAR} (escape do templatefile).
#
# Ordem:
#   1. instalar pacotes base
#   2. instalar Docker oficial + plugin compose
#   3. configurar /etc/docker/daemon.json (rotação de log)
#   4. instalar AWS CLI v2
#   5. exportar AWS_SHARED_CREDENTIALS_FILE
#   6. clonar infra-repo
#   7. fetch_ssm() → /opt/cpt/.env
#   8. symlinks compose + Caddyfile
#   9. docker login ghcr.io
#  10. cron de backup
#  11. docker compose up -d
#  12. healthcheck pós-boot

set -euxo pipefail
exec > >(tee -a /var/log/cpt-bootstrap.log) 2>&1

echo "[bootstrap] $(date -u +%FT%TZ) iniciando"

AWS_REGION="${aws_region}"
SSM_PREFIX="${ssm_prefix}"
INFRA_REPO_URL="${infra_repo_url}"
INFRA_REPO_REF="${infra_repo_ref}"

export AWS_SHARED_CREDENTIALS_FILE=/etc/cpt/aws_credentials
export AWS_DEFAULT_REGION="$AWS_REGION"

# 1. pacotes base
export DEBIAN_FRONTEND=noninteractive
apt-get update -o Acquire::Retries=3
apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  unzip \
  cron \
  jq \
  git

# 2. Docker oficial + compose plugin
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

UBUNTU_CODENAME=$(. /etc/os-release && echo "$${VERSION_CODENAME}")
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $${UBUNTU_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -o Acquire::Retries=3
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# 3. daemon.json — rotação de log
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  }
}
EOF
systemctl restart docker

# 4. AWS CLI v2
if ! command -v aws >/dev/null 2>&1; then
  cd /tmp
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
  unzip -q awscliv2.zip
  ./aws/install
  rm -rf awscliv2.zip aws
fi

# 5. exportar credenciais para cron e SSH interativo
cat > /etc/profile.d/cpt.sh <<EOF
export AWS_SHARED_CREDENTIALS_FILE=/etc/cpt/aws_credentials
export AWS_DEFAULT_REGION=$AWS_REGION
EOF
chmod 0644 /etc/profile.d/cpt.sh

grep -q 'AWS_SHARED_CREDENTIALS_FILE=' /etc/environment \
  || echo 'AWS_SHARED_CREDENTIALS_FILE=/etc/cpt/aws_credentials' >> /etc/environment

# 6. clonar infra-repo
mkdir -p /opt/cpt
if [ ! -d /opt/cpt/infra/.git ]; then
  git clone --depth=1 --branch="$INFRA_REPO_REF" "$INFRA_REPO_URL" /opt/cpt/infra
fi

# 7. fetch_ssm — pull SSM /cpt/prod/* → /opt/cpt/.env
fetch_ssm() {
  local out=/opt/cpt/.env
  install -m 0600 /dev/null "$out"
  aws ssm get-parameters-by-path \
    --path "$SSM_PREFIX" \
    --with-decryption \
    --recursive \
    --region "$AWS_REGION" \
    --output json \
    | jq -r '.Parameters[] | "\(.Name | split("/") | last | ascii_upcase)=\(.Value)"' \
    > "$out"
  chmod 0600 "$out"
}
fetch_ssm

# 8. symlinks
ln -sf /opt/cpt/infra/compose/docker-compose.prod.yml /opt/cpt/docker-compose.yml
cp /opt/cpt/infra/compose/Caddyfile /opt/cpt/Caddyfile

# 9. docker login ghcr.io (lê GHCR_USER e GHCR_TOKEN do .env)
set +x  # não logar token
# shellcheck disable=SC1091
. /opt/cpt/.env
echo "$${GHCR_TOKEN}" | docker login ghcr.io -u "$${GHCR_USER}" --password-stdin
set -x

# 10. cron de backup pg_dump
cat > /etc/cron.d/cpt-backup <<'EOF'
# pg_dump diário 04:00 UTC → S3 (Glacier IR aos 30d)
0 4 * * * root /opt/cpt/infra/scripts/backup.sh >> /var/log/cpt-backup.log 2>&1
EOF
chmod 0644 /etc/cron.d/cpt-backup
systemctl restart cron

# 11. docker compose up -d
cd /opt/cpt
docker compose pull
docker compose up -d

# 12. healthcheck pós-boot — não falha o user-data, só registra
echo "[bootstrap] aguardando publisher conectar (até 5min)..."
for i in $(seq 1 30); do
  if docker compose logs publisher 2>&1 | grep -qE '(CONNECTED|WS connected|WebSocket aberto)'; then
    echo "[bootstrap] publisher conectado na WH (iteração $i)"
    break
  fi
  sleep 10
done

touch /var/lib/cloud/instance/cpt-bootstrap.done
echo "[bootstrap] $(date -u +%FT%TZ) concluído"
