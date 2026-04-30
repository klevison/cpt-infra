---
description: Saúde dos 8 Redis streams + 5 consumer groups Phoenix.
allowed-tools: Bash
---

## O que fazer

Para cada stream, rodar `XLEN` + `XINFO GROUPS`. Use uma única invocação remota
para reduzir overhead SSH:

```bash
./scripts/ssh.sh 'cd /opt/cpt && cat <<EOF | docker compose exec -T redis redis-cli
XLEN wh_soccer_events
XLEN wh_soccer_incidents
XLEN wh_soccer_event_states
XLEN wh_soccer_event_settled
XLEN wh_soccer_event_metadata
XLEN wh_soccer_lineups
XLEN wh_soccer_stats
XLEN wh_soccer_upcoming_matches
EOF'
```

E para consumer groups (apenas dos que Phoenix consome):

```bash
./scripts/ssh.sh 'cd /opt/cpt && for s in wh_soccer_events wh_soccer_incidents wh_soccer_event_states wh_soccer_event_settled wh_soccer_upcoming_matches; do
  echo "--- $s ---"
  docker compose exec -T redis redis-cli XINFO GROUPS $s 2>/dev/null || echo "(grupo não existe)"
done'
```

## Saída

Formatar como duas tabelas em PT-BR:

**Tabela 1 — Streams (XLEN):**
| Stream | Tamanho | MAXLEN ~ |
|---|---|---|
| wh_soccer_events | 12345 | 100000 |
| ... | | |

**Tabela 2 — Consumer groups Phoenix:**
| Stream | Group | Consumers | Pending | Lag |
|---|---|---|---|---|

Sinalizar 🚨 se:
- pending > 1000 em qualquer grupo (consumidor lento ou parado)
- consumers = 0 em horário esperado de operação
- XLEN de algum stream caiu para 0 (publisher pode estar fora)
