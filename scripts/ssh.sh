#!/usr/bin/env bash
# Wrapper SSH para o host Lightsail.
# Lê o IP do `terraform output instance_public_ip` no diretório terraform/.
# Procura chave em $CPT_SSH_KEY, ~/.ssh/cpt-lightsail.pem ou ~/.ssh/cpt-lightsail
# (nessa ordem). A versão sem .pem é o nome com que `aws lightsail download-key-pair`
# salva por default em algumas máquinas.

set -euo pipefail

KEY="${CPT_SSH_KEY:-}"
if [ -z "$KEY" ]; then
  for candidate in "$HOME/.ssh/cpt-lightsail.pem" "$HOME/.ssh/cpt-lightsail"; do
    if [ -f "$candidate" ]; then
      KEY="$candidate"
      break
    fi
  done
fi
TF_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"

if [ -z "$KEY" ] || [ ! -f "$KEY" ]; then
  echo "chave SSH não encontrada em ~/.ssh/cpt-lightsail{.pem,} nem em \$CPT_SSH_KEY" >&2
  echo "ajuste \$CPT_SSH_KEY ou crie com: aws lightsail create-key-pair --key-pair-name cpt-prod-key --region eu-west-2" >&2
  exit 1
fi

IP=$(cd "$TF_DIR" && terraform output -raw instance_public_ip 2>/dev/null || true)
if [ -z "$IP" ]; then
  echo "instance_public_ip vazio. Rodou terraform apply?" >&2
  exit 1
fi

exec ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new "ubuntu@${IP}" "$@"
