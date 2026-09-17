---
fecha: 2026-09-16
hora: 15:07
sesion: mefisto-planner
tema: Refinamiento del runner paralelo de la suite de Mefisto
---

## Contexto
Se refino #1416, draft que combinaba descubrimiento de unas 125 pruebas, ejecucion concurrente, senales, resumen, adopcion doctrinal y benchmark.

## Descubrimientos
El runner es repo-only y debe vivir en `src/internal/scripts/`, no en `scripts/tests/` del paquete publicado. La suite tiene tres superficies: shims publicados, tests internos y una fuente canonica adicional sin shim. Los gates ya admiten el tipo de artefacto y R4 exige un shim byte-exacto en `.claude/scripts/`.

## Decisiones
Se creo #1438 para el inventario autoritativo, #1440 para la ejecucion supervisada y #1439 para adopcion/documentacion. #1416 quedo reducido al entrypoint, run dir y resumen. El grafo es #1438 -> #1440 -> #1416 -> #1439, con #1416 leyendo tambien #1438.

## Descartado
Se descarto publicar `scripts/tests/run-all.sh`, paralelizar los 125 scripts individualmente, hacer obligatoria la suite en cada stage y usar tiempos como gate estricto.

## Preguntas abiertas
Ninguna para Definition of Ready. El siguiente draft independiente del backlog es #801.

## Referencias
Issues creados: #1438, #1439, #1440. Issue refinado: #1416.
