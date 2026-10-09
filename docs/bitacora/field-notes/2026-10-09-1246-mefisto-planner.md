---
fecha: 2026-10-09
hora: 12:46
sesion: mefisto-planner
tema: Refinar #2129 (prohibir dependencias negadas en el planner publicado)
---

## Contexto
Refinar el borrador #2129, hermano publicado de #2128 (ya listo).

## Decisiones
- La regla de `## Dependencias` se escribe una vez bajo "Crear issues", fuera de los heredocs `ISSUEEOF` (lo de dentro termina en el body de cada issue), y aplica a los 4 templates (dominio, infra, proyeccion, MCP).
- Se quito el modo `oleadas` del alcance: ordena por matriz de archivos y no escribe `## Dependencias`.
- Verificacion en `test-planner-agent.sh` como CA propio.

## Referencias
Issues refinados: #2129 -> estado:listo. Hermanos: #2128, #2126, #2127.
