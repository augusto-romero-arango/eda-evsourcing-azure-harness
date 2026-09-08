---
fecha: 2026-09-07
hora: 17:13
sesion: mefisto-planner
tema: Refinamiento del fallback de agentes OpenCode
---

## Contexto

Se refino el draft #1034, originado por cuatro corridas del pipeline interno en las que OpenCode descarto `mefisto-writer` y `mefisto-reviewer` por estar declarados como `subagent`, pese a que el runtime los invoca como agentes primarios mediante `opencode run --agent`.

## Descubrimientos

- La causa raiz del draft coincide con el codigo actual: ambos agentes declaran `mode: subagent`, el generador propaga ese valor a `.opencode/agents/` y `runtime-opencode.sh` los selecciona como agentes de nivel superior.
- `mode: primary` corregiria la seleccion, pero abriria `question: allow` por la regla actual de `opencode_permission_json`; para stages headless, `mode: all` corrige la seleccion y conserva `question: deny`.
- El adaptador Claude ignora `mode`, por lo que no hace falta un cambio funcional en ese runtime.
- El test `test-tooling-runtime-neutral.sh` ya prueba que el argv contiene los ids correctos, pero no que esos ids sean elegibles como primarios. `test-internal-agents-generated.sh` es el punto mas pequeno para fijar la invariante de modo.
- El propio issue no puede implementarse de forma confiable con el camino OpenCode actual: el writer de Stage 1 se selecciona antes de que el cambio exista. La primera entrega debe usar el adaptador Claude o cierre manual.

## Decisiones

- Se acoto #1034 a corregir de forma homogenea las declaraciones de writer/reviewer a `mode: all`, regenerar sus adaptadores y ajustar la cobertura existente.
- Se mantuvo un unico lado afectado: tooling interno, sin espejo publicado.
- Se declararon como aplicables MEF-ADR-0019, MEF-ADR-0049 y MEF-ADR-0050.
- El issue quedo con cinco criterios verificables, sin dependencias y con estimacion informal menor a 30 minutos.
- Se cambio el label de `estado:borrador` a `estado:listo`; se conservaron `tipo:tooling` y `bug`.

## Descartado

- No se eligio `mode: primary`, porque habilitaria preguntas en agentes no interactivos con el mapping vigente.
- No se incluyo en #1034 la deteccion del aviso de fallback por `stderr`: implica tocar el adaptador de runtime y decidir que el trabajo producido por el agente equivocado sea irrecuperable, un segundo componente principal que merece refinamiento separado.

## Preguntas abiertas

- Crear y refinar un issue de defensa en profundidad para que `runtime-opencode.jq` convierta el fallback al agente por defecto en un fallo explicito y para que el pipeline nunca recupere trabajo producido bajo un agente distinto del solicitado.

## Referencias

Issues creados: ninguno.

Drafts refinados: #1034 - Corregir el fallback silencioso a agente por defecto de OpenCode en el pipeline interno.
