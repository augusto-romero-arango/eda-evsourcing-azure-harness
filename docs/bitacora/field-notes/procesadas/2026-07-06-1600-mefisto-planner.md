---
fecha: 2026-07-06
hora: 16:00
sesion: mefisto-planner
tema: Mover el terraform apply de infraestructura de local a CI (GitHub Actions bajo OIDC/WIF)
---

## Contexto

El `terraform apply` de los pipelines IaC (`/infra`, `/infra-base`, agentes `infra-applier`, `infra-bootstrap`, `infra-base-scaffolder`) hoy corre 100% local con las credenciales Azure del desarrollador que usa Mefisto. Eso obliga a ese humano a tener permisos elevados sobre Azure y acceso a secretos. Objetivo de negocio: que el apply lo ejecute el service principal de GitHub via OIDC / Workload Identity Federation (ADR-0022) dentro de GitHub Actions; el humano solo planifica y revisa el HCL/plan.

## Descubrimientos

- **El apply es 100% local.** `scripts/iac-pipeline.sh` Stage 3 -> `agents/infra-applier.md` (`terraform apply tfplan`) con creds del dev. Las unicas cosas en GitHub Actions son deploy de codigo (`deploy-{kebab}.yml`) y smoke-tests; **no existe ningun workflow de Terraform en CI**.
- **ADR-0022 estaba "a un paso".** Al asignar `Contributor` al SP dice "alcance del deploy de Functions **e infraestructura**": anticipo el scope de roles para apply en CI, pero nunca materializo ni el workflow ni la doctrina.
- **El draft #195 presuponia un `infra-cd.yml` inexistente.** Describia un gap de permisos (`roleAssignments/write`) real, pero cuya premisa ("el scaffolder genera infra-cd.yml que corre apply como el SP") es falsa en el harness actual. Por tanto #195 no es paralelo: es dependiente de esta oleada. Se reencuadro (no se cerro).
- **Dos gaps tecnicos que #195 no cubria:**
  1. El SP tiene solo `Storage Blob Data Reader` sobre el tfstate. Un `apply` escribe el state y toma el lease/lock -> necesita `Storage Blob Data Contributor`.
  2. El `backend "azurerm"` de `bootstrap-backend.sh` no lleva `use_azuread_auth` -> accede al state por access key (`listKeys`), lo que choca con ADR-0025. Mover a CI es la ocasion para volverlo keyless AAD.

## Decisiones

