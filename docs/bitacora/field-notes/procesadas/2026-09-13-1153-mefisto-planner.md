---
fecha: 2026-09-13
hora: 11:53
sesion: mefisto-planner
tema: Completar la certificación multi-runtime del issue 1181 sobre v0.37.16
---

## Contexto

El mantenedor informó que la release v0.37.16 logró completar tooling correctamente en Claude y OpenCode y pidió continuar con el issue #1181. Como el cierre anterior había fallado por evidencia incompleta, se diseñaron prompts autónomos para auditar el consumidor sin exigir recopilación manual.

## Descubrimientos

- La release pública v0.37.16 existe y el manifiesto del checkout declara el commit fuente `e9054d5f7576e13edf09b6ca304b79f8d95b0884`.
- Todas las dependencias locales declaradas por #1181 están cerradas.
- Las corridas válidas corresponden a consumer #11/PR #18 para Claude y consumer #12/PR #19 para OpenCode, con baseline común `c96e10ca129662a6bcc3cedcd8b08618f67f2d6e`.
- El primer auditor reportó tres bloqueos aparentes: checks sin verde, filas Herdr invertidas y ausencia de modelo heredado Claude.
- La geometría real descartó el supuesto bug Herdr: workspace `wA`, Claude en `rect.y=1` y OpenCode en `rect.y=42`, labels canónicos y pools separados.
- La expectativa de modelo heredado era incorrecta. Sin `--models`, `tooling-pipeline.sh` resuelve automáticamente los defaults por perfil mediante `mefisto_resolve_model`: writer/balanced=`sonnet`, reviewer/deep=`opus`; el runner los recibe explícitamente y por eso `inherited=false` es correcto.
- Los checks no estaban pendientes ni fallidos: los fixtures docs-only no activan el único workflow `pull_request`, `Infra CD`, filtrado a `infra/**`. Ambos SHA tienen cero Actions runs y cero check-runs.
- La auditoría final publicó expedientes sanitizados, confirmó Herdr/observabilidad/centinelas en `PASA` y ejecutó la limpieza completa: PRs cerrados sin merge, ramas remotas eliminadas, issues fixture cerrados `not planned`, cero worktrees, árbol limpio y baseline restaurado.

## Decisiones

- Refinar CA-5 de #1181 para exigir resolución automática Claude frente a override explícito OpenCode, no `inherited=true`.
- Refinar CA-3 para exigir verde únicamente a checks aplicables; una exclusión verificable por filtros se registra `NO_APLICAN`.
- No abrir bugs: Herdr y modelos se comportaron conforme al código; la ausencia de checks es consecuencia del scope docs-only del fixture y no un defecto del harness.
- Registrar el expediente operacional final como `PASA` en el body y comentarios de #1181.
- Mantener #1181 abierto y `estado:listo` hasta que `/mefisto-tooling 1181` traslade el expediente a `docs/testing/opencode-consumer-cutover.md`; no cerrarlo manualmente antes de integrar ese cambio documental.

## Descartado

- No crear un bug por filas Herdr invertidas: las coordenadas reales demostraron Claude arriba/OpenCode abajo.
- No cambiar la resolución de modelos para fabricar herencia Claude: contradiría la resolución automática vigente sin requerimiento en MEF-ADR-0053.
- No agregar CI artificial al consumidor para un fixture docs-only: MEF-ADR-0053 exige PR real y observabilidad, no checks ajenos al alcance.
- No cerrar #1181 únicamente con evidencia narrativa; se preservaron URLs verificables y se completó la limpieza.

## Preguntas abiertas

- Ninguna operacional. Resta únicamente implementar la actualización documental de #1181 y luego continuar con el veredicto global #1066.

## Referencias

Issues creados: ninguno.
Issues actualizados: #1181 — Ejecutar el tooling publicado en ambos runtimes desde Herdr.
Evidencia Claude: https://github.com/augusto-romero-arango/mefisto-consumer-certification/issues/11#issuecomment-5655078146
Evidencia OpenCode: https://github.com/augusto-romero-arango/mefisto-consumer-certification/issues/12#issuecomment-5655078692
Comentario final en #1181: https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1181#issuecomment-5655153827
