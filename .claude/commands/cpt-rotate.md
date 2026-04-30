---
description: Rotaciona um secret no SSM e re-sincroniza o host.
argument-hint: "<secret_name>"
allowed-tools: Bash
---

## Contexto

Wrapper guiado para rotação de secrets. Aceita:
- `secret_key_base` — Phoenix
- `internal_token` — Phoenix + Publisher
- `ghcr_token` — pede PAT novo via prompt
- `postgres_password` — **bloqueado**, requer ALTER USER manual (ver `docs/secrets.md`)

## O que fazer

1. Validar `$ARGUMENTS` é um dos 4 nomes acima. Se inválido ou vazio, listar e parar.

2. Se `postgres_password`, **NÃO PROSSEGUIR**. Mostrar instrução para o usuário:
   "Rotação de postgres_password requer ALTER USER no banco antes do SSM. Veja
   `docs/secrets.md` seção 'Rotacionar postgres_password' para o procedimento."

3. **Pedir confirmação humana** antes de continuar:
   "Vou rotacionar `/cpt/prod/$ARGUMENTS`. Isso afeta: <serviços>. Confirma? (sim/não)"

4. Após confirmação, rodar:
   ```bash
   ./scripts/bootstrap-secrets.sh rotate $ARGUMENTS
   ```

5. O script `bootstrap-secrets.sh` já pede confirmação interna e mostra o comando
   de refresh-env a rodar na instância. Repassar a saída ao usuário.

6. Perguntar se o usuário quer aplicar agora:
   "Aplicar `refresh-env.sh` + restart dos serviços afetados na instância?"

   Se sim:
   ```bash
   ./scripts/ssh.sh "/opt/cpt/infra/scripts/refresh-env.sh && cd /opt/cpt && docker compose up -d <SERVIÇOS>"
   ```

7. Verificar saúde com `/cpt-status`.

## Notas

- **Nunca** logar o valor do secret novo no chat.
- `bootstrap-secrets.sh` para `ghcr_token` pede o PAT em prompt interativo (`read -s`).
  Se a sessão Claude Code não tem TTY, sugerir o usuário rodar manualmente:
  `./scripts/bootstrap-secrets.sh rotate ghcr_token`.
