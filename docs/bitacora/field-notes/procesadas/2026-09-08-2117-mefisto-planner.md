---
fecha: 2026-09-08
hora: 21:17
sesion: mefisto-planner
tema: Pools Herdr publicados por runtime
---

## Contexto

Se refino #1065, segundo eslabon Herdr del corte tooling publicado, para impedir que las filas Claude y OpenCode que agregara #1064 reutilicen o cierren el pane de seguimiento de la otra. El draft mezclaba identidad del pool con stop, orden de batch, logs y una nocion de reconexion que el pipeline no implementa.

## Descubrimientos

- `scripts/herdr-pipeline.sh` guarda hoy solo `pane_id` en `.claude/pipeline/herdr-report-panes.txt`; selecciona por workspace y colapsa todos sus panes libres hasta dejar uno.
- #928/PR #944 ya resolvieron el mismo defecto en `src/internal/scripts/mefisto-herdr-pipeline.sh` con el formato `<pane_id> <runtime>` y seleccion/cierre acotados al runtime.
- El pipeline publicado tiene una diferencia relevante: `--collapse-panes`, invocado best-effort por `/merge`, debe continuar retornando `0` sin efectos cuando no hay contexto suficiente.
- El lado publicado dispone de `mefisto_resolve_runtime` desde #1045 y de `mefisto_state_path` desde #1050.
- Un pane creado por Herdr contiene un shell ya vivo. Resolver runtime para el ledger no garantiza que ese valor alcance a `--_pane-runner`; debe fijarse en la linea argv-safe de `herdr pane run`.
- MEF-ADR-0053 obliga a que todo escritor nuevo use `.mefisto/pipeline/`. El ledger legacy no tiene runtime y, por tanto, no se puede atribuir de forma segura a ninguna fila.

## Decisiones

- #1065 queda `estado:listo`/`bloqueado`, depende solo de #1064 abierto y bloquea #1066.
- Se porta la mecanica de #928, sin sourcear codigo ni estado interno: ledger unico canonico con lineas `<pane_id> <runtime>`.
- Cada despacho resuelve runtime una sola vez antes de mutar el pool y lo pasa a seleccion, registro y comando del pane; no se introduce default Claude/OpenCode.
- Seleccion y cierre de sobrantes se filtran por `(workspace,runtime)`; entradas muertas se podan globalmente y panes vivos de otros pools quedan intactos.
- El pool legacy `.claude/pipeline/herdr-report-panes.txt` se conserva byte a byte y no se usa: sus lineas carecen de identidad suficiente. La primera corrida crea el ledger canonico.
- `--parallel` registra todos sus panes con el runtime de la corrida y `--collapse-panes` colapsa solo ese pool.
- La resolucion fallida aborta un despacho sin efectos, pero en `--collapse-panes` conserva el no-op `0` de #799.
- Se corrigio #1063 para retirar la relacion obsoleta “Bloquea #1064”; #1064 ya no depende de observabilidad headless.

## Descartado

- Un archivo separado por runtime: el ledger tipado ya mantiene un inventario unico y replica el precedente interno probado.
- Reutilizar lineas legacy como Claude por defecto: seria una atribucion silenciosa contraria a neutralidad.
- Mantener el pool bajo `.claude/pipeline/`: viola la escritura canonica de MEF-ADR-0053.
- Incluir locks o prometer resolver carreras simultaneas del mismo pool: no forman parte del defecto ni del precedente que se porta.
- Cambiar stop, hold/retry, grafo de issues, logs/eventos o geometria del workspace: pertenecen a contratos e issues separados.

## Preguntas abiertas

- Una mejora posterior podria estudiar exclusion mutua para dos despachos literalmente simultaneos del mismo runtime; #1065 conserva la semantica actual de concurrencia basada en `pane_is_free`.
- #1063 migrara reportes y observabilidad tooling a estado canonico; #1065 solo migra el ledger que modifica.

## Referencias

Draft refinado: #1065 `Separar los pools de panes Herdr publicados por runtime`.

Issues corregidos: #1063 (dependencia obsoleta hacia #1064 retirada).

Fuentes: `scripts/herdr-pipeline.sh`, `scripts/tests/test-herdr-collapse-panes.sh`, `scripts/tests/test-herdr-parallel.sh`, `src/internal/scripts/mefisto-herdr-pipeline.sh`, `.claude/scripts/tests/test-mefisto-herdr-pipeline.sh`, #799, #928/PR #944 y MEF-ADR-0017/0019/0049/0050/0053.
