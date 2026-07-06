---
fecha: 2026-07-06
hora: 18:56
sesion: mefisto-planner
tema: Refinamiento de los 6 issues de la auditoria de onboarding greenfield (#208-#213) a estado:listo
---

## Contexto

Continuacion de la sesion de desglose (ver `2026-07-06-1817-mefisto-planner.md`). Con los 6 issues
ya creados como `estado:borrador`, esta ronda los refino a `estado:listo` siguiendo la Definition
of Ready de ADR-0011 (columna `tooling`), en el orden de oleadas: Fase 1 (#208), Fase 2 en
paralelo (#209, #210, #212), Fase 3 (#211), Fase 4 (#213). Todas las decisiones abiertas quedaron
resueltas al cierre.

## Descubrimientos

- **`ARM_SUBSCRIPTION_ID` ya estaba declarado pero inutil.** El `env` del `infra-cd.yml`
  (infra-base-scaffolder.md:1199) exporta `ARM_SUBSCRIPTION_ID`, pero el provider lee
  `var.subscription_id` (`:830`), asi que esa variable de entorno no hace nada hoy. El provider
  azurerm resuelve `subscription_id` nativamente desde `ARM_SUBSCRIPTION_ID` cuando se omite el
  argumento (docs de HashiCorp).
- **El `terraform validate` local ya tolera `var.subscription_id` sin valor** (regla #7 del
  scaffolder pasa hoy), lo que evidencia que omitir el argumento no rompe la revision estatica.
- **El password de Postgres no es derivable del state.** `marten-connection` se construye con
  outputs (`postgresql_fqdn`, `database_name`, `administrator_login`) MAS el password, que es
  INPUT del admin (`TF_VAR`), no output. Esto acota que puede mecanizarse la siembra de secretos
  (solo `app-insights-connection` y `serviceBus.internal`, que si son outputs sensibles del state).
- **Los `serviceBus.external[]` no viven en el state de este BC** (ASB del backbone compartido,
  provisionado por otro equipo, ADR-0024 decision #4): nunca son mecanizables desde este apply.
- **Hallazgo 9-vs-8 labels resuelto.** `setup-github-labels.sh:31` borra 8 labels default y `:44`
  recrea `bug` con `--force`. GitHub trae 9 default. La formulacion precisa es la de
  `onboard.md:218` ("8 + recrea bug"); README:240 y el comentario del script (`:3`, dice "9") son
  los imprecisos.
- **La seccion "Tokens del harness" del CLAUDE.md del consumidor es un artefacto separado** de
  `harness.config.json`: `load_harness_config` (_pipeline-common.sh:83-92) lee el config, pero los
  agentes/skills leen el CLAUDE.md porque no pueden sustituir variables. Por eso el diagnostico de
  `/onboard` debe grepear el CLAUDE.md, no solo el config.
- **Constraint agente->skill**: `infra-bootstrap` (agente con Bash) puede invocar directo los
  scripts bash (`setup-github-labels.sh`, `setup-github-ci.sh`), pero el eslabon de la base
  (`infra-base-scaffolder`/`/infra-base`, que es agente/skill) debe delegarse/instruirse, no
  invocarse por bash.

## Decisiones

- **#208 (D1) - `subscription_id` via `ARM_SUBSCRIPTION_ID`** (default claro, aplicado): se omite
  `var.subscription_id` y el provider se apoya en `ARM_SUBSCRIPTION_ID` (ya en el env). Fundamento:
  menos superficie (una variable requerida menos) + coherencia con el modelo OIDC (el provider ya
  resuelve `ARM_CLIENT_ID`/`ARM_TENANT_ID`/`ARM_USE_OIDC` del env). Fallback documentado:
  `TF_VAR_subscription_id` si azurerm v4 forzara la variable en `validate`.
- **#208 (D1) - password-source Opcion R** (confirmada por el usuario): `TF_VAR_postgresql_admin_password`
  desde un GitHub secret que crea el admin **manualmente**, sin tocar `setup-github-ci.sh`.
  Mantiene #208 acotado a D1a; el valor queda consistente con la semilla de KV `marten-connection`
  (accion de admin). Se descartaron Opcion S (script genera el password, print-once) y la de
  doctrina (`random_password`, ya descartada por el tfstate).
- **#212 (D5) - estructura de carpetas informativa/no-bloqueante** (default fundamentado, aceptado
  por el coordinador): reportar `src/`/`tests/`/`infra/environments/` sin marcarlas `FALTA`, porque
  un greenfield legitimo no las tiene antes del primer `/scaffold` (evita falso negativo).
- **#211 (D4) - Opcion A: documentar y enmarcar** (confirmada por el usuario): fijar el tercer
  perfil de acceso (siembra de secretos ongoing, distinto del dev cero-credenciales y del bootstrap
  de una sola vez) en ADR-0022/0025 + README. Sin mecanizar.
- **#213 (D6) - fix ABAC diferido**: la idempotencia parcial de la condicion ABAC en
  `setup-github-ci.sh` se documenta como caveat; el arreglo real del script se difiere hasta que
  aparezcan consumidores migrados desde pre-#195.
- Los 6 issues quedaron `estado:listo`; #213 conserva `bloqueado` (depende de #211 y #212 por
  solape de archivo en README/onboard.md).

## Descartado

- **#211 Opcion B (mecanizacion parcial en CI)**: descartada por ahora por decision del usuario.
  NO se abrio issue. Trade-off que la frena: el SP de CI necesitaria `Key Vault Secrets Officer`
  (escritura) -> mas superficie IAM, y desplazaria la siembra de admin a CI (tensiona ADR-0025:48).
  Si el peso manual se vuelve doloroso, se reevalua como issue separado.
- **#211 Opcion C (mecanizacion total via `random_password`)**: fuera de scope (materializa el
  secreto en el tfstate; ya descartada en #208).
- Partir #208 en D1a/D1b ahora: se mantiene unificado (Opcion R no toca el script -> #208 = D1a).

## Preguntas abiertas

Ninguna. Todas las decisiones abiertas de la ronda quedaron resueltas.

## Referencias

Issues refinados a `estado:listo` esta ronda:
- #208 (D1) - subscription_id via ARM_SUBSCRIPTION_ID + password Opcion R + .gitignore de tfvars
- #209 (D2) - orquestacion greenfield completa + prerequisitos de admin
- #210 (D3) - fila function-app de ADR-0021 a storage por identidad
- #211 (D4) - siembra de secretos como tercer perfil (Opcion A, documentar y enmarcar)
- #212 (D5) - /onboard verifica tokens de CLAUDE.md + estructura de carpetas (informativa)
- #213 (D6) - barrido de docs (estado:listo + bloqueado; 9-vs-8 resuelto a 8)

ADRs anclados: ADR-0011 (DoR), ADR-0021, ADR-0022, ADR-0024, ADR-0025, ADR-0007.
