---
description: Status geral da stack — Lightsail, containers, último backup, último deploy.
allowed-tools: Bash
---

Reúne em um relatório breve o estado atual da stack cpt_bet.

## O que fazer

Executar em paralelo (mesma mensagem com múltiplos Bash) e formatar como tabela:

1. **Instância Lightsail** (status, blueprintId, criação):
   ```bash
   aws lightsail get-instance --instance-name cpt-prod --region eu-west-2 \
     --query 'instance.{state:state.name,blueprint:blueprintId,bundle:bundleId,publicIp:publicIpAddress,createdAt:createdAt}' \
     --output table
   ```

2. **Containers** (ps + logs muito curtos para detectar crash loop):
   ```bash
   ./scripts/ssh.sh "cd /opt/cpt && docker compose ps --format 'table {{.Service}}\t{{.Status}}\t{{.State}}'"
   ```

3. **Último backup**:
   ```bash
   aws ssm get-parameter --name /cpt/prod/last_backup_at \
     --query Parameter.Value --output text --region eu-west-2 \
     || echo "(nunca rodou)"
   ```

4. **Última imagem GHCR**:
   ```bash
   gh api /user/packages/container/cpt/versions --jq '.[0] | {sha: .name, tags: .metadata.container.tags, updated_at: .updated_at}' 2>/dev/null \
     || echo "(sem permissão ou imagem não existe)"
   gh api /user/packages/container/wh-publisher/versions --jq '.[0] | {sha: .name, tags: .metadata.container.tags, updated_at: .updated_at}' 2>/dev/null \
     || echo "(sem permissão ou imagem não existe)"
   ```

## Saída

Resumo em PT-BR de 6–10 linhas. Sinalizar com 🚨 (apenas neste output, não em código)
se: container em estado diferente de `running`, último backup > 36h, instância em
qualquer estado != `running`.
