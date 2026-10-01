---
fecha: 2026-09-22
hora: 20:36
sesion: mefisto-planner
tema: Refinar #1554 (reentrega de field note tras PR mergeado)
---

## Descubrimientos
- Tres fallos verificados en mefisto-field-note.sh: ref remota rancia rompe el lease; contenido identico igual hace push (rama huerfana); contenido nuevo no abre PR al ver el PR mergeado.

## Decisiones
- Opcion A: reentrega = PR nuevo desde la misma rama de sesion; borrar solo la ref rancia de esa rama; ancestro de main decide identico vs nuevo.

## Descartado
- Rama con sufijo por entrega (B).

## Referencias
Issues refinados: #1554.
