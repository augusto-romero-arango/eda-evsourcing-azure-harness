---
fecha: 2026-09-12
hora: 20:43
sesion: mefisto-planner
tema: refinamiento del aborto de Stage 1 en tooling publicado
---

## Contexto

Se solicito refinar #1283, reportado desde Bitakora.ControlAsistencia despues
de que dos corridas con `v0.37.13` abortaran antes de invocar al writer del
pipeline tooling publicado.

## Descubrimientos

- La causa raiz esta presente en `scripts/tooling-pipeline.sh`: la primera
  sentencia de `run_agent` deriva `log_base` desde `stage` y `agent` mientras
  declara esos mismos locales bajo `set -u`.
- La regresion entro en `b5453d4` / PR #1142 y alcanzo `v0.37.12` y
  `v0.37.13`.
- `scripts/tests/test-tooling-neutral-runner.sh` conserva comprobaciones
  mayoritariamente estaticas de la frontera neutral; ejecuta
  `log_agent_model_invocation`, pero no `run_agent`.
- El test tiene actualmente 29 llamadas `contains`/`absent`; el conteo de 26
  incluido en el reporte ya no era estable y no debe formar parte del CA.
- El status huérfano no es la misma causa: `abort()` escribe `failed`, pero el
  trap `EXIT` solo limpia temporales y no reconcilia errores no controlados.

## Decisiones

- #1283 queda reducido a separar la declaracion local y agregar una regresion
  que ejecute la funcion real con dobles, sin red ni CLIs de runtime.
- Se retiraron del alcance de #1283 el barrido textual global, la corrida real
  posterior al release y la politica general de cierre de status.
- La corrida real ya vive en #1181; se agrego #1283 como dependencia directa y
  se conserva su label `bloqueado`.
- Se creo #1286 para marcar `failed` ante abortos no controlados del pipeline
  tooling. Es independiente de #1283 y quedo `estado:listo`.
- #1283 conserva `bug`, `tipo:tooling` y `estado:listo`: tiene cinco CAs
  verificables, un componente principal y una estimacion menor a 30 minutos.

## Descartado

- Relajar `set -u`: ocultaria el defecto en vez de reparar el orden de
  evaluacion asumido por el codigo.
- Mantener como CA una ejecucion real sobre una release futura: duplicaria la
  responsabilidad de certificacion E2E de #1181.
- Agregar un grep aproximado para detectar cualquier auto-referencia dentro de
  `local`: analizar sintaxis Bash de forma textual genera falsos positivos y no
  sustituye la regresion ejecutable.
- Resolver en #1283 todos los status `running` obsoletos: es una segunda
  conducta con casos de salida exitosa, `abort()` explicito y fallo previo al
  status.

## Preguntas abiertas

- Que release posterior a #1283 y #1281 se usara para reanudar #1180/#1181.
- Si en el futuro se adopta un analizador estatico general para scripts Bash,
  que regla verificable cubrira declaraciones y asignaciones dependientes.

## Referencias

Issues creados: #1286.

Issues refinados: #1283.

Issues actualizados: #1181.

Fuentes: PR #1142, MEF-ADR-0019, MEF-ADR-0031, MEF-ADR-0050,
MEF-ADR-0053 y GNU Bash Reference Manual, seccion `local`.
