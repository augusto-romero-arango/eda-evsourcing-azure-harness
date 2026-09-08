---
fecha: 2026-09-07
hora: 21:22
sesion: mefisto-planner
tema: Refinamiento de la extracción del runner común (#1045)
---

## Contexto

Se pidió refinar #1045, que ya estaba marcado `estado:listo` como una sola extracción del runner, los resolutores y los adaptadores hacia `src/runtime/`.

## Descubrimientos

- El alcance original mezclaba el runner de 648 líneas, el watchdog alojado en `_mefisto-common.sh`, discovery de runtime, adaptadores/traductores, resolución de modelos y más de 5.400 líneas entre las fuentes y tests principales revisados.
- El runner no era todavía independiente del lado interno: obtenía `run_agent_with_watchdog` desde la librería común interna y derivaba el default de `--events-log` con `mefisto_state_path`.
- `mefisto_resolve_runtime` enumeraba `claude|opencode` y sus binarios; un runtime nuevo exigía editar el resolutor, contrario al punto de extensión abierto de MEF-ADR-0050.
- `mefisto_resolve_model` dependía del schema interno, de la función opcional interna `resolve_stage_model` y de una enumeración cerrada de runtimes. Las tablas de defaults estaban mezcladas con los adaptadores internos de generación y permisos.

## Decisiones

- Partir el alcance en dos issues, por decisión del mantenedor: #1045 conserva runner, watchdog, discovery y adaptadores/traductores; #1072 recibe exclusivamente resolución de modelos.
- El runner común no deriva estado `.mefisto`: `--events-log` queda opcional y sin default en el núcleo; el shim o caller interno preserva temporalmente el default vigente.
- Cada adaptador de ejecución expone `runtime_<id>_is_available`; el resolutor escanea `runtime-<id>.sh` y deja de enumerar runtimes.
- El resolutor común de modelos recibe explícitamente modelo y ruta del mapping. Los defaults pasan por `runtime_<id>_default_model`, mientras `adapter-<id>.sh` conserva generación de frontmatter y permisos internos.
- #1046 depende ahora de #1045 y #1072; #1062 declara también la dependencia de #1072.

## Descartado

- Partir el alcance original en cuatro issues separados para watchdog, adaptadores/discovery, runner y modelos. Era la recomendación inicial por complejidad, pero el mantenedor eligió dos cortes.
- Mover `mefisto_state_path` o cualquier política de estado/scope al núcleo común.
- Mantener la enumeración `claude|opencode` o asumir que el binario siempre coincide con el id del adaptador.
- Duplicar la resolución de perfiles entre los lados publicado e interno.

## Preguntas abiertas

- La implementación decidirá qué shims temporales necesita #1045 para mantener verde al consumidor interno hasta que #1046 lo reconecte directamente; #1046 debe retirar los que queden sin consumidores.

## Referencias

Issue refinado: #1045 — Extraer el runner y los adaptadores de ejecución al núcleo común de runtime.

Issue creado: #1072 — Extraer la resolución de modelos al núcleo común de runtime.

Issues ajustados por dependencias: #1046 y #1062.
