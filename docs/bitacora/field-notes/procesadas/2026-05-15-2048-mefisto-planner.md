---
fecha: 2026-05-15
hora: 20:48
sesion: mefisto-planner
tema: revision sistematica de coherencia de skills/agentes/scripts publicados con la separacion Mefisto vs consumidor
---

## Contexto

Tras consolidar la separacion fisica entre skills publicados (operan sobre el consumidor) y skills internos (operan sobre el propio plugin), recorrimos uno a uno los 14 skills publicados, 16 agentes publicados, 12 scripts publicados y el archivo de hooks para validar:

- Presencia del guard defensivo "cwd != Mefisto" donde aplique.
- Lenguaje coherente con "harness para el consumidor".
- Ausencia de detalles hardcoded del proyecto consumidor original (Bitakora) que rompan portabilidad.
- Referencias internas (ADRs, comandos, modos) que existan realmente.
- Convenciones del flujo de entrega (rama + PR, no main directo).

## Descubrimientos

- **Numeracion de ADRs descalibrada**: muchos agentes y un script publicado citan ADRs por numero, pero los numeros son los del consumidor Bitakora, no los del harness. Ejemplo: `0014-definition-of-ready` en planner/implement, cuando en Mefisto el DoR es `0011`; `0022-convencion-naming-tests` en test-writer/reviewer, cuando en Mefisto es `0016`; `0023-archivo-senal-refactor` en tdd-pipeline, cuando en Mefisto es `0017`. La causa raiz: los agentes se escribieron contra el consumidor, no contra el harness publicado.

- **`eda-modeler` con dominios Bitakora baked-in**: el agente enumera "Dominios del sistema" (Depuracion, CalculoHoras, Programacion, Empleados) y "Contratos compartidos" (Turno, DiaOperativo, Marcacion, DesgloseHoras, CalculadoraHoras) como hechos del sistema. Para un consumidor distinto, esto es ficcion: el agente le mentira sobre lo que existe.

- **Cinturon + tirantes incompleto**: cuatro pipelines principales (`tdd`, `iac`, `scaffold`, `tmux`) y cuatro scripts auxiliares (`appinsights-query`, `eda-lint`, `setup-github-ci`, `setup-github-labels`) carecen del guard "cwd != Mefisto" que el resto si tiene. Si se invocan directos en Mefisto, producen errores confusos o crean artefactos basura.

- **Anti-patron de `git push` directo a main**: `historiador.md` y `fix-review.md` hacen push directo a main sin rama + PR. Contradice CLAUDE.md ("Nunca trabajar contra main directo") y la memoria del usuario.

- **`tooling-investigator` con limitacion no documentada**: lee `.claude/commands/` y `.claude/agents/` como si ahi vivieran los skills del plugin, pero el plugin instalado los tiene en otra ruta. Su capacidad real de investigar bugs del plugin desde el consumidor se limita a crear drafts cross-repo.

- **`dom:tooling` no provisionado**: `tooling-investigator` lo sugiere como label en issues del consumidor, pero `setup-github-labels.sh` no lo crea automaticamente. Inconsistencia entre lo que el agente pide y lo que el harness provisiona.

- **Inconsistencias menores**: `/draft` referencia "planner modo 7" (no existe), `/health-check` sugiere `/loop` (no existe), `/show-flow` menciona "architecture/flows/" en vez de "docs/eda/flows/", `_pipeline-common.sh` hardcodea el slug del repo Mefisto en lugar de leerlo de `harness.config.json`.

## Decisiones

Convertimos los hallazgos en 8 issues bien dimensionados, todos como `estado:listo`:

- **#4** (bug): corregir numeracion de ADRs en agentes/skills/scripts publicados.
- **#5** (bug): limpiar dominios y contratos hardcoded de Bitakora en `eda-modeler`.
- **#6**: anadir guard a `tdd-pipeline`, `iac-pipeline`, `scaffold-pipeline`, `tmux-pipeline`.
- **#7**: anadir guard a scripts auxiliares (`appinsights-query`, `eda-lint`, `setup-github-*`).
- **#8** (bug): eliminar `git push` directo a main en `historiador` y `fix-review`.
- **#9**: hacer configurable el slug del repo de Mefisto en `_pipeline-common.sh`.
- **#10**: corregir referencias rotas en skills `draft`, `health-check`, `show-flow`.
- **#11**: aclarar alcance de `tooling-investigator` y decidir sobre `dom:tooling`.

Cada uno paso el checklist pre-listo: CAs <=6, un componente principal, sin ubicacion ambigua, estimacion informal <30 min, CAs verificables.

Ningun issue depende de otro — todos son independientes y se pueden trabajar en paralelo o en cualquier orden.

## Descartado

- **Crear un issue contenedor "limpieza general post-separacion"**: contradice la convencion del marco (no issues epic ni padres). La relacion entre los 8 issues se hace via narrativa de esta sesion, no via issue sintetico.

- **Fusionar guards de pipelines principales (#6) con guards de auxiliares (#7)**: aunque son la misma idea, los pipelines principales tienen alta prioridad (son la cara visible del harness) y los auxiliares son mas perifericos. Mantenerlos separados permite priorizarlos distinto y ejecutarlos en paralelo.

- **Agrupar las inconsistencias menores de skills (#10) con otros issues**: cada referencia rota es trivial pero el conjunto tiene cohesion (todos son fricciones textuales en skills publicados). Mantenerlos juntos evita 3 micro-issues sin valor independiente.

## Preguntas abiertas

- Para #1 (#4 en numeracion real), considerar a futuro si los ADRs del harness deben quedar **dentro del plugin distribuido** (no replicados en el consumidor) para evitar drift de numeracion. Hoy CLAUDE.md asume que los ADRs del harness viven en `docs/adr/` del consumidor — eso es lo que permite la descalibracion. Podria ser un issue futuro mayor (mover ADRs al directorio del plugin y referenciarlos relativamente).

- Para #11, decidir si tomar la **Opcion A** (eliminar `dom:tooling`, alineado con Mefisto interno) o la **Opcion B** (provisionar el label). En la sesion sugerimos A pero la decision final es del implementer del issue.

- Verificar despues del round de fixes si hay mas artefactos publicados que asumen estructura del consumidor Bitakora (por ejemplo el resto de tests/, ejemplos de codigo en agentes TDD). Esta primera pasada cubrio lo evidente; una segunda pasada con grep dirigido a "Bitakora", "ControlAsistencia", "ControlHoras", etc. podria descubrir mas.

## Referencias

Issues creados: #4, #5, #6, #7, #8, #9, #10, #11
