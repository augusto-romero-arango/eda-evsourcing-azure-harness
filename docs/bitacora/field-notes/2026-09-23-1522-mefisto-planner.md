---
fecha: 2026-09-23
hora: 15:22
sesion: mefisto-planner
tema: Portar /parallel a OpenCode (tmux y herdr) con paridad de logs y control del lote
---

## Contexto
El usuario pidio planear el port de `/parallel` a OpenCode manteniendo las mismas garantias que en Claude (logs y control del lote) en tmux y herdr.

## Descubrimientos
- El modo pane de `/parallel` ya es neutral: `cmd_parallel` de tmux (#1593) y de herdr (`build_pane_runner_cmdline`) le pasan `MEFISTO_RUNTIME` a cada pane; lanzan `tdd-pipeline.sh`/`tooling-pipeline.sh`, que ya estan en el paquete publicado.
- `/batch-stop` y `/work-status` ya estan migrados; `batch-stop.md` ya menciona `{{mefisto:command parallel}}`.
- Lo que falta: `parallel-pipeline.sh` (el scheduler con cola, `--max-parallel`, log del lote, batch-stop y serializacion de projection) exige `claude` y no esta en `TOOLING_CLOSURE_ASSETS`; `/parallel` no tiene fuente neutral.

## Decisiones
- Seguir el mismo corte que `/sequential` (#1591 -> #1592): primero neutralizar el runtime del pipeline, despues migrar el comando junto con el asset del paquete.
- Primero se crearon en `estado:borrador` a pedido del usuario; en la misma sesion se refinaron a `estado:listo` (#1621 conserva `bloqueado` por #1620).
- #1620 se corrigio contra el molde real de `batch-pipeline.sh`: `_pc_script_dir` para cargar la libreria, `runtime_cli_available` para el chequeo del CLI, y el scaffold del test ya copia `src/runtime`.

## Descartado
- Certificacion e2e real en OpenCode (lote en herdr y en tmux hasta PRs): el usuario aprobo el corte en dos sin ella.
- Empaquetar `iac-pipeline.sh`: `tipo:infra` se salta con `SKIP:infra`.

## Preguntas abiertas
- Ninguna. La detección de batch-stop por `pgrep` se verifico: el launcher OpenCode resuelve `MEFISTO_PACKAGE_ROOT` con `pwd -P`.

## Referencias
Issues creados: #1620, #1621
