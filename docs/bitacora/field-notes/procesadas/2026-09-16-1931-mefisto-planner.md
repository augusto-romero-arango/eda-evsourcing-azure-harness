---
fecha: 2026-09-16
hora: 19:31
sesion: mefisto-planner
tema: Refinar #1447 (prompts > ARG_MAX en el runner neutral) y partirlo en cuatro issues
---

## Contexto
El batch de tooling del 2026-09-16 dejo al reviewer de #1407 sin arrancar: el pipeline interno incrusto un diff de 3,2 MB en el prompt (3.237.916 bytes), ambos adaptadores lo pasan como un elemento del argv y el kernel rechazo el exec (`Argument list too long`, `ARG_MAX` = 1.048.576 en macOS). El draft #1447 mezclaba dos arreglos independientes (transporte del prompt y tamano del contexto del reviewer) y tocaba seis archivos de codigo mas cuatro suites.

## Descubrimientos
- El watchdog `mefisto-process.sh` conecta stdin a `/dev/null` en sus tres ramas; ese `</dev/null` es parte del aislamiento sin TTY de #943. Sustituirlo por un archivo regular conserva el aislamiento (un archivo regular nunca es TTY).
- OpenCode v1.18.29 (`run.ts:416-418`, `resolveRunInput`) lee stdin cuando no es TTY y, si ademas hay mensaje posicional, los CONCATENA con `\n`. El adaptador debe omitir el posicional para que el mensaje llegue integro.
- Claude Code local expone `--append-system-prompt-file` ademas de `--append-system-prompt`, y `-p` esta documentado "useful for pipes" con `--input-format text` por defecto.
- El lado publicado (`scripts/tooling-pipeline.sh:744`, `scripts/tdd-pipeline.sh:1209`) tiene el mismo `FULL_DIFF` inline y ya invoca `mefisto-run-agent.sh`: el transporte por stdin lo cubre, el diff inline no.
- El runner crea `RUN_TMP_DIR` DESPUES de `build_cmd`; para que un adaptador materialice el archivo de stdin hay que adelantarlo y exponerlo (`MEFISTO_RUNTIME_WORK_DIR`).

## Decisiones
- Partir en cuatro issues, todos `tipo:tooling` + `bug`:
  - #1447 (re-alcanzado): contrato `MEFISTO_RUNTIME_STDIN_FILE` + `MEFISTO_RUNTIME_WORK_DIR`, watchdog con `${MEFISTO_RUNTIME_STDIN_FILE:-/dev/null}` sin cambiar firma, runner valida y adelanta el temp dir, `runtime-fake.sh` gana el guion `dump-stdin`, regresion con fixture > ARG_MAX y control "no pasa en vacio" (E2BIG real).
  - #1448 (bloqueado por #1447): migrar `runtime-claude.sh` y `runtime-opencode.sh` a stdin sin posicional; stubs vuelcan stdin; paridad ante ARG_MAX.
  - #1449 (interno, independiente): reviewer de `mefisto-tooling-pipeline.sh` recibe SHA base/HEAD + `--stat=120` + `--name-status`; el diff se consulta bajo demanda; regresion "prompt < 64 KiB con diff >= 3 MB".
  - #1450 (publicado, independiente): espejo de #1449 para `tooling-pipeline.sh` y `tdd-pipeline.sh`.
- Preferir la variable global con default en el watchdog a un octavo posicional: cuatro tests consumen la firma actual.
- #1439 tambien edita los prompts del pipeline interno: no es dependencia (el batch secuencial sincroniza main entre eslabones).
- Retomar #1407 desde Stage 2 es paso operativo, no CA; quedo como comentario en #1407.

## Descartado
- Un solo issue para todo el draft: >30 min, dos causas independientes, sin unidad de revision.
- Truncar el prompt o subir `ARG_MAX`: cambia el contenido o el sistema en vez del canal.
- Declarar dependencia de #1449 hacia #1447: cualquiera de las dos mitades evita el incidente por si sola.

## Preguntas abiertas
- Confirmar con una corrida real corta que `claude -p` sin posicional toma stdin como prompt (la ayuda lo sugiere; #1448 lo exige antes del merge).
- Si el reviewer acotado pide demasiados `git diff -- <ruta>` por turno, medir turnos tras #1449 (plan de velocidad en pausa).

## Referencias
Issues creados: #1448, #1449, #1450
Issues refinados: #1447 (borrador -> listo, titulo nuevo)
Comentarios: #1407 (nota operativa)
