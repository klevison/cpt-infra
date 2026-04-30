---
description: Roda terraform fmt -check + validate + plan, sem aplicar.
allowed-tools: Bash
---

## O que fazer

Wrapper seguro de `terraform plan`. Sequência:

```bash
cd terraform/

# 1. format check (informativo — não falha o fluxo)
terraform fmt -check -recursive || {
  echo "⚠️  arquivos com formatação fora do padrão. Rode: terraform fmt -recursive"
  exit 1
}

# 2. init (idempotente)
terraform init -input=false -no-color

# 3. validate
terraform validate

# 4. plan
terraform plan -out=tfplan -lock-timeout=60s -input=false
```

## Saída

- Sumário do plan (recursos a adicionar/alterar/destruir).
- Se houver `destroy` no plan: 🚨 alertar explicitamente o usuário antes de
  qualquer aplicação.

## Notas

- **Nunca** chamar `terraform apply` neste comando — apenas plan. Apply é
  decisão humana explícita (ler `CLAUDE.md` seção "Ações que exigem confirmação").
- Se o usuário pedir apply após revisar o plan, lembrar de usar o `tfplan`
  gerado: `terraform apply tfplan`.
