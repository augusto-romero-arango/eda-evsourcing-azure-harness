---
fecha: 2026-09-12
hora: 22:42
sesion: mefisto-planner
tema: Refinamiento del pipeline de cierre documental interno
---

## Contexto

La sesion comenzo para refinar el issue #1295, que proponia extraer a Bash el cierre documental de `mefisto-planner` despues de observar ramas creadas en el checkout principal y entregas sin PR.

## Descubrimientos

- La ubicacion propuesta `.claude/scripts/mefisto-field-note.sh` no podia contener la implementacion: `src/internal/scripts/README.md` y la regla R4 de `mefisto-neutrality-gate.sh` exigen una implementacion canonica en `src/internal/scripts/` y un shim de tres lineas en `.claude/scripts/`.
- El camino actual sin PR tiene un defecto reproducible: `gh pr list --jq '.[0] | [...] | @tsv'` devuelve tabuladores para una lista vacia, por lo que el guard de cadena no vacia omite por error `gh pr create`.
- El bloque `[J]` de `scripts/tests/test-guards.sh` valida snippets de prosa, no el comportamiento Git/GitHub del cierre.

## Decisiones

- #1295 queda acotado al pipeline base y a la primera entrega aislada, con un unico componente principal y cinco criterios verificables.
- La resiliencia e idempotencia se separaron en #1299, dependiente de #1295.
- La delegacion desde la fuente neutral de `mefisto-planner` se separo en #1298, dependiente de #1299; este corte conserva la regeneracion de ambos adaptadores como responsabilidad del issue del agente.
- #1296 ahora depende de #1299, porque el lado publicado debe reutilizar el patron solo despues de validar el ciclo completo interno.

## Descartado

- Mantener pipeline, agente, adaptadores, pruebas de comportamiento y todos los caminos de recuperacion en #1295: excedia la revision de complejidad simplificada.
- Crear la implementacion directamente bajo `.claude/scripts/`: violaria el layout canonico y el gate R4 de MEF-ADR-0049.
- Reforzar otra vez la secuencia shell dentro del prompt: no convierte la mecanica en una unidad ejecutable ni probada.

## Preguntas abiertas

- #1296 conserva un alcance publicado de pipeline + agente con seis CAs; conviene aplicarle un desglose equivalente antes de lanzarlo.

## Referencias

Issues refinados: #1295, #1296. Issues creados: #1298, #1299. ADRs: MEF-ADR-0019, MEF-ADR-0049, MEF-ADR-0050.
