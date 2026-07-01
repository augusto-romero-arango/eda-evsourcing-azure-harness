---
model: haiku
---

Genera la infraestructura base del consumidor (8 modulos Terraform + esqueleto del entorno con outputs) invocando al agente `infra-base-scaffolder`. Es el eslabon greenfield entre `bootstrap-backend.sh` (crea el `tfstate`) y el primer `/infra` (aplica). Comunicate en **espanol**.

## Pre-condicion: cwd != Mefisto

Este skill es del plugin publicado y solo aplica al repo consumidor. Mefisto no tiene infraestructura Terraform/Azure. Verifica antes de continuar:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /infra-base no aplica al repo de Mefisto."
    exit 1
fi
```

## Entrada

`$ARGUMENTS` (opcional): el ambiente -- `dev` (default), `staging` o `prod`.

## Proceso

### 1. Resolver el ambiente

Si `$ARGUMENTS` esta vacio, usa `dev`. Si trae un valor, validalo (`dev`/`staging`/`prod`).

### 2. Informar que se va a generar

```
Se va a generar la infraestructura base del consumidor (ambiente: <env>):

  - infra/modules/{resource-group, monitoring, postgresql, service-bus,
                   service-plan, storage, function-app}/main.tf
  - infra/environments/<env>/{main, variables, providers, outputs}.tf
    (NO se genera backend.tf: lo escribe bootstrap-backend.sh)

El generador es idempotente: si ya existen archivos, los respeta y solo crea lo que falta.
```

### 3. Lanzar el agente

```bash
claude --agent infra-base-scaffolder "Genera la infraestructura base. Ambiente: <env>."
```

### 4. Tras terminar

Recuerda al usuario el orden del flujo greenfield:

```
Infraestructura base generada. Siguiente:
  1. Si el backend del tfstate aun no existe -> bootstrap-backend.sh
  2. Provee las variables requeridas en terraform.tfvars (alert_email,
     postgresql_admin_password, subscription_id) y revisa los defaults
     derivados (project, project_short, postgresql_location).
  3. Primer /infra para aplicar.
  4. /scaffold <dominio> agrega su service-plan/storage/function-app a este entorno.
```

## Reglas

- **No generes la infraestructura tu mismo.** Solo valida la pre-condicion, informa y lanza el agente.
- El agente nunca corre `terraform plan`/`apply`: solo `fmt`, `init -backend=false` y `validate`.
- El agente es idempotente: no sobrescribe archivos `.tf` existentes (ADR-0021).
