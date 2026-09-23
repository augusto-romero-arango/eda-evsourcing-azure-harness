---
fecha: 2026-09-08
hora: 18:37
sesion: mefisto-planner
tema: Identidad append-only de sesiones multi-runtime
---

## Contexto

Se continuo el refinamiento de #1129, abierto al detectar que `sessions.jsonl` no podia satisfacer la identidad runtime/modelo/version/commit exigida por MEF-ADR-0053 con el snapshot de seis campos creado por #1057. Durante la revision, #1058 termino de implementarse en el PR #1133 con el contrato anterior.

## Descubrimientos

- OpenCode 1.18.29 no incluye modelo en `session.created`, pero su hook `chat.params` recibe el `Model` efectivo con `providerID` e `id` antes de cada llamada al LLM.
- Claude puede entregar `model` en algunos `SessionStart`, pero existen rutas publicamente reportadas como `/clear` donde falta. Tampoco hay una señal directa y fiable para los cambios de `/model`; el transcript indicado por el payload conserva `assistant.message.model` despues de una respuesta.
- El modelo es una observacion que puede cambiar durante una sesion, no una propiedad inmutable disponible necesariamente al arrancar.
- Un registro append-only puede conservar compatibilidad si distingue `session.started` de `session.model-observed`; las lineas historicas sin discriminador siguen interpretandose como inicios legacy.

## Decisiones

- #1129 define siete bindings neutrales: conserva los seis existentes y agrega `session.model-observed` -> `append-session-model`.
- La linea de inicio incorpora `record_type`, `runtime`, `model`, `harness_version` y `harness_commit`; `model` puede ser `null` de forma veraz.
- Las observaciones de modelo se anexan solo cuando cambia el ultimo modelo no nulo de la misma sesion. No se actualizan, borran ni migran lineas previas.
- OpenCode normaliza el identificador como `<providerID>/<model.id>` sin persistir proveedor por separado.
- Como #1058 ya cerro, no se reabre ni se amplian retroactivamente sus CAs: #1136 implementara la observacion Claude despues de #1129/#1132.
- #1059 quedo refinado y listo para consumir `session.created` + `chat.params`; #1066 declara ahora la dependencia explicita de #1136.

## Descartado

- Exigir un modelo no nulo en el inicio: inventaria datos para OpenCode y para ciertos `SessionStart` Claude.
- Reescribir la ultima linea de una sesion: romperia el contrato append-only y borraria cambios de modelo observables.
- Leer settings, cache, auth store o configuracion del proveedor para inferir el modelo.
- Reabrir #1058 ya completado: mezclaria un follow-up nuevo con el alcance historico entregado por PR #1133.

## Preguntas abiertas

- #1136 debe fijar mediante fixtures la forma exacta del transcript Claude vigente y degradar a `null` si cambia o resulta ilegible; los reportes publicos del proveedor documentan la brecha, pero no sustituyen una API versionada.
- La certificacion #1066 debe comprobar cambios reales de modelo en ambos runtimes, no solo presencia del campo inicial.

## Referencias

Issues creados: #1136 `Registrar observaciones de modelo en sesiones Claude`.

Drafts refinados: #1129 `Completar la identidad multi-runtime de sessions.jsonl`; #1059 `Implementar la observabilidad interactiva de OpenCode`.

Issues ajustados: #1058 (estado historico y follow-up), #1066 (dependencia de #1136).

Fuentes: MEF-ADR-0025/0031/0049/0050/0053; tipos fijados de `@opencode-ai/plugin` y `@opencode-ai/sdk` 1.18.29; reportes publicos `anthropics/claude-code#87045` y `#75981`.
