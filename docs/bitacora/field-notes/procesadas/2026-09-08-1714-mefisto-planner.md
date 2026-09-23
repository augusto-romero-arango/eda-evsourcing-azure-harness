---
fecha: 2026-09-08
hora: 17:14
sesion: mefisto-planner
tema: Refinamiento de los agentes tooling publicados
---

## Contexto

Despues de refinar #1054 se eligio #1060 como siguiente tarea de la ruta critica del corte vertical `/mefisto:tooling`: aportar ids de agente neutrales para los stages writer y reviewer del consumidor.

## Descubrimientos

- `scripts/tooling-pipeline.sh` contiene hoy la doctrina completa de writer/reviewer dentro de sus prompts y los ejecuta como nombres genericos.
- El contrato publicado solo modela capacidades (`read`, `edit`, `shell`, etc.); no tiene metadata de scope por rutas.
- El adaptador Claude traduce capacidades a disponibilidad de tools, no a permisos path-aware. El mapping OpenCode protege rutas del plugin, pero no clasifica por si solo tooling frente a logica de dominio bajo `src/`.
- Por tanto, definir los agentes no puede reemplazar honestamente el enforcement del pipeline ni demostrar que `bypassPermissions` desaparecio. Esa responsabilidad pertenece a #1062.
- Los agentes minimos no usan `{{mefisto:run ...}}` ni `{{mefisto:package-root}}`, por lo que #1054 no es una dependencia tecnica de #1060.

## Decisiones

- Se crean dos ids inequivocos: `tooling-writer` (`balanced`) y `tooling-reviewer` (`deep`), ambos con `read`, `edit` y `shell`, sin MCP, Skills, web o task.
- Los bodies contienen solo el rol estable; el issue, diff, allowlist concreta y path del summary viajan en el mensaje inicial de #1062.
- Ambos agentes son no interactivos, no publican ramas/PRs y dejan siempre un summary con secciones cerradas por rol.
- Las claves historicas `writer`/`reviewer` pueden permanecer en #1062 para stages, metricas y overrides; no sustituyen los ids neutrales.
- Se retiro #1054 de las dependencias, se quito `bloqueado` y #1060 paso a `estado:listo` sin dependencias abiertas.

## Descartado

- Ampliar #1060 para agregar scope path-aware al schema y a ambos adaptadores: seria otro componente y excederia una pasada pequena.
- Afirmar que `capabilities` o el frontmatter sustituyen los gates post-stage del pipeline.
- Duplicar dentro de cada rol la allowlist completa de `tooling-pipeline.sh`, porque volveria a introducir dos fuentes de verdad.
- Incluir ejecucion headless, reintentos, hold/resume, commits, push o PR en los agentes.

## Preguntas abiertas

- Al refinar #1062 se debe decidir y verificar la frontera exacta entre permisos del runner, prompt de scope y gates post-stage.
- El mapping OpenCode actual no permite `dotnet *`; #1062 debera confirmar si los agentes necesitan esa verificacion durante el stage o si los gates del pipeline son suficientes.

## Referencias

Issues creados: ninguno

Issue refinado: #1060
