---
fecha: 2026-09-20
hora: 09:28
sesion: mefisto-planner
tema: refinamiento del issue 1513
---

## Contexto
Se refino el draft #1513, que reportaba que `/onboard` reemplaza el objeto `tenancy` completo al escribir `tenancy.strategy`.

## Descubrimientos
La causa sigue presente en `commands/onboard.md:264`; `/install-apim` ya contiene el filtro de merge correcto y una prueba de bloques ejecutables que sirve de precedente.

## Decisiones
#1513 queda acotado al skill publicado `/onboard`, con un test dedicado que cubre `tenancy` existente y ausente, modo ejecutable e inventario de suite. Aplican MEF-ADR-0019, MEF-ADR-0028 y MEF-ADR-0053. Se agregaron los labels `bug` y `estado:listo`.

## Descartado
No se extrae un helper compartido ni se modifica `_pipeline-common.sh`; una expresion jq comun en dos comandos no justifica ampliar el alcance.

## Preguntas abiertas
Ninguna.

## Referencias
Issues refinados: #1513 — Preservar los demas campos del objeto tenancy al escribir tenancy.strategy desde /onboard.