- **Reforma de ADRs, no ADR nuevo.** El ancla (#196) reforma ADR-0021 + ADR-0022 y enmienda ADR-0025. Doctrina no-obsolete: lo removido se elimina del cuerpo y solo queda en el control de cambios.
- **Trigger CI: plan-en-PR / apply-en-merge-a-main.** Implica federated credential con subject `pull_request` ademas del de `main` (Issue C / #195).
- **Backend keyless AAD ahora** (`use_azuread_auth = true`, Issue B / #198) + tfstate del SP a `Storage Blob Data Contributor` (Issue C / #195).
- **Granularidad:** ancla-reforma + A..E, un issue cada uno. D (#199) y E (#200) marcados como candidatos a partir en refinamiento.
- Todos arrancan `estado:borrador`; el ancla requiere refinamiento antes de `listo` y el resto depende de el (label `bloqueado`).

## Descartado

- **ADR nuevo (0026):** el usuario opto por reforma de ADRs existentes.
- **Dejar el backend con access key/listKeys:** se descarto a favor de keyless AAD por coherencia con ADR-0025.
- **Cerrar #195 y crear uno nuevo:** se descarto; se edito #195 preservando el hilo y el origen cross-repo.

## Preguntas abiertas

- Scope del rol RBAC Administrator del SP: subscription-scope con condicion anti-escalacion vs. acotar al RG del BC (chicken-and-egg: el RG aun no existe en bootstrap). A decidir en refinamiento de #195.
- Criterio exacto de cierre del issue de infra en el nuevo modelo (al mergear el PR vs. al completar el run de apply en CI). A definir en #199 coordinado con #197.
- Coordinacion de orden entre `infra-cd.yml` (apply) y `deploy-{kebab}.yml` (deploy de codigo). A refinar en #197.
- Posible particion de #199 (pipeline vs. retiro de infra-applier) y #200 (README+skills vs. agentes+onboard/health-check).

## Referencias

Issues creados:
- #196 (ancla): Reformar ADR-0021 y ADR-0022 para fijar que el apply de infraestructura ocurre en CI bajo identidad federada.
- #197 (A): Generar el workflow infra-cd.yml de Terraform en CI (plan en PR, apply en merge, OIDC). Depende de #196.
- #198 (B): Configurar el backend de Terraform como keyless AAD en bootstrap-backend.sh. Depende de #196.
- #195 (C, reencuadrado): Elevar el principal de CI para aplicar infraestructura en CI (roleAssignments/write + tfstate Contributor + federated credential pull_request). Depende de #196; acoplado con #198.
- #199 (D): Rediseñar el pipeline IaC para eliminar el apply local y delegar el apply a CI. Depende de #196 y #197.
- #200 (E): Actualizar docs y onboarding al modelo de apply de infraestructura en CI. Depende de #196..#199 y #195.

Fuentes de best practice citadas (docs de proveedor):
- HashiCorp, "Automate Terraform with GitHub Actions" (plan en PR / apply en merge).
- Provider azurerm, guia OIDC (`use_oidc`/`ARM_USE_OIDC`, `id-token: write`).
- Backend azurerm, setting `use_azuread_auth` (keyless AAD).
- Microsoft Learn, built-in roles (Contributor excluye roleAssignments/write; RBAC Administrator least-privilege).

---

## Refinamiento de la oleada (misma sesion, 16:30-17:30)

Los 6 issues pasaron a `estado:listo` en orden de dependencias. Decisiones de doctrina resueltas durante el refinamiento (confirmadas por el usuario via coordinador):

### #196 (ancla, listo)
- **Scope RBAC**: subscription-scope + Role Based Access Control Administrator con condicion anti-escalacion (excluye asignar Owner/UAA/RBAC-Admin). Fundamento: chicken-and-egg (el RG del BC lo crea el propio apply, ADR-0021); acotar al RG rompe ADR-0021. Menor privilegio *viable*.
- **Cierre del issue de infra**: al completar el `apply` de CI exitosamente, NO al mergear (coherente con doctrina #96). El PR no lleva `Closes #N`.
- **Orden infra->deploy**: se fija el PRINCIPIO en el ADR; el mecanismo se remite a #197.

### #197 (listo, bloqueado)
- Emision por `infra-base-scaffolder` (idempotente, greenfield). Plan en `pull_request` sobre `infra/**`; apply en `push:main`. OIDC + backend AAD keyless.
- Cierre por CI tras apply (deriva nº de rama `infra-issue-<num>-*`).
- **Orden infra->deploy (confirmado por usuario)**: `workflow_run` + **filtro de paths por dominio** en `deploy-{kebab}.yml` (salta redeploy si el commit no toco `src/<dominio>/**`).

### #198 (listo, bloqueado)
- `use_azuread_auth = true` en el backend que escribe `bootstrap-backend.sh`. El rol tfstate Reader->Contributor va en #195 (acoplamiento anotado).

### #195 (listo, bloqueado)
- RBAC Administrator + condicion ABAC v2.0 (plantilla "Allow all except privileged administrator roles"); recomendado resolver role IDs por nombre, no hardcodear GUIDs.
- tfstate Reader -> Contributor. Federated credential `pull_request` ademas de `main`.

### #199 (listo, bloqueado)
- **Decision clave del usuario: `terraform plan` corre SOLO en CI; el dev tiene CERO permisos de Azure en el flujo ongoing.** El Stage 2 (`infra-reviewer`) pasa a revision ESTATICA (`fmt -check` + `init -backend=false` + `validate`); NADA de `plan` local. Stage 3 (apply) y `agents/infra-applier.md` se ELIMINAN por completo (no se degradan). Se retira la maquinaria `--auto-apply`/`--from-stage 3`/`--skip-apply`/preview-marker.
- **Distincion bootstrap vs ongoing**: "cero permisos" aplica al flujo ongoing del dev; el bootstrap inicial (`bootstrap-backend.sh` + `setup-github-ci.sh`) es operacion privilegiada de una sola vez de un admin.

### #200 (listo, bloqueado)
- Barrido de docs: README (Primeros pasos, §3, tabla "Que corre donde"), `/infra-base`, `infra-bootstrap`, `/onboard`, `/health-check`. Refleja cero-permisos ongoing + excepcion privilegiada del bootstrap.

## Enmienda PROPUESTA a #196 (NO aplicada; #196 esta listo y en implementacion en tmux)

La decision "plan solo en CI" crea tension con dos puntos del texto actual de #196; se pasa al coordinador para que el usuario decida:

1. **Flujo en la enmienda a ADR-0021**: cambiar "write -> review(**plan**) -> PR" por "write -> review(**validacion estatica**: fmt/validate) -> PR". El `plan` es CI-only; no hay plan local.
2. **Excepcion del bootstrap**: anadir a la doctrina de "cero permisos de Azure" (decision #1 / enmienda ADR-0022 y ADR-0025) una frase explicita: *"El 'cero permisos de Azure' aplica al flujo ongoing del desarrollador. El bootstrap inicial -bootstrap-backend.sh (tfstate) y setup-github-ci.sh (SP + federated credentials)- es una operacion privilegiada de una sola vez que un admin con permisos de Azure ejecuta para habilitar la CI; queda fuera de esa doctrina."*

## Convencion de `bloqueado` aplicada

CLAUDE.md: `bloqueado` cuando depende de otro **no cerrado**. #196 esta `listo` pero NO cerrado, asi que #197/#198/#195/#199/#200 conservan `bloqueado`. Accion de backlog futura: al cerrarse #196, quitar `bloqueado` de los que solo dependian de el.

## Decisiones pendientes de visto bueno del usuario

- **Enmienda a #196** (arriba): los dos puntos (flujo sin plan local + excepcion del bootstrap). El coordinador decide con el usuario si se aplica a #196 o se deja como esta.
- Ninguna otra: las sub-decisiones de #197 (workflow_run+filtro) y #199 (plan solo en CI) ya fueron confirmadas por el usuario.

## Nota de particion (candidatos marcados, NO partidos)

- #199: podria partirse en (D1) rework de `iac-pipeline.sh`+`/infra` y (D2) retiro de `infra-applier`+catalogo+cambio de rol del reviewer. **Recomendacion: mantener juntos** (interdependientes; partir da estado intermedio incoherente).
- #200: podria partirse en (E1) README+`/infra-base` y (E2) `infra-bootstrap`+`/onboard`+`/health-check`. **Recomendacion: mantener juntos** (barrido homogeneo).
