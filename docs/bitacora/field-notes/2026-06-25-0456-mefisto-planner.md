---
fecha: 2026-06-25
hora: 04:56
sesion: mefisto-planner
tema: Refinar issue #83 (bootstrap greenfield de Terraform)
---

## Contexto

El coordinador invoco `/mefisto-plan` en modo refinar para el draft #83, originado desde un consumidor real (`MiControlPlane` con `mefisto@0.6.0`). El draft reportaba que el camino documentado para inicializar Terraform en greenfield se rompe: falta `bootstrap-backend.sh`, hay rutas relativas invalidas en `infra-bootstrap`, y no existe doc de primeros pasos.

## Descubrimientos

- Causa raiz de los 3 hallazgos del draft **verificada en el codigo del harness**:
  - `grep -rln "bootstrap-backend"` da un unico hit: el propio `agents/infra-bootstrap.md` (el script nunca existio).
  - `agents/infra-bootstrap.md:38,48,69` usa rutas relativas (`./infra/scripts/...`, `./scripts/...`) que no resuelven con `cwd = consumidor`. Quedo fuera del patron canonico `$PLUGIN_SCRIPTS` que ya usan todos los `commands/` y `agents/planner.md`/`agents/reviewer.md`.
  - `scripts/setup-github-ci.sh:51-56` solo asigna rol al SP; no crea backend.
- El patron de "campo opcional del config leido inline" ya existe en `scripts/_pipeline-common.sh:24-28` (`repoSlug`). Sirve de molde para el nuevo `azureLocation`.
- `infra/environments/<env>/` es donde `agents/infra-reviewer.md:60-63` ejecuta `terraform init`; el stage 1 de `iac-pipeline.sh:359` usa `-backend=false`. Ahi debe aterrizar el `backend.tf`.

## Decisiones

- **Issue monolitico** (decision del usuario via coordinador): el #83 cubre script nuevo + fix de rutas + campo `azureLocation` + cableado del backend + seccion README. Mi objecion inicial (Revision de complejidad: >1 componente, pregunta de diseno abierta) quedo resuelta al cerrarse las 3 decisiones de diseno; el usuario asume conscientemente el alcance amplio.
- **Decisiones de diseno cerradas** (eliminan la ambiguedad que bloqueaba `estado:listo`):
  1. `LOCATION` -> campo opcional `azureLocation` en `harness.config.json`, leido inline (patron `repoSlug`), con flag `--location` override. Opcional => no MAJOR.
  2. `key` del tfstate -> `<env>.tfstate` (un state por ambiente).
  3. Cableado del backend -> opcion (a): `bootstrap-backend.sh` escribe `backend.tf` (script autocontenido, genera el HCL).
- ADRs anclados: 0019 (publicado vs interno, guard defensivo), 0020 (backend del state como prerequisito del hosting por dominio), y nota de versionado (campo opcional => no MAJOR).
- 12 criterios de aceptacion verificables (CA-1..CA-12). Excede el limite blando de 6 de la Revision de complejidad, pero es un issue homogeneo: todos los CAs son facetas del mismo eje "habilitar el arranque greenfield de Terraform", y el usuario eligio explicitamente el formato monolitico.

## Descartado

- Propuesta inicial del planner de **partir en 3 issues** (fix de rutas / script+backend / doc README). El usuario decidio mantenerlo monolitico.

## Preguntas abiertas

- Ninguna de diseno. En implementacion queda por confirmar el origen del `subscription-id` (argumento posicional vs flag) — el CA-4 lo deja como "argumento o flag coherente con el guardrail del consumidor"; el implementador decide la forma exacta.

## Referencias

Issues refinados: #83 (de `estado:borrador` a `estado:listo`, `tipo:tooling` + `documentation`).
Issues creados: ninguno.
Issues cerrados: ninguno.
