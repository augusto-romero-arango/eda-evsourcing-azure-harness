---
fecha: 2026-09-15
hora: 23:23
sesion: mefisto-planner
tema: auditoria de paridad TDD entre Claude Code y OpenCode
---

## Contexto
Se reviso si la migracion publicada del flujo TDD estaba completa como producto multi-runtime.

## Descubrimientos
El pipeline, los agentes, permisos y clausura ya estan adaptados y sus suites pasan, pero OpenCode carece del comando `implement` y del conocimiento que los agentes intentan leer. Cuatro agentes aun resuelven conocimiento mediante el marker/cache Claude y cinco conservan lectores exclusivos de `CLAUDE.md`; `domain-scaffolder` tambien lee solo la configuracion legacy.

## Decisiones
Separar la correccion en drafts por componente: conocimiento distribuido, resolucion de package root, contrato consumidor, comando neutral y certificacion E2E. Mantener fallback legacy indefinido conforme a MEF-ADR-0053.

## Descartado
No declarar la paridad completa solo porque las pruebas estaticas y el arranque hasta `Uso:` estan verdes. No combinar todas las brechas en un unico issue saturado.

## Preguntas abiertas
Politica exacta para inventariar ADRs; representacion segura del flag de scaffold en el comando neutral; alcance final de la certificacion para Stage 2b y proyecciones.

## Referencias
Issues creados: #1407, #1408, #1409, #1410, #1411.
