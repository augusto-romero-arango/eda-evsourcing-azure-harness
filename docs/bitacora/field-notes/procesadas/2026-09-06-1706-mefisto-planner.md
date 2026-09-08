---
fecha: 2026-09-06
hora: 17:06
sesion: mefisto-planner
tema: Refinar #928 (workspace herdr en dos filas por runtime) y desglosarlo en #928/#930/#931
---

## Contexto
El draft #928 pedia un solo workspace herdr del repo de Mefisto con dos filas, una por runtime (Claude Code y OpenCode), cada una con planeacion + ejecucion + visor, abiertas con invocaciones independientes (dogfooding de MEF-ADR-0049). El propio body pedia desglose en tres partes y tocaba dos archivos de lados distintos (`src/internal/scripts/mefisto-herdr-pipeline.sh` interno y `scripts/herdr-workspace.sh` publicado), asi que no pasaba la revision de complejidad como un solo issue.

## Descubrimientos
- `herdr pane layout` (herdr 0.8.2) **si expone geometria**: `rect` por pane y el arbol `splits` con `direction`/`ratio`. Sirve para verificar layouts por API (antes se asumia que solo "a ojo").
- Un `pane split` (y tambien `pane move --split --target-pane`) es siempre **relativo a un pane** y anida bajo el: en el workspace real `w4`, el visor `pC` partido `down` solo dividio su columna (x=232, ancho 84 de 290). No hay forma de partir el contenedor raiz a posteriori.
- Consecuencia: para que cada fila sea un contenedor propio, el **primer split del workspace tiene que ser `down`**, y solo la primera invocacion puede hacerlo. De ahi el patron **pane ancla**: la primera invocacion reserva la fila 2 con un pane vacio (`fila libre`), la segunda lo parte `right` dos veces y lo cierra.
- Los nombres de agente de herdr admiten 32 chars (`[a-z][a-z0-9_-]{0,31}`); `ejecucion-` (10) + slug (20) ya estaba al tope. Con sufijo `-opencode` (9) el slug baja a 13: `ejecucion-eda-evsourcin-opencode`.
- `mefisto-runtime.sh` no lo sourcea `_mefisto-common.sh`; `mefisto-tooling-pipeline.sh` lo sourcea explicitamente (L40) y llama `mefisto_resolve_runtime` (L298). El herdr pipeline interno debe replicar ese patron.
- `herdr pane list --workspace` devuelve `label` por pane: base para detectar filas ya montadas sin depender de que el agente haya arrancado.

## Decisiones
- **Tres issues**, no dos: #928 (parte 1, conserva el numero), #930 (parte 2), #931 (parte 3, `bloqueado` por ambos). B (#930) tiene valor propio (el sidebar muestra el runtime) y es pequeno; fusionarlo con C rondaba 7 CAs.
- **Runtime del pool (#928)**: se resuelve con `mefisto_resolve_runtime`, nunca con `${MEFISTO_RUNTIME:-claude}` en la capa neutral (MEF-ADR-0049). Fail-fast en el despacho: el mismo error ya lo emite `mefisto-run-agent.sh` en el primer stage. El usuario confirma que en adelante siempre se pasara el runtime.
- **Formato del pool**: `<pane_id> <runtime>` con espacio (el id ya lleva `:`). Lineas legacy sin clave se descartan del registro **sin cerrar el pane** (conservador, costo unico).
- **Sufijo de nombres (#930)**: **siempre** en el repo de Mefisto (tambien `claude`), no solo fuera del default: tras #928 no hay default fijo y una sola regla simplifica la deteccion de filas en #931. El sufijo es el mismo valor de `--kind`, sin tabla de alias.
- **Layout (#931)**: split raiz `down` + ancla en la primera invocacion; segunda invocacion parte el ancla `right` x2 con `--env MEFISTO_RUNTIME=<kind2>` y cierra el ancla (su shell nacio sin el env). Sin `--ratio` (50/50, el humano redimensiona la fila con la que trabaja). Idempotencia por (workspace, kind) via labels `planner [<kind>]`. Sin ancla -> abortar, nunca anidar. Consumidor byte a byte. Los panes de fila llevan siempre `--env MEFISTO_RUNTIME=<kind>`, tambien con el default.
- `mef-abrir` del `.zshrc` no cambia: `MEFISTO_RUNTIME=claude mef-abrir` y `MEFISTO_RUNTIME=opencode mef-abrir`.

## Descartado
- Un solo issue umbrella (dos lados, tres componentes).
- Dos issues (A; B+C): B+C superaba el tope de CAs sobre el mismo archivo.
- Default literal `claude` en `mefisto-herdr-pipeline.sh` (contra MEF-ADR-0049 aunque el gate R1-R3 no lo atrape).
- Tabs de herdr (`herdr tab create`) como plan B para la fila 2: pierden el lado a lado que motiva el issue.
- Un workspace por runtime: rechazado ya en el draft (no compra aislamiento, duplica ventanas).
- Anidar la fila 2 bajo el planner de la fila 1 como degradacion aceptable: la fila quedaria apretada en el ancho del planner.
- El experimento en vivo de `pane split --direction down`: innecesario, `herdr pane layout` ya mostro la semantica de anidado.

## Preguntas abiertas
- Con un solo runtime el ancla ocupa media pantalla hasta redimensionar o cerrar. Si molesta en el uso diario, evaluar un `--ratio` pequeno para el ancla en un issue posterior.
- CA-6 de #931 (visor en la fila correcta) es verificacion manual con `herdr pane layout`; no hay stub de geometria en los tests. Si se repite la necesidad, valorar un stub de `pane layout`.
- #924 (visor en vivo) sigue en curso y es independiente; los seis panes no dependen de el.

## Referencias
Issues creados: #930, #931
Issues refinados a `estado:listo`: #928 (retitulado como parte 1, `bug`)
Orden de batch sugerido (por `## Dependencias`): #928, #930, #931
