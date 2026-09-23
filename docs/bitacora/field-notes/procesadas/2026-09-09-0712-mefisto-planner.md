---
fecha: 2026-09-09
hora: 07:12
sesion: mefisto-planner
tema: Auditoria de labels bloqueado en el siguiente batch
---

## Contexto

El reporte de `/mefisto-next-order` declaró catorce issues lanzables y ningún bloqueo externo, mientras varios conservaban el label `bloqueado`. Se auditó cada body contra el estado real de todas sus dependencias declaradas para distinguir labels correctos, dependencias que el propio orden resuelve y labels obsoletos tras merges recientes.

## Descubrimientos

- `mefisto-next-order.sh` no usa `bloqueado` como filtro ni muta labels. Calcula el orden exclusivamente desde dependencias forward canónicas en `## Dependencias` y considera lanzable un dependiente si su dependencia abierta aparece antes en el mismo batch.
- Un issue puede estar realmente bloqueado para ejecución aislada y, al mismo tiempo, ser lanzable dentro del batch calculado. “Sin bloqueos externos” no significa “todas las dependencias ya están cerradas”.
- Los labels de #1131, #1135 y #1139 eran obsoletos: todas sus dependencias forward están cerradas.
- Los labels de #1134, #1059, #1132, #1136, #1056, #1145, #1064 y #1065 son correctos mientras sus predecesores sigan abiertos; el orden propuesto los resuelve dentro del batch.
- #1129, #1144 y #1147 ya estaban correctamente sin `bloqueado` y no tienen dependencias abiertas.
- `scripts/pr-sync.sh` sí reconcilia dependientes después de un merge, pero es tooling publicado y no se usa en Mefisto. `mefisto-batch-pipeline.sh` y `/mefisto-merge` ejecutan `gh pr merge` directo por contrato.
- El validador interno `mefisto-validate-batch-deps.sh` retira `bloqueado` al iniciar un batch viable cuando sus dependencias abiertas quedan satisfechas por el orden. No existe hoy una reconciliación equivalente inmediatamente después de cada merge interno.
- Los merges de #1055 (PR #1149) y #1126 (PR #1154) dejaron visibles los tres residuos auditados; ambos PRs tienen `Closes #N`, por lo que el problema no fue falta de cierre del issue.

## Decisiones

- Se retiró `bloqueado` de #1131: #1126 y #1104 están cerrados.
- Se retiró `bloqueado` de #1135: #1126 está cerrado.
- Se retiró `bloqueado` de #1139: #1055 está cerrado.
- Se conservaron los ocho labels con dependencias todavía abiertas. No se importó la semántica “resuelto por orden futuro” al estado estático del backlog antes de lanzar el batch.
- Se volvió a ejecutar `/mefisto-next-order`; el orden no cambió y continúa sin ciclos ni bloqueos externos.

## Descartado

- Quitar todos los labels de los catorce issues solo porque el batch tiene un orden viable: ocultaría bloqueos reales para una ejecución aislada antes de validar/lanzar el batch.
- Atribuir el residuo a `pr-sync`: ese script está excluido explícitamente del flujo interno de Mefisto.
- Recalcular el grafo manualmente para sustituir al script: `mefisto-next-order.sh` sigue siendo la fuente de verdad del orden.

## Preguntas abiertas

- Conviene planear una reconciliación post-merge para `mefisto-batch-pipeline.sh` y `/mefisto-merge`, manteniendo un único parser de dependencias y sin reutilizar `pr-sync.sh` del consumidor.
- Debe decidirse si esa mejora se parte por pipeline/comando o si se extiende un helper interno existente sin introducir un artefacto nuevo que requiera registro previo de scope.

## Referencias

Issues corregidos: #1131, #1135 y #1139.

Issues auditados con bloqueo vigente: #1134, #1059, #1132, #1136, #1056, #1145, #1064 y #1065.

Issues auditados sin bloqueo: #1129, #1144 y #1147.

Fuentes: `src/internal/scripts/mefisto-next-order.sh`, `src/internal/scripts/mefisto-validate-batch-deps.sh`, `src/internal/scripts/mefisto-batch-pipeline.sh`, `scripts/pr-sync.sh`, PR #1149 y PR #1154.
