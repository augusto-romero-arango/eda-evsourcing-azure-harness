---
fecha: 2026-09-16
hora: 14:21
sesion: mefisto-planner
tema: Desglose de la resolucion neutral de conocimiento TDD
---

## Contexto
Se refino #1409 tras comprobar que cuatro agentes TDD publicados dependian de rutas Claude-only para abrir ADRs, cheatsheet y recursos Nivel 3 del Skill `projections`.

## Descubrimientos
`{{mefisto:package-root}}` resuelve ADRs y cheatsheet, pero no abstrae la divergencia `skills/projections/` frente a `skills/mefisto-projections/`. El contrato necesita una directiva `{{mefisto:skill-root <id>}}` validada contra el frontmatter `skills`.

## Decisiones
#1409 queda limitado a `test-writer`. Se creo #1422 como prerrequisito contractual y un issue independiente para cada agente restante: #1423 `reviewer`, #1424 `projection-implementer` y #1425 `projection-test-writer`. #1411 ahora declara las cuatro dependencias de agentes.

## Descartado
Se descarto resolver recursos Nivel 3 con `package-root` y una ruta fisica comun: los adaptadores empaquetan nombres distintos. Tambien se descarto mantener los cuatro agentes en #1409 por exceder un componente principal.

## Preguntas abiertas
#1411 conserva pendientes la eleccion del consumidor de certificacion, el alcance de Stage 2b/proyecciones y la evidencia minima versionada.

## Referencias
Issues creados: #1422, #1423, #1424, #1425. Issue refinado: #1409. Dependencias actualizadas: #1411.
