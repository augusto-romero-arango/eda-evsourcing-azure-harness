---
fecha: 2026-09-20
hora: 09:34
sesion: mefisto-planner
tema: Refinamiento del rendimiento del adaptador OpenCode publicado
---

## Contexto
Se retomo el draft #1519 para convertir el cuello de botella observado en `adapter-opencode.sh render` en una tarea pequena, medible y lista para el pipeline interno.

## Descubrimientos
El adaptador tiene 32 sitios de invocacion de `jq`; el camino por fuente repite el parseo de frontmatter y la validacion MCP global. El `generate-published-adapters.sh --check` de control tardo 15 s, consistente con la linea base previa de 13,8-14,0 s.

## Decisiones
Se acoto #1519 al adaptador publicado y su prueba. Los CAs fijan un maximo de 12 procesos `jq` por render representativo, mediana <= 10 s para tres corridas del generador, salida byte-identica y conservacion de los fallos cerrados. El presupuesto de todo el gate de neutralidad queda fuera del alcance.

## Descartado
No se amplio el issue a `validate-published-mcp.sh`, al generador, al adaptador interno ni a una dependencia nueva. Tampoco se uso solo tiempo de pared como regresion: se agrego una guarda estructural sobre procesos.

## Preguntas abiertas
Ninguna para Definition of Ready. Si el generador no alcanza <= 10 s sin tocar otros componentes, se medira y abrira un seguimiento separado en vez de ensanchar #1519.

## Referencias
Issues refinados: #1519 — Recortar el coste de render de adapter-opencode.sh en el generador publicado.
