---
fecha: 2026-09-08
hora: 06:47
sesion: mefisto-planner
tema: Segunda pasada de refinamiento de #1057
---

## Contexto

Se pidio refinar #1057, que define la futura fuente neutral de hooks publicados para los adaptadores Claude Code y OpenCode del rollout de MEF-ADR-0053.

## Descubrimientos

- La unica implementacion publicada vigente es `hooks/hooks.json`; no existen los scripts `hook-session-observability.sh` ni `hook-notification.sh` que nombraba el issue.
- El archivo contiene exactamente seis handlers: dos `SessionStart` y cuatro `PostToolUse`.
- No hay handlers actuales de session end, tool start, prompt, permiso, notificacion o compactacion. Declararlos como comportamiento vigente inventaba alcance sin evidencia.
- El JSON mezcla semantica del harness, eventos/matchers Claude y shell inline con `CLAUDE_PLUGIN_ROOT` y `.claude/pipeline`.
- #1042, #1043, #1050 y #1078 ya estan cerrados; #1057 no conserva dependencias abiertas.

## Decisiones

- El contrato neutral se acota a los seis comportamientos existentes y usa señales/acciones logicas, sin nombres de eventos o tools propios de runtime.
- El descriptor fija entrega sin bloqueo funcional: sincronica, `failure: continue` y sin deadline adicional impuesto por Mefisto; cada adaptador documenta el limite efectivo de su runtime.
- Los payloads se cierran por allowlist y conservan las salidas observables actuales (`sessions.jsonl`, recordatorio y lineas resumidas de `events.log`) sin guardar prompts, tool inputs o comandos completos.
- La matriz de adaptacion debe citar documentacion oficial vigente y clasificar cada mapping como equivalente, sintetizado o no soportado.
- Se retiro el label `bloqueado`; #1057 permanece `tipo:tooling` + `estado:listo` y bloquea #1058/#1059.

## Descartado

- Modelar como existentes eventos interactivos que el harness no produce hoy.
- Introducir scripts ejecutables o generar `hooks/hooks.json` dentro del issue de contrato.
- Aplicar MEF-ADR-0038, que gobierna telemetria OpenTelemetry de las aplicaciones consumidoras y no hooks del harness.

## Preguntas abiertas

- #1058 y #1059 todavia necesitan segunda pasada para alinearse con el contrato acotado y con las dependencias actuales del rollout.

## Referencias

Issues creados: ninguno

Issue refinado: #1057
