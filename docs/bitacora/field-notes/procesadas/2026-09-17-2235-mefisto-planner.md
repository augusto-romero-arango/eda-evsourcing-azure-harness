---
fecha: 2026-09-17
hora: 22:35
sesion: mefisto-planner
tema: Refinar #1468 (descubribilidad de la prohibicion R3 antes de escribir)
---

## Contexto
Dos writers (#1416, #1439) abortaron el 2026-09-17 por la misma fuga R3 copiada de `mefisto-state.sh`, que pasa el gate por excepcion nominal. El draft #1468 pedia hacer visible la regla antes de escribir.

## Descubrimientos
- El unico punto garantizado antes de escribir en headless es el prompt (`STAGE1_PROMPT`/`STAGE2_PROMPT`); README interno y AGENTS.md no lo son.
- El prompt vive en `src/internal/` y tambien esta bajo R3: la regla se enuncia por referencia a la cabecera del gate y por categoria, nunca con los literales.
- `mefisto-state.sh` es el unico archivo bajo `src/internal/scripts/` con excepcion R3 por mera prosa; los demas la necesitan de verdad.
- MEF-ADR-0019 E: retirar una excepcion y limpiar su uso cabe en un solo PR (el gate que juzga se carga desde main); solo anadirla exige dos.

## Decisiones
- Bloque `NEUTRALIDAD DE RUNTIME:` unico (variable Bash) interpolado en writer y reviewer; cubre R1-R3 sin costo extra.
- Cortar la copia en el origen: reformular el comentario de `mefisto-state.sh` y retirar su entrada de la allowlist.
- Asserts en `test-tooling-runtime-neutral.sh` (puede nombrar los literales: `.claude/scripts/tests/**` es `ALL`).

## Descartado
- AGENTS.md y `src/internal/scripts/README.md` como ubicacion de la regla.
- Ampliar la allowlist para archivos nuevos.

## Preguntas abiertas
- #1469 (mensaje de remedio del gate) sigue en borrador; sin orden impuesto respecto a #1468.

## Referencias
Issues refinados: #1468 (estado:borrador -> estado:listo)
