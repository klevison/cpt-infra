---
description: Roda SQL ad-hoc na produção via docker exec no container Postgres.
argument-hint: "<sql>"
allowed-tools: Bash
---

## Contexto

- Container: `cpt-postgres-1`
- User: `cpt` (`POSTGRES_USER`)
- DB: **`cpt`** (`POSTGRES_DB`) — NÃO `cpt_prod`, apesar do path SSM `/cpt/prod/`.
- Acesso direto via `docker exec` dispensa compose/.env e é à prova das gotchas
  de path/permissão do compose.

## O que fazer

1. Validar que `$ARGUMENTS` é uma string SQL não-vazia. Se vazio, perguntar ao usuário qual query rodar.

2. **Classificar a query**:
   - **Read-only** (`SELECT`, `EXPLAIN`, `\d`, `\dt`, `\l`, `SHOW`, `WITH ... SELECT`): pode rodar direto.
   - **DDL/DML** (`INSERT`, `UPDATE`, `DELETE`, `ALTER`, `DROP`, `TRUNCATE`, `CREATE`, `GRANT`, `REVOKE`, `COPY ... FROM`): **PARAR e pedir confirmação humana explicitamente** antes de rodar. Modifica produção.

3. Rodar (escapando aspas simples internas no SQL como `'"'"'`):
   ```bash
   ./scripts/ssh.sh 'sudo docker exec -i cpt-postgres-1 psql -U cpt -d cpt -c "<SQL>"'
   ```

4. Retornar a saída tabular do psql ao usuário.

## Notas

- **Por que `docker exec` direto e não `docker compose exec`?** Compose precisa ler `/opt/cpt/.env` (root:600) e exige `cd /opt/cpt`. `docker exec` direto no nome do container pula tudo isso — só precisa de `sudo` (usuário `ubuntu` não está no grupo `docker`).
- Para query multilinha ou com muitos `'`/`$$`/`"` literais, gravar arquivo temporário e fazer redirect:
  ```bash
  ./scripts/ssh.sh 'sudo docker exec -i cpt-postgres-1 psql -U cpt -d cpt' < /tmp/query.sql
  ```
- Saída CSV-like (sem header/border): adicionar flags `-A -t` ao `psql`.
- Listar tabelas: `\dt`. Schema de tabela: `\d soccer_matches`. Tamanho: `\dt+`.
- **Nunca** logar resultados que contenham PII/secrets no chat.
