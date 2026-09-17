---
fecha: 2026-09-16
hora: 11:01
sesion: mefisto-planner
tema: Refinamiento de la clausura de conocimiento TDD publicada
---

## Contexto
Se refino #1407 para corregir la ausencia de ADRs y del cheatsheet en las distribuciones publicadas.

## Descubrimientos
`package-opencode-release.sh` ya empaqueta todo `dist/opencode`; la causa raiz esta en el generador. `TOOLING_CLOSURE_ASSETS` solo modela ejecutables, por lo que el conocimiento merece una coleccion separada.

## Decisiones
Descubrir deterministicamente `docs/adr/mef-adr-*.md`, incluir explicitamente el cheatsheet, excluir `INDICE-TEMATICO.md` y bloquear de forma directa #1409 y #1410. El issue queda `estado:listo`, `tipo:tooling` y `bug`.

## Descartado
No mantener una lista manual de ADRs, no empaquetar todo `docs/` y no modificar el packager salvo su prueba. MEF-ADR-0031 se retiro de los ADRs aplicables por no gobernar esta frontera de distribucion.

## Preguntas abiertas
Ninguna para #1407.

## Referencias
Issues refinados: #1407 Empaquetar el conocimiento requerido por el flujo TDD
