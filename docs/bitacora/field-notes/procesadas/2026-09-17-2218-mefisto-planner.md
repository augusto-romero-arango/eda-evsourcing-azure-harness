---
fecha: 2026-09-17
hora: 22:18
sesion: mefisto-planner
tema: Refinar #1416 (runner de la suite completa) y #1439 (adopcion del runner); crear #1471 (guard estatico)
---

## Contexto
Modo refinar sobre dos drafts encadenados de la suite completa de tests, ambos con un intento fallido previo por el gate de neutralidad R3. Sus bases #1438 (inventario) y #1440 (ejecutor) ya estaban mergeadas (PRs #1466/#1467).

## Descubrimientos
- `mefisto_test_inventory_check_canonical_coverage` (CA-4 de #1438) no tenia ningun consumidor fuera de su propio test: el runner #1416 es su consumidor natural.
- `mefisto_test_executor_run` retorna 0 aunque haya entradas FAIL; el veredicto agregado es responsabilidad del runner. Retorna 130/143 por INT/TERM y reconcilia CANCELLED siempre tras el `wait`.
- R3 escanea `src/internal/**` y `.claude/scripts/*.sh` de nivel superior; `.claude/scripts/tests/**` esta exento con `rules: ["ALL"]`.
- Hoy no existe ningun bucle completo ad hoc versionado sobre la suite: la unica aparicion literal del glob esta en los prompts de `mefisto-tooling-pipeline.sh` (lineas 1127/1213) que lo prohiben. Ningun test afirma sobre el texto de esos prompts.
- El baseline secuencial "1067.999 s" de #1439 no vive en ningun archivo del repo (medicion local del 2026-09-16).

## Decisiones
- #1416 CA-2 exige ambas validaciones del inventario (validate + cobertura canonica) antes de lanzar; cobertura incompleta es exit 1 sin lanzar pruebas.
- #1416 conserva las pruebas de senales 130/143 (tmux) en el mismo issue: precedente #1440 y CA-4 no puede quedar sin verificar en el PR que lo introduce.
- #1416: el runner no instala un trap INT/TERM que salga antes de que el ejecutor retorne, o pierde la reconciliacion CANCELLED y el resumen final.
- #1439 se parte: el guard estatico (antes CA-3) sale al hijo #1471, bloqueado por #1439 porque necesita que los prompts dejen de escribir el glob literal para poder escanear el pipeline sin exentarlo.
- #1439 CA-2 retira el glob literal y el conteo historico "mas de 120 scripts" de los prompts, y remite al runner en prosa.
- La medicion del runner real (#1439) queda solo en el body del PR, fechada y con sha; ninguna cifra se hardcodea en el repo ni en el README.
- #1439 lleva `bloqueado` (#1416 abierto, sin PR). #1471 lleva `bloqueado` (#1439 abierto).
- No se toca la allowlist de neutralidad en ninguno de los tres.

## Descartado
- Partir las pruebas de senales de #1416 en un issue hijo.
- Registrar los entrypoints nuevos en la allowlist R3 para poder nombrar variables de runtime en prosa.
- Descartar el guard estatico por no haber infractores hoy (el usuario prefirio conservarlo como issue propio).
- Registrar la medicion del runner en el README interno o en un doc nuevo de `docs/testing/`.

## Preguntas abiertas
- Si se quiere `/mefisto-test-suite` como comando en `src/internal/commands/`, es un issue aparte (no creado).
- Orden de batch sugerido: #1416 -> #1439 -> #1471 (cadena lineal, `/mefisto-next-order` lo confirmara cuando #1416 mergee).

## Referencias
Issues refinados: #1416 (borrador -> listo), #1439 (borrador -> listo + bloqueado)
Issues creados: #1471 (listo + bloqueado)
