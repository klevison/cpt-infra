# Deploy do zero — provisionar a stack cpt_bet em AWS Lightsail London

Tempo estimado: 30–45 min de provisionamento (a maior parte é espera).

## Pré-requisitos locais

| Ferramenta | Versão mínima | Como verificar |
|---|---|---|
| Terraform | 1.14+ | `terraform version` |
| AWS CLI v2 | 2.x | `aws --version` |
| Docker + Compose v2 | 24+ | `docker version && docker compose version` |
| GitHub CLI (`gh`) | 2.x | `gh auth status` |
| `jq` | 1.6+ | `jq --version` |

> AWS CLI quebrado por Python 3.14 (libexpat)? Reinstalar:
> `brew uninstall awscli && brew install awscli`

## 1. Configurar credenciais AWS admin

Use um perfil dedicado (não confundir com o IAM user `cpt-instance-bootstrap` que o Terraform criará):

```bash
aws configure --profile cpt-admin
aws sts get-caller-identity --profile cpt-admin
export AWS_PROFILE=cpt-admin
```

## 2. Registrar `cpt.bet` em Route 53

Pela própria AWS Route 53 (~$26 USD). Após o registro, a hosted zone é criada automaticamente.

Verificar:
```bash
aws route53 list-hosted-zones --query 'HostedZones[?Name==`cpt.bet.`]'
```

## 3. Criar key pair Lightsail (uma vez)

Terraform **não** gerencia o key pair (vazaria privada no state). Criação manual:

```bash
aws lightsail create-key-pair \
  --key-pair-name cpt-prod-key \
  --region eu-west-2 \
  --query 'privateKeyBase64' \
  --output text \
  | base64 -d > ~/.ssh/cpt-lightsail.pem

chmod 600 ~/.ssh/cpt-lightsail.pem
```

## 4. Criar PAT GitHub

Em https://github.com/settings/tokens (classic), escopo apenas `read:packages`. Anotar — só é mostrado uma vez.

## 5. Preparar `infra/` como repo público no GitHub

```bash
cd ~/Development/cpt_bet/infra
git init -b main
gh repo create klevison/cpt-infra --public --source=. --remote=origin
git add .
git commit -m "infra: bootstrap inicial"
git push -u origin main
```

## 6. Aplicar handoffs nos repos `cpt/` e `wh-publisher/`

Cada repo é independente. Ler e executar:

- `~/Development/cpt_bet/cpt/` → seguir [`docs/handoff/cpt.md`](handoff/cpt.md)
- `~/Development/cpt_bet/wh-publisher/` → seguir [`docs/handoff/wh-publisher.md`](handoff/wh-publisher.md)

Resultado esperado: workflows GHA rodam, imagens publicadas em
`ghcr.io/klevison/cpt:latest` e `ghcr.io/klevison/wh-publisher:latest`.

Confirmar antes de seguir:
```bash
gh api /user/packages/container/cpt/versions --jq '.[0].metadata.container.tags'
gh api /user/packages/container/wh-publisher/versions --jq '.[0].metadata.container.tags'
```

## 7. Preencher `terraform.tfvars`

```bash
cd ~/Development/cpt_bet/infra/terraform
cp terraform.tfvars.example terraform.tfvars
# editar terraform.tfvars: ghcr_token = "ghp_..." (PAT do passo 4)
```

`terraform.tfvars` é gitignored. Confirmar com `git status` que NÃO aparece staged.

## 8. Aplicar Terraform

```bash
cd ~/Development/cpt_bet/infra/terraform
terraform init
terraform plan -out=tfplan
# revisar plan — deve listar ~25 recursos a criar
terraform apply tfplan
```

Atalho via slash command (revisa fmt + validate antes do plan): `/cpt-tf-plan`.

Saídas relevantes:
```bash
terraform output instance_public_ip
terraform output -raw ssh_command
```

## 9. Aguardar boot (~5–7 min)

O user-data instala Docker, puxa SSM, faz `docker login`, sobe o compose. Acompanhar:

```bash
../scripts/ssh.sh "tail -f /var/log/cpt-bootstrap.log"
```

Espere a linha `[bootstrap] concluído`.

## 10. Verificar

```bash
# Acesso direto (MVP IP-only — sem domínio, sem TLS)
IP=$(terraform output -raw instance_public_ip)
curl -I "http://${IP}/live-events"

# Quando registrar cpt.bet e ativar enable_route53=true:
#   dig cpt.bet A +short
#   curl -I https://cpt.bet/live-events   # ver docs/caddy-reintro.md

# Publisher conectado na WH
../scripts/ssh.sh "cd /opt/cpt && docker compose logs publisher --tail=50 | grep -E '(CONNECTED|WS connected)'"

# Streams populando
../scripts/ssh.sh "cd /opt/cpt && docker compose exec redis redis-cli XLEN wh_soccer_events"

# Phoenix consumindo
../scripts/ssh.sh "cd /opt/cpt && docker compose exec redis redis-cli XINFO GROUPS wh_soccer_events"
```

Atalhos:
- `/cpt-status` — ps, uptime, último deploy
- `/cpt-redis-streams` — saúde dos 8 streams
- `/cpt-backup-status` — último pg_dump

## 11. Restringir SSH (opcional, recomendado)

Após o primeiro acesso bem-sucedido, alterar `terraform.tfvars`:
```hcl
allowed_ssh_cidrs = ["SEU.IP.PUBLICO/32"]
```
Depois `terraform apply`.

## Custo mensal esperado

~$22 USD: Lightsail $20 + S3 backups $0.50 + Route 53 $0.50 + IAM/SSM/KMS $0.
