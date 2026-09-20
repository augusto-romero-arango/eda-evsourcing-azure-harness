---
fecha: 2026-09-20
hora: 09:26
sesion: mefisto-planner
tema: Refinar #1509 (tests versionados sin bit de ejecucion que la suite salta en silencio)
---

## Contexto
Modo refinar sobre el draft #1509, creado al revisar #1495: un test nuevo se
commiteo con modo 100644 y quedo fuera de la suite completa sin aviso.

## Descubrimientos
- El alcance real es 5x el del draft: 25 de 151 tests (17%) estan versionados
  100644 -- 5 en `.claude/scripts/tests/` (carril interno) y 20 en
  `scripts/tests/` (carril publicado). Los 25 pasan al correrlos con `bash`.
- Causa raiz: el writer del pipeline crea archivos en modo 644 y el cierre
  (test-guards.sh + tests del diff) no lo detecta; `mefisto_test_inventory_validate`
  es fail-closed solo sobre lo que SI descubrio, nunca sobre lo excluido por `-x`.
- Donde debe vivir un guard que atrape el defecto en el PR que lo introduce:
  `scripts/tests/test-guards.sh`, porque es lo unico que el writer corre siempre
  al cerrar (la suite completa nunca es gate de stage, README interno).
- macOS no trae `timeout` por defecto: correr tests a mano sin envolverlos.

## Decisiones
- Opcion A: bloque `[L]` en `test-guards.sh` (bit en disco + modo en indice git,
  con verificacion positiva sobre fixture) + `chmod +x` de los 25 en el mismo
  issue, para no dejar `main` rojo entre medias. Un solo issue, sin partir.
- Fuera de alcance: chequeo equivalente en `mefisto_test_inventory_validate`
  (solo dispararia cuando el defecto ya esta en main) y cambios a los prompts
  del writer (el bloque rojo en el cierre ya le indica el remedio).
- Fuentes canonicas de `src/published/scripts/tests/` y `src/runtime/tests/`
  quedan fuera del barrido: se alcanzan por shim con `exec bash`, el bit no importa.

## Descartado
- Opcion A+B en dos issues: la capa del inventario no aporta deteccion temprana.

## Preguntas abiertas
- Si mas adelante se quiere que la suite completa tambien rechace un carril con
  archivos excluidos por `-x`, seria un issue aparte sobre
  `mefisto-test-inventory.sh` (hoy no se abrio draft).

## Referencias
Issues refinados: #1509 (estado:borrador -> estado:listo, +bug; titulo ampliado a
ambos carriles y 25 archivos).
