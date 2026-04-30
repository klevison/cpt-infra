#!/usr/bin/env bash
# Wrapper SSH para o host Lightsail.
# Lê o IP do `terraform output instance_public_ip` no diretório terraform/.
# Espera chave em ~/.ssh/cpt-lightsail.pem (ou $CPT_SSH_KEY).

set -euo pipefail

KEY="${CPT_SSH_KEY:-$HOME/.ssh/cpt-lightsail.pem}"
TF_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"

if [ ! -f "$KEY" ]; then
  echo "chave SSH não encontrada em $KEY" >&2
  echo "criar com: aws lightsail create-key-pair --key-pair-name cpt-prod-key --region eu-west-2" >&2
  exit 1
fi

IP=$(cd "$TF_DIR" && terraform output -raw instance_public_ip 2>/dev/null || true)
if [ -z "$IP" ]; then
  echo "instance_public_ip vazio. Rodou terraform apply?" >&2
  exit 1
fi

exec ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "ubuntu@${IP}" "$@"
