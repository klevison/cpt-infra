# Handoff para o repo `cpt/` — adicionar Dockerfile + workflows GHA

Documento auto-contido para alguém (humano ou Claude) trabalhando no repo
`~/Development/cpt_bet/cpt/`. **Não precisa clonar nem ler outros arquivos do `infra/`.**

## Contexto

A stack `cpt_bet` vai rodar em um único host AWS Lightsail London. O repo `cpt/`
(Phoenix LiveView + Elixir) precisa publicar uma imagem Docker em
`ghcr.io/klevison/cpt:latest` a cada push em `main`. Watchtower no host puxa a
imagem nova a cada 5min e re-cria o container Phoenix com graceful shutdown
(`stop_grace_period: 60s`, configurado pelo `infra/`).

## O que criar

### 1. `Dockerfile` na raiz do repo

Multi-stage Phoenix release. Runtime baseado em `debian:bookworm-slim` com `bash`
incluído (o healthcheck do Compose usa `/dev/tcp/localhost/4000`).

```dockerfile
# syntax=docker/dockerfile:1.7

# ============================================================================
# Estágio de build — compila release Elixir
# ============================================================================
FROM hexpm/elixir:1.19.5-erlang-28.4.1-debian-bookworm-20250203-slim AS build

ENV MIX_ENV=prod \
    LANG=C.UTF-8

WORKDIR /app

# pacotes nativos para deps de build (esbuild/tailwind/argon2 etc)
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
       build-essential git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

# Cache de deps — copia só mix.* primeiro
COPY mix.exs mix.lock ./
COPY config ./config
RUN mix deps.get --only prod && mix deps.compile

# Código + assets
COPY priv ./priv
COPY assets ./assets
COPY lib ./lib

RUN mix assets.deploy
RUN mix compile
RUN mix release

# ============================================================================
# Runtime — debian slim com bash (healthcheck usa /dev/tcp/)
# ============================================================================
FROM debian:bookworm-slim AS runtime

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
       libstdc++6 openssl libncurses6 locales ca-certificates bash \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    PHX_SERVER=true

WORKDIR /app

# Usuário não-root
RUN useradd --system --user-group --create-home --home-dir /app/home cpt \
    && chown -R cpt:cpt /app
USER cpt

COPY --from=build --chown=cpt:cpt /app/_build/prod/rel/cpt ./

EXPOSE 4000

CMD ["/app/bin/cpt", "start"]
```

> Confirmar nome do release em `mix.exs` — campo `:app` deve ser `:cpt`. Se for
> outro nome, ajustar `bin/cpt` em duas linhas acima.

### 2. `.github/workflows/build.yml`

Build + push para GHCR a cada `main`.

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
          images: ghcr.io/${{ github.repository_owner }}/cpt
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

### 3. `.github/workflows/ci.yml`

Roda `mix precommit` em PRs. Postgres é serviço para testes que dependem do banco.

```yaml
name: ci

on:
  pull_request:
    branches: [main]
  workflow_dispatch:

jobs:
  precommit:
    runs-on: ubuntu-latest

    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: cpt_test
        ports: ['5432:5432']
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    env:
      MIX_ENV: test
      DATABASE_URL: ecto://postgres:postgres@localhost:5432/cpt_test

    steps:
      - uses: actions/checkout@v4

      - uses: erlef/setup-beam@v1
        with:
          otp-version: '28'
          elixir-version: '1.19.5'

      - name: Cache deps
        uses: actions/cache@v4
        with:
          path: |
            deps
            _build
          key: mix-${{ runner.os }}-${{ hashFiles('mix.lock') }}
          restore-keys: mix-${{ runner.os }}-

      - run: mix deps.get
      - run: mix precommit
```

### 4. (Opcional, recomendado) Rota `GET /api/health`

O healthcheck do Compose é TCP probe, então não depende de rota HTTP.
Mas adicionar `/api/health` é útil para uptime monitor externo (UptimeRobot,
Better Uptime, etc).

Em `lib/cpt_web/router.ex`:

```elixir
scope "/api", CptWeb do
  pipe_through :api

  get "/health", HealthController, :show
  # ... outras rotas
end
```

E `lib/cpt_web/controllers/health_controller.ex`:

```elixir
defmodule CptWeb.HealthController do
  use CptWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok", service: "cpt"})
  end
end
```

## Variáveis de ambiente que prod espera

Já documentadas em `config/runtime.exs`. O `infra/` injeta via `/opt/cpt/.env` (puxado do SSM):

| Var | Origem | Notas |
|---|---|---|
| `DATABASE_URL` | `/cpt/prod/database_url` | `ecto://cpt:...@postgres:5432/cpt` |
| `SECRET_KEY_BASE` | `/cpt/prod/secret_key_base` | 64 chars |
| `INTERNAL_TOKEN` | `/cpt/prod/internal_token` | usado em `X-Internal-Token` (Publisher → Phoenix) |
| `PHX_HOST` | `/cpt/prod/phx_host` | `cpt.bet` |
| `REDIS_URL` | `/cpt/prod/redis_url` | `redis://redis:6379/0` |
| `PHX_SERVER` | `true` (Compose) | Phoenix listen ativo |
| `MIX_ENV` | `prod` (Compose) | |
| `PORT` | `4000` (Compose) | |

## Constraints de runtime

- **`terminate/2` no Phoenix faz `XGROUP DELCONSUMER`** — `bin/cpt start` em release Elixir já honra SIGTERM (BEAM converte em `:init.stop/0`). O `infra/` configura `stop_grace_period: 60s` no Compose. **Nada a fazer no Dockerfile.**
- **Cada GenServer consumer Redix mantém conexão dedicada** (XREADGROUP BLOCK 5s). Default `maxclients` Redis (10000) cobre. **Nada a mudar.**
- **Imagem deve ter `bash` instalado** (já incluído no Dockerfile acima) — healthcheck do Compose usa `/dev/tcp/localhost/4000` via bash.

## Validar localmente

```bash
docker build -t cpt:test .

# Smoke test — release sobe e responde a comandos
docker run --rm cpt:test bin/cpt eval "IO.puts(:ok)"
```

## Fluxo completo

```bash
cd ~/Development/cpt_bet/cpt/

# 1. criar/atualizar Dockerfile, .github/workflows/build.yml, ci.yml
# (e opcionalmente HealthController)

# 2. validar localmente
docker build -t cpt:test .

# 3. precommit
mix precommit

# 4. commit (PT-BR, sem co-author/IA)
git add Dockerfile .github
git commit -m "infra: dockerizar release e adicionar workflows GHA"
git push origin main

# 5. confirmar workflow rodando + imagem publicada
gh run watch
gh api /user/packages/container/cpt/versions --jq '.[0].metadata.container.tags'
```

Após `ghcr.io/klevison/cpt:latest` existir, voltar ao `infra/` e seguir o passo 7
do [`infra/docs/deploy.md`](../deploy.md) (`terraform.tfvars` + `terraform apply`).

## Convenções

- Documentação, comentários, commits em **PT-BR**.
- Identifiers em **inglês**.
- `mix precommit` antes de push (já configurado no repo).
- Commits **sem co-author**, **sem citação a IA/Claude**.
