---
fecha: 2026-06-25
hora: 05:40
sesion: mefisto-planner
tema: Refinar issue #86 (automatizar backend.tf en el worktree del pipeline IaC)
---

## Contexto

El coordinador invoco `/mefisto-plan` en modo refinar para el draft #86, creado como follow-up del #85 (ya mergeado, cerro #83). El draft documentaba un *seam* que el #85 resolvio solo por documentacion: `scripts/bootstrap-backend.sh` escribe `infra/environments/<env>/backend.tf` en el working tree del consumidor, pero el pipeline IaC ramifica su worktree desde `origin/main`, asi que el archivo no llega al `terraform init` en greenfield salvo que ya este versionado en `origin/main`.

## Descubrimientos

- Causa raiz **verificada en el codigo del harness** antes de cerrar a `estado:listo`:
  - `scripts/iac-pipeline.sh:260` crea el worktree ramificando siempre desde `origin/main`.
  - `scripts/iac-pipeline.sh:271` resuelve `INFRA_ENV_DIR_ABS` dentro de ese worktree.
  - `agents/infra-reviewer.md:62-63` confirma que `terraform init`/`plan` corre dentro del worktree.
  - Consecuencia: el `backend.tf` del working tree no viaja al worktree en greenfield; el primer `terraform plan/apply` correria con estado local.
- El patron de "commit dentro de la rama del worktree" ya existe en `scripts/iac-pipeline.sh:407-409` (commit del reviewer). Sirve de molde para el commit del `backend.tf`.

## Decisiones

- **Opcion (a) sobre (b)** (recomendacion del planner, confirmada por el usuario via coordinador): que `iac-pipeline.sh` copie el `backend.tf` al worktree. Es determinista y verificable; la opcion (b) dependia del agente `haiku` y era dificil de verificar.
- **Alcance: copiar + commitear** (opcion 2): ademas de copiar, commitear el `backend.tf` en la rama del worktree. Subsume la opcion (b): cierra el seam del `terraform init` **y** versiona el `backend.tf` en `main` via el merge del PR del pipeline, sin push directo a `main` desde un agente (riesgo que el reviewer del #85 marco).
- **3 defaults de borde aprobados** por el usuario:
  1. Si el `backend.tf` ya existe en `origin/main` (no-greenfield), la copia lo sobrescribe identico => no-op en el diff.
  2. Si no hay `backend.tf` en el working tree, el pipeline emite `warn` y continua sin abortar.
  3. En `--from-stage > 1` (worktree existente) no se re-copia ni re-commitea; el comportamiento de retomar no cambia.
- **6 criterios de aceptacion**: el usuario eligio fusionar el CA de docs (README paso greenfield 4.1 + `agents/infra-bootstrap.md` paso 3) y el de `CHANGELOG.md` en un unico CA-6, para quedar en el umbral de 6 de la Revision de complejidad. Son homogeneos (todos giran sobre el mismo cambio).
- ADRs anclados: 0019 (publicado vs interno) y 0020 (backend del state como prerequisito del hosting por dominio).

## Descartado

- **Opcion (b) pura** (que el agente incluya el `backend.tf` en el PR): depende del agente `haiku`, dificil de verificar. Quedo subsumida por copiar+commitear.
- **Opcion 1 (solo copiar, sin commitear)**: resolveria el `terraform init` local pero el `backend.tf` no apareceria en el diff del PR; el consumidor tendria que commitearlo aparte.
- **Mantener 7 CA**: el usuario opto por fusionar docs+changelog a 6.

## Preguntas abiertas

- Ninguna de diseno. El punto de insercion exacto quedo documentado en `## Notas tecnicas` del issue (entre `iac-pipeline.sh:263` y `:271`, rama `else` del `FROM_STAGE -gt 1`; patron de commit en `:407-409`).

## Referencias

Issues refinados: #86 (de `estado:borrador` a `estado:listo`, `tipo:tooling`).
Issues creados: ninguno.
Issues cerrados: ninguno.
Origen: follow-up del #85 (PR mergeado, cerro #83).
