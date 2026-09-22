---
fecha: 2026-09-22
hora: 17:59
sesion: mefisto-planner
tema: Refinar #1560 (ADRs aplicables en templates de fixture de certificacion TDD)
---

## Contexto
Refinar el draft #1560 surgido de la certificacion TDD multi-runtime v0.38.2.

## Decisiones
- La seccion `## ADRs aplicables` de los templates lleva solo un placeholder que sustituye el planner publicado (opcion B); sin piso fijo de ADRs.
- Un fixture con la seccion vacia o con el placeholder sin sustituir no es lanzable.
- Las secciones historicas de veredicto (#1435/#1436/#1411/#1487) no se tocan.
- Lado publicado (docs/), labels estado:listo + bug.

## Descartado
- Piso fijo de ADRs por columna; copiar las listas de los fixtures #34/#36.

## Referencias
Issues refinados: #1560
