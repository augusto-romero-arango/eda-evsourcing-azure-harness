---
fecha: 2026-09-23
hora: 06:35
sesion: mefisto-planner
tema: Refinamiento del issue 1602
---

## Contexto
Se refino el draft #1602 tras verificar la falla real de la suite del generador publicado.

## Descubrimientos
El faltante original de `pr-sync.sh` fue corregido por el PR #1607, pero la falla reaparecio con `work-status-collect.sh`: la causa raiz es la lista y los conteos duplicados que el fixture mantiene fuera de `TOOLING_CLOSURE_ASSETS`.

## Decisiones
El issue se reformulo como correccion sistemica de un solo script de test, con cinco criterios verificables, lado publicado y labels `tipo:tooling`, `bug` y `estado:listo`.

## Descartado
Se descarto limitar el cambio a agregar manualmente la ruta faltante actual, porque repetiria la deriva observada dos veces.

## Preguntas abiertas
Cerrar el draft #1606 como duplicado de #1602.

## Referencias
Issues creados: ninguno. Issue refinado: #1602, "Evitar la deriva del fixture de adaptadores publicados".
