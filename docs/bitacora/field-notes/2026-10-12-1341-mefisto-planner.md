---
fecha: 2026-10-12
hora: 13:41
sesion: mefisto-planner
tema: Paridad del sequential en curso, repoSlug en onboard/upgrade, carril solo smoke del TDD y tiempo del issue en curso
---

## Contexto
Continuación de la sesión (nota previa en el PR #2348). Llegaron capturas de la banda durante un lote y tres borradores nacidos al verificar el rename del repo (#2349) y de una corrida abortada en Bitakora (#952).

## Descubrimientos
- `run_tests_projects` excluye a propósito `*.SmokeTests/` (MEF-ADR-0013). Por eso un issue que solo toca smoke nunca queda en rojo en el Gate 1b, y el pipeline abortaba con "todos los tests pasan".
- `no-red-signal.md` solo se respeta con `projection-test-writer`. El carril `refactor-signal` salta los stages 2, 2b y 4, pero no le da dueño a los entregables documentales.
- `_repo_slug` de `upgrade.sh` nunca leía `.mefisto/harness.config.json`, y `repoSlug` también decide de dónde baja las releases el `/upgrade` de OpenCode.
- `gh api` con `Accept: application/vnd.github.raw+json` devuelve el `plugin.json` crudo, sin base64 (probado contra mefisto y MiControlPlane).
- El pact solo dibujaba la tabla de issues al cerrar el lote. La cinta interna la muestra también mientras corre.

## Decisiones
- #2350: el sequential en curso del pact copia el layout interno y quita la fila de pasos del agente.
- #2353: `/onboard` valida el slug efectivo:
  - si coincide con el `origin` del propio consumidor, `FALTA` sin consultar la red;
  - si no, lee el `plugin.json` del slug: `mefisto` da `OK`, un 404 o un `name` distinto da `FALTA`, y sin `gh` o sin red queda `NO VERIFICADO`.
- #2352: `upgrade.sh` usa `resolve_harness_config_path`. El comando no exporta nada, porque declara al script como única autoridad.
- #2357: carril *solo smoke* detectado por el diff, sin señal nueva:
  - el stage 2 corre en modo documental y es el dueño de los ADR y las filas de docs;
  - los stages 2b y 4 quedan `skipped`;
  - el PR lleva una sección "Validación pendiente post-deploy".
- #2358: la doctrina del carril va en los agentes `test-writer` e `implementer`.
- #2360 y #2361: una fila `●` en curso en la tabla del lote, con tiempo corriendo y costo `…`. Va un issue por lado: el usuario pidió issues, no briefs.

## Descartado
- Respetar `no-red-signal` en write-side: se mantiene que el rojo write-side siempre es alcanzable.
- Exportar `HARNESS_CONFIG_PATH` desde el comando `/upgrade`.
- Mostrar el tiempo del issue en la cola o en la línea del título.

## Preguntas abiertas
- Lanzar `/mefisto-sequential 2357 2358 2360 2361`, publicar el release y relanzar Bitakora#952 con `--from-stage 2`.

## Referencias
Issues: #2350, #2352, #2353 (cerrados), #2357, #2358, #2360, #2361 (estado:listo).
