---
fecha: 2026-09-09
hora: 07:22
sesion: mefisto-planner
tema: Reconciliacion interna de labels bloqueado post-merge
---

## Contexto

Tras auditar labels obsoletos en #1131, #1135 y #1139, se pidio llevar al tooling interno el comportamiento que `scripts/pr-sync.sh` ya ofrece al consumidor: despues de mergear un PR, retirar `bloqueado` de los dependientes cuya ultima dependencia acaba de cerrar.

## Descubrimientos

- El consumidor implementa `desbloquear_issues_dependientes` dentro de `scripts/pr-sync.sh`: extrae `Closes #N`, escanea issues abiertos con `bloqueado`, analiza marcadores forward canonicos y solo retira el label cuando todas las dependencias estan `CLOSED`/`MERGED`.
- Mefisto no puede invocar ese script: `/mefisto-merge` y `mefisto-batch-pipeline.sh` usan `gh pr merge` directo por MEF-ADR-0019 y no disponen del contrato/configuracion del consumidor.
- Los dos puntos internos de merge son independientes: uno es un comando neutral guiado por agente; el otro, el motor Bash secuencial.
- `src/internal/scripts/mefisto-validate-batch-deps.sh` ya es la autoridad interna que delimita `## Dependencias`, parsea `Depende de`/`Bloqueado por`, consulta issues/PRs y muta `bloqueado` cuando corresponde.
- Crear un reconciliador nuevo exigiria primero registrar otra ruta de artefacto en un PR separado. Un modo nuevo del validador existente evita ese overhead y una tercera copia del parser.
- La fuente neutral de `/mefisto-merge` puede invocar el modo mediante `{{mefisto:run ...}}`; los adaptadores generados conservan la seleccion Claude/OpenCode.

## Decisiones

- Se divide la mejora en tres issues pequenos, sin epic:
  - #1159 agrega `--reconcile-pr <pr>` al validador interno existente.
  - #1160 integra el reconciliador despues de cada merge exitoso de `/mefisto-merge`.
  - #1161 lo integra despues de cada merge exitoso de `mefisto-batch-pipeline.sh`.
- #1160 y #1161 dependen de #1159 y llevan `bloqueado`; ambos aportan valor independiente.
- El modo exige que el PR disparador este `MERGED` y usa exclusivamente cierres `Closes #N`, en paridad con el comportamiento publicado actual.
- Solo las dependencias forward canonicas cuentan. Referencias inversas/prosa no desbloquean; una dependencia abierta o desconocida conserva el label.
- Los callers tratan la reconciliacion como post-merge best-effort: un fallo produce warning, pero nunca transforma en fallo un merge ya completado ni detiene automaticamente el resto.
- La reconciliacion ocurre despues de cada merge, no como barrido al final, para reflejar cada cierre cuanto antes.

## Descartado

- Invocar `scripts/pr-sync.sh` desde Mefisto: viola la separacion publicado/interno y arrastra configuracion del consumidor.
- Copiar la funcion completa dentro del batch y del comando: produciria tres parsers divergentes.
- Crear de inmediato `mefisto-reconcile-blocked.sh`: requiere el PR previo de registro de scope y no es necesario mientras el validador existente ya posee la responsabilidad mecanica.
- Resolver ambos callers en un solo issue: mezcla skill y pipeline, supera el corte de un componente principal y dificulta verificar fallos best-effort por separado.
- Quitar labels solo al comenzar el siguiente batch: mantiene el backlog incorrecto entre el merge y la siguiente ejecucion.

## Preguntas abiertas

- Si el modo `--reconcile-pr` adquiere mas consumidores en el futuro, se puede reevaluar extraer una utilidad dedicada bajo la regla de tres y el registro previo de MEF-ADR-0019.
- La implementacion debera decidir el formato exacto del resumen stdout sin cambiar los exit codes del modo posicional de validacion.

## Referencias

Issues creados: #1159 `Añadir reconciliacion post-merge al validador interno de dependencias`; #1160 `Reconciliar bloqueos despues de cada merge manual interno`; #1161 `Reconciliar bloqueos despues de cada merge del batch interno`.

Fuentes: `scripts/pr-sync.sh`, `scripts/tests/test-pr-sync-desbloqueo.sh`, `src/internal/scripts/mefisto-validate-batch-deps.sh`, `.claude/scripts/tests/test-batch-deps-validation.sh`, `src/internal/scripts/mefisto-batch-pipeline.sh`, `src/internal/commands/mefisto-merge.md` y MEF-ADR-0018/0019/0049/0050.
