---
fecha: 2026-07-06
hora: 22:12
sesion: mefisto-planner
tema: Descubribilidad del arranque greenfield (quickstart + Proximos pasos en /onboard)
---

## Contexto
Tras cerrar la auditoria de onboarding greenfield (#208-#213, que verifico la doctrina "cero permisos" del flujo ongoing), surgio la necesidad de hacer el walkthrough de arranque greenfield **accesible y descubrible desde dentro del plugin**, para que un consumidor nuevo entienda como arrancar sin leerse el README entero.

Restriccion doctrinal clave: el flujo greenfield YA existe exhaustivamente en `README.md` §"Primeros pasos con el harness (greenfield)" (lineas ~181-331), y los ADRs 0021/0022/0025 son la fuente de verdad de las reglas. Lo que faltaba NO era contenido nuevo, sino un formato **corto/narrativo** + **descubribilidad**. Ningun issue debe re-enunciar reglas: se enlaza.

Decision del usuario ya tomada: capturar como par A+B.
- A: extender `/onboard` con un bloque "Proximos pasos" contextual + puntero al quickstart.
- B: crear `docs/greenfield-quickstart.md` (narrativa canonica corta, "explicaselo a un companero").

## Descubrimientos
- `/onboard` (`commands/onboard.md`) ya acumula toda la informacion de estado que necesita el bloque "Proximos pasos" (variables `N_FALTA`, `N_NV`, `ACTIONS`, y las secciones config/tokens/labels/CI/estructura). El bloque puede reutilizarla sin re-diagnosticar.
- El paso 2 del skill ("Presentar el resultado") ya sugiere el siguiente paso del flujo cuando el estado es LISTO; hay que unificar esa sugerencia con el nuevo bloque para no duplicar mensajes.
- Puntero descubrible al quickstart: como `/onboard` corre en el consumidor (que no tiene `docs/greenfield-quickstart.md`), la referencia robusta es la URL estable de GitHub del harness (`homepage` de `plugin.json` + `/blob/main/docs/greenfield-quickstart.md`), que funciona aunque `docs/` no viaje en el cache del plugin. Alternativa plugin-relative si se confirma empaquetado de `docs/`.
- Doctrina de solo-lectura de `/onboard`: el bloque nuevo debe ser puramente informativo; las unicas escrituras siguen siendo las provisiones opt-in (pasos 3 y 4).

## Decisiones
- **2 issues, no 1.** Archivos disjuntos (A -> `commands/onboard.md`; B -> `docs/greenfield-quickstart.md` + enlace en `README.md`), pipelineables por separado; cada uno un solo componente principal, <=6 CAs (5 y 5), <30 min. Pasan la revision de complejidad simplificada y la DoR de ADR-0011 columna `tooling`.
- **Dependencia de orden: A depende de B (#222 depende de #221).** El bloque "Proximos pasos" de A cierra con un puntero al quickstart; si A se mergeara a `main` antes que B, `/onboard` apuntaria a un documento inexistente (puntero huerfano — el caso que advierte la revision de complejidad: "no dejar un lado huerfano sin consumidor"). B es autonomo: aporta valor completo via el enlace desde el README §greenfield, sin depender de A. Por eso B primero; A lleva label `bloqueado` mientras B no cierre.
- Ambos son `lado: publicado` (onboard.md en `commands/`; README y `docs/` son la cara publica del harness). No hay concern de lado publicado-vs-interno huerfano.
- La separacion visual admin-vs-dev en el quickstart puede resolverse con una tabla "quien corre que", analoga a la tabla "Que corre donde" del README §7.

## Descartado
- Un solo issue con dos CAs: descartado por separacion de archivos y para poder pipelinearlos independientemente.
- Tratar A y B como paralelizables: descartado. Aunque los archivos son disjuntos (tecnicamente worktrees aislados), hay una dependencia semantica de valor (el puntero de A no debe quedar huerfano en `main`), asi que se declara orden explicito.

## Preguntas abiertas
- Empaquetado de `docs/` en el cache del plugin: si `docs/` viaja en el cache, el puntero de A podria ser plugin-relative en vez de URL de GitHub. Se dejo a criterio del implementer en las notas tecnicas de #222.

## Referencias
Issues creados:
- #221 Crear docs/greenfield-quickstart.md: narrativa corta del arranque greenfield (tipo:tooling, estado:listo)
- #222 Extender /onboard con un bloque Proximos pasos contextual y puntero al quickstart (tipo:tooling, estado:listo, bloqueado; depende de #221)
