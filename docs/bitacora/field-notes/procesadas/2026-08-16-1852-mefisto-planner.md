---
fecha: 2026-08-16
hora: 18:52
sesion: mefisto-planner
tema: trazabilidad de version del harness en logs y metricas del consumidor y del interno
---

## Contexto

El usuario pregunto si los logs y metricas de ejecucion de Mefisto en los consumidores
registran con que version del plugin corrio cada accion. La auditoria del codigo
(modo analizar) confirmo que NO: ningun artefacto de observabilidad estampa la version.

Inventario verificado:
- `pipeline-history.jsonl` (tdd/tooling/iac, 6 puntos de escritura): esquema sin version.
- `sessions.jsonl` (hook SessionStart): session_id/transcript_path/cwd/source/timestamp, sin version.
- `events.log`, logs de stage y trazas `*.stream.jsonl`: sin version (las metricas de
  #646 extraen hasta el `model`, nada del plugin).
- `metrics-report.sh` (#656): hereda el esquema, no puede segmentar por version.
- Unico rastro implicito: `.claude/pipeline/.plugin-root` (basename = version del cache),
  pero es snapshot sobrescrito por SessionStart y por /upgrade — no reconstruye historia.
- El gap existe tambien del lado interno: `mefisto-tooling-pipeline.sh` (L107/L820) y
  `mefisto-metrics-report.sh`.

## Descubrimientos

- La estructura del cache (`<cache>/<marketplace>/mefisto/<version>`) ya es contrato
  de facto: `update-plugin.sh` la parsea (`_versiones_del_cache`, `_marketplace_dir`).
  El basename de `CLAUDE_PLUGIN_ROOT` es una fuente de version valida para el hook.
- Los pipelines publicados pueden leer su propia version de
  `<dir del script>/../.claude-plugin/plugin.json` (el cache distribuye el repo entero).
- Motivacion directa: el plan de velocidad (#645-#648) instrumento metricas por stage
  y reporte agregado, pero sin version estampada no hay atribucion de mejoras o
  regresiones a releases concretas. En el interno, la version de plugin.json solo
  cambia en release: entre releases el discriminador util es el SHA de HEAD.

## Decisiones

- Nombre de campo uniforme `harness_version` en los tres artefactos (pipeline-history
  publicado, sessions.jsonl, pipeline-history interno) para cruzarlos sin mapeos.
- Lado interno estampa DOS campos: `harness_version` (paridad de esquema con el
  publicado) + `harness_sha` (granularidad entre releases). El SHA se toma del repo
  principal (los `.claude/scripts/` que corren son los del checkout principal, no los
  del worktree del issue).
- `harness_sha` NO es eje de agrupacion en el reporte interno (un grupo por corrida
  no agrega nada): va como detalle en las filas per_run.
- La version se computa una vez en el prologo de cada pipeline; el trap de aborto solo
  interpola la variable ya resuelta.
- Retrocompatibilidad sin migracion: las lineas historicas sin el campo agrupan como
  `(sin version)` reutilizando el patron instrumented/legacy ya existente en ambos reportes.
- Particion en 5 issues (estampado != reporte, un componente principal por issue),
  simetrica entre publicado (A/C) e interno (D1/D2), + hook (B).
- Ningun issue crea rutas de artefacto nuevas: no aplica el registro previo
  blocklist/allowlist de MEF-ADR-0019 seccion E.

## Descartado

- Estampar solo en pipeline-history y dejar sessions.jsonl sin version (se prefirio
  cubrir ambos artefactos: cruzarlos requiere el campo en los dos).
- Solo SHA en el interno (se prefirio version+SHA para no bifurcar el shape de
  `by_version` entre los dos reportes).
- Reconstruccion retroactiva de versiones por fechas de /upgrade: fragil
  (`.plugin-root.previous` lo borra el hook SessionStart; el delta de CHANGELOG no
  persiste en el consumidor).

## Preguntas abiertas

- Si algun dia el consumidor instala el plugin por path local (fuera del cache del
  marketplace), el basename de CLAUDE_PLUGIN_ROOT no sera semver; #661 decidio
  aceptarlo tal cual (el campo describe lo cargado, no valida formato).
- Portar la columna `harness_sha` al reporte publicado no aplica hoy (el consumidor
  no conoce el SHA del harness); si el cache algun dia expone metadata de commit,
  reevaluar.

## Referencias

Issues creados:
- #660 Estampar harness_version en las entradas de pipeline-history.jsonl de los pipelines publicados
- #661 Estampar la version del plugin en sessions.jsonl desde el hook SessionStart
- #662 Estampar harness_version y harness_sha en el pipeline-history.jsonl interno
- #663 Segmentar el reporte de metricas publicado por harness_version (depende de #660, bloqueado)
- #664 Segmentar mefisto-metrics-report.sh por harness_version con harness_sha como detalle per-run (depende de #662, bloqueado)

Orden de batch sugerido: 660, 661, 662, 663, 664 (unico criterio: dependencias
declaradas; la validacion formal la hace mefisto-validate-batch-deps.sh en el paso
1.5 de /mefisto-sequential).
