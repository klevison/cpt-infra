---
description: Abre SSH (ou roda comando) no host Lightsail cpt-prod.
argument-hint: "[comando opcional a executar via ssh]"
allowed-tools: Bash
---

Execute o wrapper `scripts/ssh.sh` na raiz do repo, passando os argumentos opcionais
adiante para o ssh remoto.

## Contexto

- Chave: `~/.ssh/cpt-lightsail.pem` (ou `$CPT_SSH_KEY`).
- IP: lido de `terraform output -raw instance_public_ip`.

## O que fazer

Rodar:

```bash
./scripts/ssh.sh $ARGUMENTS
```

Se o usuário não passou argumentos, mencionar que abrirá um shell interativo —
o que pode falhar dentro do Claude Code se a sessão não suportar TTY. Nesse caso,
sugerir o usuário rodar `./scripts/ssh.sh` diretamente no terminal.

Se passou argumentos (ex: `"docker compose ps"`), executar diretamente e retornar a saída.
