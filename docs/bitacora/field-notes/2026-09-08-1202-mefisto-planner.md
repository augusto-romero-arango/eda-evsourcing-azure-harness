---
fecha: 2026-09-08
hora: 12:02
sesion: mefisto-planner
tema: Refinamiento del generador de hooks Claude #1058
---

## Contexto

Se refino #1058, el siguiente borrador del rollout multi-runtime, para convertir
`hooks/hooks.json` en una salida Claude generada desde el contrato neutral de hooks.

## Descubrimientos

- #1057 cerro durante la sesion mediante PR #1098 y dejo en `main` el descriptor, schema,
  validador y matriz con exactamente seis bindings.
- El generador publicado de #1048 no sirve para `hooks/hooks.json`: procesa Markdown de
  agentes/comandos, exige un comentario HTML y reemplaza raices completas `dist/<runtime>`.
- El hook Claude vigente no declara `async` ni `timeout`; los seis handlers son sincronos y
  toleran fallos dentro de sus comandos.
- El contrato nuevo exige estado canonico, pero muchos comandos y `/upgrade` aun consumen
  `.claude/pipeline/.plugin-root`; retirar ese marker haria que el fallback al cache pudiera elegir
  una version distinta de la cargada por la sesion.

## Decisiones

- Mantener #1058 como un generador Claude especifico, sin extender
  `generate-published-adapters.sh` ni escribir todavia en `dist/claude/`.
- Generar `sessions.jsonl` y `events.log` exclusivamente bajo `.mefisto/pipeline/`.
- Crear #1099 para autorizar y modelar antes un mirror legacy transitorio limitado a
  `.plugin-root`; ningun otro binding puede escribir en estado legacy.
- Representar `mode=sync` y `timeoutSeconds=null` mediante ausencia de `async`/`timeout`, y
  `failure=continue` mediante comandos que terminan sin tumbar la sesion.
- No insertar marker, `$schema` ni metadata de generacion en el JSON Claude; la autoridad se
  prueba mediante documentacion y `--check` byte a byte.
- Marcar #1058 como `estado:listo`, conservando `bloqueado` mientras #1099 siga abierto.

## Descartado

- Generar una salida completamente legacy: contradice el contrato ya mergeado de #1057.
- Eliminar `.plugin-root` legacy sin transicion: rompe la identidad exacta de la version cargada.
- Ampliar #1058 para enmendar tambien el contrato/ADR: mezcla dos cortes y excede el alcance de un
  unico componente principal.
- Hacer que dos generadores posean `dist/claude/`: el generador de agentes/comandos reemplaza esa
  raiz como unidad y eliminaria outputs ajenos.

## Preguntas abiertas

- Retirar el mirror legacy solo despues de un inventario sin lectores de `.plugin-root` y
  `.plugin-root.previous`; #1099 exige que ese retiro tenga un issue explicito.
- La incorporacion final de hooks a una raiz completa `dist/claude/` queda fuera del corte actual
  mientras el marketplace siga apuntando a la raiz del repo.

## Referencias

Issues creados: #1099.

Issue refinado: #1058 — Generar los hooks publicados de Claude Code.

PR de dependencia cerrado durante la sesion: #1098 (cierra #1057).
