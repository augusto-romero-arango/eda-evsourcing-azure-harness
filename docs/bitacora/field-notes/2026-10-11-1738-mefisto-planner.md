---
fecha: 2026-10-11
hora: 17:38
sesion: mefisto-planner
tema: Progreso y log de la corrida en fausto-blood-pact, con la misma experiencia que la cinta interna
---

## Contexto
Continuación de la sesión (notas previas en los PR #2278, #2290, #2301 y #2317). El primer `/mefisto:sequential` en Bitakora se veía sin progreso en la banda. El usuario pidió la banda del implementador con progreso y log, igual que el tooling interno.

## Descubrimientos
- Los pipelines publicados corren con `--redact-observability` (#1128/#1156, MEF-ADR-0053). Por eso el `events.jsonl` del consumidor no trae `message` e `input_summary` llega en `null`. La información útil está en `pipeline-<ts>.log` y en `batch-<ts>.log`.
- `roleOfAgent` del pact compara nombres exactos, y `projection-test-writer` cae en desarrollador. Hay que mapear por sufijo.
- `refreshRuns` solo sondea cada 60 s cuando no ha visto corridas, así que tarda en detectar una corrida nueva.
- En el repo el script de IaC es `iac-pipeline.sh`, no `infra-pipeline.sh`.

## Decisiones
- #2320: la vista de corrida se detecta en ≤10 s por `tool.call` Bash sobre los scripts de pipeline. Lleva la cabecera `mefisto · sequential 0/1 · #N agente Xm` y los pasos de `status.agents` (✓●✗○). Las últimas líneas vienen del log del pipeline (sin ANSI) más el último evento del agente. La mascota se elige por rol, según el sufijo.
- #2321: un Pane de log igual al visor interno, con la misma cabecera y las acciones m/v/c. Junta dos `tail -F`: events.jsonl (con un `parseEvent` portado) y el log del pipeline o del batch. Separa con `══ #N ══` y `── agente · modelo ──`, mata los tails por PID al cerrar y se abre con `/fausto-blood-pact log`.
- No se toca MEF-ADR-0053: la redacción se queda y el log del pipeline cubre el hueco.

## Descartado
- Un tail crudo del log como visor: no iguala la experiencia interna.
- Quitar `--redact-observability` en el consumidor.

## Preguntas abiertas
- Lanzar `/mefisto-sequential 2320 2321`, publicar con `/mefisto-release` y correr `/mefisto:upgrade` en Bitakora.
- Briefs de mods internos pendientes: cierre a 15 s de las cintas y affordance de clic.
- PRs de field notes abiertos por mergear (#2317).

## Referencias
Issues: #2320 (estado:listo), #2321 (estado:listo, bloqueado por #2320).
