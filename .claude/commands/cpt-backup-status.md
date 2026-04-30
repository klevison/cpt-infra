---
description: Verifica frescor do último pg_dump e lista os 5 dumps mais recentes em S3.
allowed-tools: Bash
---

## O que fazer

1. Ler timestamp do último backup:
   ```bash
   LAST=$(aws ssm get-parameter --name /cpt/prod/last_backup_at \
     --query Parameter.Value --output text --region eu-west-2 2>/dev/null || echo "")
   echo "Último backup (SSM): ${LAST:-nunca rodou}"
   ```

2. Listar últimos dumps em S3:
   ```bash
   BUCKET=$(aws ssm get-parameter --name /cpt/prod/s3_backups_bucket --with-decryption \
     --query Parameter.Value --output text --region eu-west-2)
   aws s3 ls "s3://${BUCKET}/pg/" --region eu-west-2 | tail -5
   ```

3. Calcular idade do último backup:
   - parsear `LAST` (formato `YYYYMMDDTHHMMSSZ`)
   - converter para timestamp Unix
   - comparar com `now`
   - se > 36h, alertar com 🚨

## Saída

Tabela:
- Linha 1: timestamp último backup + idade em horas
- Linha 2-6: 5 últimos dumps em S3 com tamanho
- Linha final: status (OK / 🚨 atrasado)

Se status alertar, sugerir investigar:
```bash
./scripts/ssh.sh "tail -100 /var/log/cpt-backup.log"
```
