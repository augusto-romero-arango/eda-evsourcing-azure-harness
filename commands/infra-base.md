---
model: haiku
---

Genera la infraestructura base del consumidor (8 modulos Terraform + esqueleto del entorno con outputs + el workflow de CI `infra-cd.yml`) invocando al agente `infra-base-scaffolder`. Es el eslabon greenfield entre `bootstrap-backend.sh` (crea el `tfstate`) y el primer `/infra`, que solo escribe y revisa el HCL: el `apply` real lo ejecuta CI al mergear el PR (ADR-0021, ADR-0022). Comunicate en **espanol**.

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
  - .github/workflows/infra-cd.yml (si no existe aun): plan en cada PR sobre
    infra/**, apply al mergear a main, autenticado por OIDC (ADR-0022)

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
  2. Crea la GitHub variable ALERT_EMAIL y el GitHub secret
     TF_VAR_POSTGRESQL_ADMIN_PASSWORD (Settings > Secrets and variables > Actions;
     setup-github-ci.sh no los crea) -- infra-cd.yml los inyecta como
     TF_VAR_alert_email/TF_VAR_postgresql_admin_password, nunca via terraform.tfvars
     commiteado (ADR-0025). subscription_id ya no es una variable: se resuelve de
     ARM_SUBSCRIPTION_ID. Revisa tambien los defaults derivados en variables.tf
     (project, project_short, postgresql_location).
  3. Primer /infra: escribe y revisa el HCL, abre un PR. El apply real
     ocurre en CI al mergear a main (workflow Infra CD), nunca en local.
  4. /scaffold <dominio> agrega su service-plan/storage/function-app a este entorno.
```

## Reglas

- **No generes la infraestructura tu mismo.** Solo valida la pre-condicion, informa y lanza el agente.
- El agente nunca corre `terraform plan`/`apply`: solo `fmt`, `init -backend=false` y `validate`. El plan real corre en CI al abrir el PR y el apply real al mergearlo a `main` (workflow `infra-cd.yml`, ADR-0021, ADR-0022).
- El agente es idempotente: no sobrescribe archivos `.tf` ni el workflow `infra-cd.yml` existentes (ADR-0021).
