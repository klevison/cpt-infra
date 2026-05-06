---
description: Mostra logs (tail) de um service do compose no host.
argument-hint: "<service> [n_linhas=200]"
allowed-tools: Bash
---

Use `scripts/ssh.sh` para rodar `docker compose logs` no serviço pedido.

## Argumentos

- `$1` — nome do service (`caddy`, `phoenix`, `publisher`, `postgres`, `redis`).
- `$2` — quantidade de linhas (opcional, default 200).

## O que fazer

Se o usuário não passou service, listar os disponíveis e perguntar qual.

Caso contrário:

```bash
SERVICE="$1"
LINES="${2:-200}"
./scripts/ssh.sh "cd /opt/cpt && sudo docker compose logs --tail=$LINES $SERVICE"
```

`sudo` é obrigatório — usuário `ubuntu` não está no grupo `docker` e `.env` é `root:600`.

Não usar `-f` (follow) — o Claude Code não segura streams indefinidamente. Se o
usuário pedir streaming explicitamente, sugerir ele rodar manualmente:
`./scripts/ssh.sh "cd /opt/cpt && sudo docker compose logs -f <service>"`.
