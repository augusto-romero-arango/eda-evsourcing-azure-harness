---
fecha: 2026-09-07
hora: 17:44
sesion: mefisto-planner
tema: Refinamiento del preflight de batches internos
---

## Contexto

Se reviso y refino el issue #1035, creado despues de que `/mefisto-sequential 1034` anunciara un batch exitosamente despachado en Herdr aunque el hijo aborto inmediatamente por estar fuera de `main` con cuatro field notes sin trackear.

## Descubrimientos

- La evidencia de los dos logs confirma un fallo pre-loop: el guard del motor aborto antes de crear worktree o historial, pero el launcher ya habia adquirido el pane y reportado exito.
- `ensure_repo_on_base_branch` ya contiene la politica correcta y segura; el cambio requerido es adelantar su evaluacion al limite sincrono, no relajarla.
- El wrapper tmux decide si delega a Herdr antes de parsear el modo. Para prevalidar `--batch` sin afectar otros modos debe identificar y validar esa invocacion antes de `should_delegate_to_herdr`.
- La interfaz Herdr valida argumentos al final del preparseo. `require_herdr_context` no toca panes, mientras que `acquire_report_pane` puede crear, cerrar o reutilizar; el preflight debe quedar entre ambos puntos.
- Dos tests extraen actualmente `ensure_repo_on_base_branch` desde `mefisto-batch-pipeline.sh`: `test-batch-start-branch-recovery.sh` y `test-batch-sync-branch-race.sh`. Ambos deben ajustarse si el helper se mueve a `_mefisto-common.sh`.
- El modo interno `--_pane-runner` debe quedar fuera del preflight del launcher; el hijo `mefisto-batch-pipeline.sh` conserva su propia defensa.

## Decisiones

- Se mantuvo #1035 como un solo issue: sus seis criterios son variaciones homogeneas del lanzamiento del batch interno y reutilizan una politica y fixtures ya existentes.
- Se fijo `_mefisto-common.sh` como ubicacion canonica del helper, consumido por tmux, Herdr y el motor.
- Se aclaro que estar ya en `main`/`master` conserva el no-op actual; la sincronizacion con `pull --ff-only` corresponde a la auto-recuperacion desde otra rama.
- Se agrego la exigencia de validar argumentos antes de que el preflight pueda cambiar de rama.
- Se concreto `changelog.d/1035.fixed.md` y se ampliaron el impacto y la cobertura a los tests que hoy extraen la funcion.
- Se mantuvieron `bug`, `tipo:tooling` y `estado:listo`.

## Descartado

- No se propuso stash, reset, switch forzado ni degradar el arbol sucio a warning.
- No se extendio el preflight a `--tooling`, `--attach`, ayuda ni al runner interno de panes.
- No se creo una politica paralela por launcher: los tres puntos de entrada deben invocar el mismo helper.

## Preguntas abiertas

Ninguna para el Definition of Ready del issue.

## Referencias

Issues creados: ninguno.

Issues refinados: #1035 - Prevalidar el arranque de batches antes de despacharlos.
