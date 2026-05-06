---
description: Abre SSH (ou roda comando) no host Lightsail cpt-prod.
argument-hint: "[comando opcional a executar via ssh]"
allowed-tools: Bash
---

Execute o wrapper `scripts/ssh.sh` na raiz do repo, passando os argumentos opcionais
adiante para o ssh remoto.

## Contexto

- Chave: wrapper procura em `$CPT_SSH_KEY` → `~/.ssh/cpt-lightsail.pem` → `~/.ssh/cpt-lightsail`.
- IP: lido de `terraform output -raw instance_public_ip`.
- Comandos passam como **string única** ao shell remoto — quote externo `'...'`, escapar `'` interno como `'"'"'`.

## O que fazer

Rodar:

```bash
./scripts/ssh.sh $ARGUMENTS
```

Se o usuário não passou argumentos, mencionar que abrirá um shell interativo —
o que pode falhar dentro do Claude Code se a sessão não suportar TTY. Nesse caso,
sugerir o usuário rodar `./scripts/ssh.sh` diretamente no terminal.

Se passou argumentos (ex: `"sudo docker compose ps"`), executar diretamente e retornar a saída.

## Gotchas (NÃO esquecer)

- **`sudo` é obrigatório** para qualquer `docker` ou `docker compose` no host (usuário `ubuntu` não está no grupo docker).
- **Compose só roda com `cd /opt/cpt`** primeiro. Nunca usar `-f /opt/cpt/docker-compose.prod.yml` — esse path não existe (o symlink é `/opt/cpt/docker-compose.yml`). E `.env` é `root:600`, lido relativo ao dir do compose.
- Container names: `cpt-{caddy,phoenix,postgres,publisher,redis}-1`.
- Para SQL ad-hoc, prefira `/cpt-psql` (encapsula `docker exec` direto, dispensa compose).
