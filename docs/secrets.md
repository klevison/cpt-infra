# Gestão de segredos — SSM Parameter Store + IAM

Todos os segredos vivem em **SSM Parameter Store** path `/cpt/prod/*` (SecureString,
KMS `alias/aws/ssm`). A instância acessa via **IAM user dedicado**
`cpt-instance-bootstrap` cuja access key fica em `/etc/cpt/aws_credentials` (modo 0600).

## Inventário de segredos

| Parâmetro SSM | Origem | Rotacionável | Quem usa |
|---|---|---|---|
| `/cpt/prod/secret_key_base` | random_password TF (length 64) | sim | Phoenix (cookie/session) |
| `/cpt/prod/internal_token` | random_password TF (length 48) | sim | Phoenix + Publisher (auth) |
| `/cpt/prod/postgres_password` | random_password TF (length 32) | requer ALTER USER | Postgres + DATABASE_URL |
| `/cpt/prod/database_url` | derivado postgres_password | derivado | Phoenix |
| `/cpt/prod/ghcr_token` | var.ghcr_token (terraform.tfvars) | sim | docker login + Watchtower |
| `/cpt/prod/last_backup_at` | escrito pelo backup.sh | n/a (status) | observabilidade |

## Listar parâmetros

```bash
aws ssm get-parameters-by-path \
  --path /cpt/prod \
  --recursive \
  --query 'Parameters[].Name' \
  --output table
```

Ler valor:
```bash
aws ssm get-parameter \
  --name /cpt/prod/secret_key_base \
  --with-decryption \
  --query Parameter.Value \
  --output text
```

## Rotacionar `secret_key_base` ou `internal_token`

Via slash command guiado:
```
/cpt-rotate secret_key_base
/cpt-rotate internal_token
```

Manualmente:
```bash
# 1. gerar valor novo
NEW=$(openssl rand -base64 64 | tr -d '\n=' | head -c 64)

# 2. sobrescrever no SSM
aws ssm put-parameter \
  --name /cpt/prod/secret_key_base \
  --type SecureString \
  --value "$NEW" \
  --overwrite \
  --region eu-west-2

# 3. recarregar .env na instância e reiniciar serviços afetados
./scripts/ssh.sh "/opt/cpt/infra/scripts/refresh-env.sh && cd /opt/cpt && docker compose up -d phoenix"
```

`secret_key_base` afeta apenas Phoenix. `internal_token` afeta Phoenix + Publisher.

## Rotacionar `postgres_password` (DESTRUTIVO se feito errado)

Não rodar `/cpt-rotate postgres_password` cegamente. Procedimento:

```bash
# 1. backup defensivo
./scripts/ssh.sh "/opt/cpt/infra/scripts/backup.sh"

# 2. gerar nova senha
NEW=$(openssl rand -base64 32 | tr -d '\n=/+' | head -c 32)

# 3. ALTER USER no Postgres ANTES de mudar SSM
./scripts/ssh.sh "cd /opt/cpt && docker compose exec -T postgres psql -U cpt -d cpt -c \"ALTER USER cpt WITH PASSWORD '$NEW';\""

# 4. atualizar SSM (ambos os params)
aws ssm put-parameter --name /cpt/prod/postgres_password --type SecureString --value "$NEW" --overwrite --region eu-west-2
aws ssm put-parameter --name /cpt/prod/database_url --type SecureString --value "ecto://cpt:$NEW@postgres:5432/cpt" --overwrite --region eu-west-2

# 5. refresh env e restart Phoenix (Postgres mantém a senha em memória; só Phoenix precisa reler)
./scripts/ssh.sh "/opt/cpt/infra/scripts/refresh-env.sh && cd /opt/cpt && docker compose up -d phoenix"
```

## Rotacionar `ghcr_token`

Quando o PAT GitHub expira ou é revogado:

```bash
# 1. criar novo PAT em github.com/settings/tokens (escopo read:packages)
# 2. atualizar SSM
aws ssm put-parameter --name /cpt/prod/ghcr_token --type SecureString --value "ghp_NOVO_TOKEN" --overwrite --region eu-west-2

# 3. refazer docker login na instância
./scripts/ssh.sh '/opt/cpt/infra/scripts/refresh-env.sh && set -a && . /opt/cpt/.env && set +a && echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin'
```

## Rotacionar access key do IAM user `cpt-instance-bootstrap`

A chave gravada em `/etc/cpt/aws_credentials` deve ser rotacionada periodicamente
(a cada 6 meses, recomendado):

```bash
cd ~/Development/cpt_bet/infra/terraform

# Cria nova access key + atualiza user-data + dispara recreate da instância via cloud-init
# CUIDADO: replace força recriação da access key.
terraform apply -replace=aws_iam_access_key.bootstrap

# A chave nova é gravada no estado. Para aplicar na instância em execução:
terraform output -raw bootstrap_aws_access_key_id
terraform output -raw bootstrap_aws_secret_access_key

# Atualizar /etc/cpt/aws_credentials manualmente via SSH:
./scripts/ssh.sh "sudo tee /etc/cpt/aws_credentials >/dev/null" <<EOF
[default]
aws_access_key_id = <NOVA_KEY_ID>
aws_secret_access_key = <NOVA_SECRET>
region = eu-west-2
EOF
./scripts/ssh.sh "sudo chmod 600 /etc/cpt/aws_credentials"
```

> Alternativa mais limpa: scrap da instância via `terraform apply -replace=aws_lightsail_instance.cpt`.
> User-data roda novamente e grava as chaves novas. **Mas perde estado dos containers** —
> use só com backup recente do Postgres.

## Boas práticas

- **Nunca** logar valor de SecureString. Slash commands `/cpt-rotate` mascaram.
- Rotacionar `secret_key_base` e `internal_token` a cada 6 meses (ou após qualquer suspeita de vazamento).
- Snapshots Lightsail são privados — **nunca** marcar como compartilhados, vazaria
  `/etc/cpt/aws_credentials`.
- `terraform.tfvars` (com `ghcr_token`) é gitignored — confirme com `git status`.
- Histórico do estado Terraform fica local (`terraform.tfstate`). Gitignored. Considerar
  backend S3 + lock DynamoDB no futuro (post-MVP).

## Em caso de comprometimento

1. Revogar imediatamente o PAT GHCR (github.com/settings/tokens) e gerar novo.
2. Rotacionar TODOS os secrets via `/cpt-rotate` para cada um.
3. `terraform apply -replace=aws_iam_access_key.bootstrap` para anular access key vazada.
4. Audit trail: `aws cloudtrail lookup-events --lookup-attributes AttributeKey=Username,AttributeValue=cpt-instance-bootstrap`.
5. Considerar rebuild completo: `terraform apply -replace=aws_lightsail_instance.cpt` (após backup).
