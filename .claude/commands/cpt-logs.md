---
description: Mostra logs (tail) de um service do compose no host.
argument-hint: "<service> [n_linhas=200]"
allowed-tools: Bash
---

Use `scripts/ssh.sh` para rodar `docker compose logs` no serviço pedido.

## Argumentos

- `$1` — nome do service (`phoenix`, `publisher`, `postgres`, `redis`, `watchtower`).
- `$2` — quantidade de linhas (opcional, default 200).

## O que fazer

Se o usuário não passou service, listar os disponíveis e perguntar qual.

Caso contrário:

```bash
SERVICE="$1"
LINES="${2:-200}"
./scripts/ssh.sh "cd /opt/cpt && docker compose logs --tail=$LINES $SERVICE"
```

Não usar `-f` (follow) — o Claude Code não segura streams indefinidamente. Se o
usuário pedir streaming explicitamente, sugerir ele rodar manualmente:
`./scripts/ssh.sh "cd /opt/cpt && docker compose logs -f <service>"`.
