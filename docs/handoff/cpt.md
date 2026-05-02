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

### 1. `Dockerfile` + `.dockerignore` + `lib/cpt/release.ex` + `rel/overlays/`

Use o gerador oficial Phoenix em vez de escrever Dockerfile manual:

```bash
cd ~/Development/cpt_bet/cpt/
mix phx.gen.release --docker --otp 28.5
```

Isso cria automaticamente:
- `Dockerfile` (multi-stage, debian-trixie-slim, user `nobody`, CMD `/app/bin/server`)
- `.dockerignore`
- `lib/cpt/release.ex` (helper Ecto migrations sem mix em prod)
- `rel/overlays/bin/{server, server.bat, migrate, migrate.bat}`

**Por que `--otp 28.5` em vez do `28.4.1` do `.tool-versions`?** Imagens
`hexpm/elixir:1.19.5-erlang-28.4.1-debian-trixie-*` não estão publicadas; só
`erlang-28.5`. Patch-level (28.4.1 vs 28.5) é funcionalmente equivalente.

**Se Docker Hub retornar 504 durante o gen:** retry. É bug intermitente do CDN
deles em queries com prefix-match longo (`name=...-trixie-`); resolve em
segundos a minutos.

### 2. Ajustes obrigatórios no Dockerfile gerado

**(a) Adicionar `bash` no runtime stage** — o healthcheck do compose
(`bash -c 'exec 3<>/dev/tcp/localhost/4000'`) precisa. Linha do `apt-get install`
em `FROM ${RUNNER_IMAGE} AS final`:

```dockerfile
RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates bash \
  && rm -rf /var/lib/apt/lists/*
```

**(b) Configurar repo privado Fluxon via BuildKit secret** — o `cpt/` usa
`{:fluxon, "~> 2.3.5", repo: :fluxon}`. Sem isso, `mix deps.get` falha. Padrão
oficial Fluxon (https://docs.fluxonui.com/fly.html#dockerfile): adicionar entre
`mix local.hex` e `mix deps.get`:

```dockerfile
RUN --mount=type=secret,id=FLUXON_LICENSE_KEY \
    mix hex.repo add fluxon https://repo.fluxonui.com \
      --fetch-public-key "SHA256:zF8zWamOWgokeJdiIYgRl91ZBmQYnyXlxIOp3ralbos" \
      --auth-key "$(cat /run/secrets/FLUXON_LICENSE_KEY)"
```

**NUNCA hardcode o auth-key no Dockerfile** — fica no histórico git e em layers.
BuildKit secret garante que o valor passa só em RAM durante o build.

### 3. Ajustes no `.dockerignore` gerado

Adicionar logo após `.dockerignore`:

```
# Variaveis sensiveis e arquivos do SO (defesa em profundidade)
.env
.env.*
.DS_Store
```

### 4. Ajustes no `.gitignore` do repo

Adicionar (caso ainda não cubra):

```
# Variaveis de ambiente
.env
.env.*
!.env.example

# macOS
.DS_Store
```

### 5. `.github/workflows/build.yml`

Build + push para GHCR a cada `main`. Passa `FLUXON_LICENSE_KEY` como BuildKit secret:

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
          # BuildKit secret p/ Fluxon (https://docs.fluxonui.com/fly.html#dockerfile)
          # Configurar em github.com/${owner}/cpt/settings/secrets/actions
          secrets: |
            FLUXON_LICENSE_KEY=${{ secrets.FLUXON_LICENSE_KEY }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

**Importante:** antes do primeiro build, adicionar `FLUXON_LICENSE_KEY` em
`github.com/klevison/cpt/settings/secrets/actions`. Sem isso, `mix deps.get` falha.

### 6. `.github/workflows/ci.yml`

Roda `mix precommit` em PRs. Postgres é serviço; `cpt_test` é criado pelo
próprio `mix ecto.create` (chamado pelo alias `mix test`). Fluxon precisa estar
configurado antes do `mix deps.get`:

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
        # cpt_test e criado pelo `mix ecto.create` (chamado por `mix test` alias).
        # Apenas user/senha sao necessarios aqui.
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
        ports:
          - 5432:5432
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
          restore-keys: |
            mix-${{ runner.os }}-

      - name: Configurar repo privado Fluxon
        env:
          FLUXON_LICENSE_KEY: ${{ secrets.FLUXON_LICENSE_KEY }}
        run: |
          mix local.hex --force
          mix local.rebar --force
          mix hex.repo add fluxon https://repo.fluxonui.com \
            --fetch-public-key "SHA256:zF8zWamOWgokeJdiIYgRl91ZBmQYnyXlxIOp3ralbos" \
            --auth-key "$FLUXON_LICENSE_KEY"

      - run: mix deps.get
      - run: mix precommit
```

### 7. (Opcional, recomendado) Rota `GET /api/health`

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
| `PHX_HOST` | `/cpt/prod/phx_host` | domínio ou IP estático (sem domínio: IP do Lightsail) |
| `PHX_SCHEME` | `/cpt/prod/phx_scheme` | `http` em IP-only, `https` quando `enable_route53=true` |
| `PHX_PORT_URL` | `/cpt/prod/phx_port_url` | `80` em IP-only, `443` quando `enable_route53=true` |
| `REDIS_URL` | `/cpt/prod/redis_url` | `redis://redis:6379/0` |
| `PHX_SERVER` | `true` (Compose) | Phoenix listen ativo |
| `MIX_ENV` | `prod` (Compose) | |
| `PORT` | `4000` (Compose) | |

> `runtime.exs` lê `PHX_SCHEME`/`PHX_PORT_URL` em `Endpoint.url` para que Phoenix
> gere links coerentes com a porta exposta externamente (no MVP IP-only:
> `http`/`80`; com domínio + Caddy: `https`/`443`). Defaults `https`/`443`
> preservam comportamento de prod quando as envs não são setadas.

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
