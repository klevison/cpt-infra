# Handoff para o repo `wh-publisher/` — Dockerizar e remover TinyProxy

Documento auto-contido para alguém (humano ou Claude) trabalhando no repo
`~/Development/cpt_bet/wh-publisher/`. **Não precisa clonar nem ler outros arquivos do `infra/`.**

## Contexto

A stack `cpt_bet` vai rodar em um único host AWS Lightsail London (`eu-west-2`),
mesma região da WH. Isso elimina o **TinyProxy** intermediário — o publisher
conecta direto em `wss://scoreboards-push.williamhill.com/diffusion`.

O repo `wh-publisher/` precisa:
1. Publicar uma imagem Docker em `ghcr.io/klevison/wh-publisher:latest` a cada push em `main`.
2. Remover defaults `PROXY_*` do código (não são mais usados).
3. (Recomendado) Tratar SIGTERM para shutdown limpo.

## O que criar/modificar

### 1. `Dockerfile` na raiz

```dockerfile
# syntax=docker/dockerfile:1.7

FROM python:3.11-slim

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# -u: unbuffered stdout/stderr (logs imediatos no `docker compose logs`)
CMD ["python", "-u", "decode_ws_lightsail.py"]
```

> **Confirmar o nome do entrypoint.** No repo legado é `decode_ws_lightsail.py`.
> Se renomeado durante a reorganização, ajustar a última linha do CMD.

### 2. `.github/workflows/build.yml`

```yaml
name: build

on:
  push:
    branches: [main]
    tags: ['v*']
  workflow_dispatch:

permissions:
  contents: read
  packages: write

concurrency:
  group: build-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Login GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository_owner }}/wh-publisher
          tags: |
            type=raw,value=latest,enable={{is_default_branch}}
            type=sha,format=long
            type=ref,event=tag

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

### 3. Remover defaults `PROXY_*` do código

Procurar `PROXY_HOST`, `PROXY_PORT`, `PROXY_USER`, `PROXY_PASS` e remover qualquer
valor default que aponte para `35.176.126.130:12321` ou similar. As variáveis
inteiras podem ser deletadas — TinyProxy não existe mais.

```bash
# encontrar usos
grep -rn 'PROXY_' .
```

Se houver lógica `if proxy_host: ...`, simplificar para conexão direta.

### 4. (Recomendado) Handler SIGTERM

Hoje o publisher ignora SIGTERM e cai em SIGKILL após 10s — funcional, mas
adicionar um handler simples evita warnings no log e permite cleanup futuro:

No topo do entrypoint principal (`decode_ws_lightsail.py`), logo após os imports:

```python
import signal
import sys

def _shutdown(signum, frame):
    print('[SHUTDOWN] SIGTERM recebido, encerrando.', flush=True)
    sys.exit(0)

signal.signal(signal.SIGTERM, _shutdown)
```

## Variáveis de ambiente que prod espera

O `infra/` injeta via `/opt/cpt/.env` (puxado do SSM) e via `environment:` do Compose:

| Var | Valor em prod | Origem |
|---|---|---|
| `REDIS_HOST` | `redis` (intra-Compose) | Compose |
| `REDIS_PORT` | `6379` | Compose |
| `REDIS_DB` | `0` | Compose |
| `PHOENIX_API_URL` | `http://phoenix:4000` | Compose |
| `INTERNAL_TOKEN` | (do SSM) | Compose env_file |
| `FEATURED_PUBSUB_ENABLED` | `true` | Compose env_file ou default |

Vars que **não devem mais existir** no prod (remover defaults):
`PROXY_HOST`, `PROXY_PORT`, `PROXY_USER`, `PROXY_PASS`.

## Constraints de runtime

- **SINGLETON HARD.** Nunca rodar 2 réplicas — duplicaria entradas em todos os streams.
  O `infra/` configura `restart: unless-stopped` sem `--scale`. **Nada a fazer no código.**
- **Logs em stdout.** `python -u` no CMD garante unbuffered. **Nada a fazer.**
- **Conexão direta WH.** `wss://scoreboards-push.williamhill.com/diffusion` resolve
  para CloudFront `eu-west-2`; latência ~5ms desde o host Lightsail London.

## Streams Redis (CONTRATO IMUTÁVEL)

O publisher **NÃO PODE** alterar nomes/shapes:

| Stream | MAXLEN ~ | Notas |
|---|---|---|
| `wh_soccer_events` | 100000 | gols (legacy) |
| `wh_soccer_incidents` | 500000 | match-level events |
| `wh_soccer_event_states` | 500000 | scoreboard ticks |
| `wh_soccer_event_settled` | 20000 | resultados finais |
| `wh_soccer_event_metadata` | 10000 | competition/region |
| `wh_soccer_lineups` | 50000 | escalações |
| `wh_soccer_stats` | 500000 | snapshots de stats |
| `wh_soccer_upcoming_matches` | 10000 | próximos jogos |

Pub/sub channels: `wh_soccer_matches` (lista 20s), `wh_soccer_featured_changes` (delta featured).

## Validar localmente

```bash
docker build -t wh-publisher:test .

# smoke test — CMD inicializa e tenta conectar (deve logar erro DNS, não sair com erro de import)
docker run --rm -e REDIS_HOST=fakehost wh-publisher:test || echo "esperado falhar DNS"
```

## Fluxo completo

```bash
cd ~/Development/cpt_bet/wh-publisher/

# 1. criar Dockerfile
# 2. criar .github/workflows/build.yml
# 3. limpar PROXY_* do código
# 4. (opcional) adicionar handler SIGTERM

# 5. validar
docker build -t wh-publisher:test .

# 6. commit (PT-BR, sem co-author/IA)
git add Dockerfile .github
# git add <arquivos com PROXY_ removido>
git commit -m "infra: dockerizar publisher e remover dependência de TinyProxy"
git push origin main

# 7. confirmar imagem publicada
gh run watch
gh api /user/packages/container/wh-publisher/versions --jq '.[0].metadata.container.tags'
```

Após `ghcr.io/klevison/wh-publisher:latest` existir, voltar ao `infra/` e seguir
o passo 7 do [`infra/docs/deploy.md`](../deploy.md).

## Convenções

- Documentação, comentários, commits em **PT-BR**.
- Identifiers em **inglês**.
- Commits **sem co-author**, **sem citação a IA/Claude**.
