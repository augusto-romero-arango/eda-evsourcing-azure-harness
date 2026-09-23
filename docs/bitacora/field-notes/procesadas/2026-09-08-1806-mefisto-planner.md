---
fecha: 2026-09-08
hora: 18:06
sesion: mefisto-planner
tema: refinamiento de observabilidad multi-runtime para tooling publicado
---

## Contexto

La sesion continuo el refinamiento del corte vertical publicado de MEF-ADR-0053 sobre el draft #1063. El issue mezclaba el escritor de observabilidad de `tooling-pipeline.sh`, tres readers, persistencia de raw sensible, identidad de distribucion y sesiones interactivas.

## Descubrimientos

- #1050 ya aporta escritura solo canonica y lectura plural canonica/legacy, pero ningun caller de observabilidad tooling la habia adoptado.
- `stream-watch.sh` parsea directamente `*.stream.jsonl` nativo de Claude; durante el corte debe leer `*.events.jsonl` neutral sin romper el fallback historico de TDD/IaC todavia no migrados.
- `metrics-report.sh` y `/work-status` no pueden elegir un unico root: tooling canonico y TDD/IaC legacy coexistiran. Deben combinar ambas poblaciones y deduplicar con precedencia canonica.
- El runner neutral conserva `message.text`, resumen de comandos y detalle de stderr. El JSONL neutral no es automaticamente una frontera segura para persistencia; hace falta un modo opt-in que redacte antes de cada anexo en vivo y final.
- `diagnose-installation-identity.sh` exige `mefisto-manifest.json` en Claude, pero la distribucion Claude actual no lo contiene y marketplace sigue apuntando a `./`. Incrustar el SHA del mismo commit en un archivo versionado plantea una referencia circular que MEF-ADR-0053 no resolvio.
- El contrato `append-session` de #1057 omite `runtime`, `model` y `harness_commit`, aunque MEF-ADR-0053 exige esas dimensiones en sesiones. Los issues #1058/#1059 no estaban listos mientras conservaran esa allowlist incompleta.

## Decisiones

- #1063 queda acotado a un unico escritor: `scripts/tooling-pipeline.sh` y glue focalizado de `_pipeline-common.sh`.
- Los readers se separan en #1123 (`stream-watch.sh`), #1124 (`metrics-report.sh`) y #1125 (`/work-status`) y deben aterrizar antes de que tooling abandone el path legacy.
- #1128 agrega `--redact-observability` al runner neutral. #1063 no persistira raw, stderr ni prompts; la evidencia durable sera el JSONL neutral redactado y sus derivados.
- #1063 registra identidad disponible desde metadata; bajo Claude incompleto usa `null` y degradacion visible. No infiere commit desde Git o caches y deja la certificacion bloqueada por #1126.
- La identidad de distribucion Claude se captura como draft arquitectonico #1126. La identidad faltante de `sessions.jsonl` se captura por separado en #1129.
- #1058 y #1059 regresan a `estado:borrador` y quedan bloqueados por #1129 hasta corregir el contrato neutral de sesiones.
- #1066 depende explicitamente de #1126/#1129 y deja de exigir un raw supuestamente redactado: raw, stderr y prompts no deben persistirse.

## Descartado

- Mantener #1063 como issue transversal de pipeline, visor, dashboard y reporte: viola la revision simplificada de complejidad.
- Llamar “raw redactado” a una transformacion: si se redacta ya no es raw; el wire data se usa solo temporalmente.
- Hacer que el visor neutral muestre `input_summary`: puede contener paths o fragmentos de comandos sensibles.
- Elegir solo `pipeline-history.jsonl` canonico cuando exista: ocultaria TDD/IaC legacy durante la migracion parcial.
- Dar por resuelta la identidad Claude con `plugin.json.version`, `git rev-parse` en consumidor o el nombre del cache: ninguna opcion satisface el contrato version+commit de #1092/MEF-ADR-0053.

## Preguntas abiertas

- Que procedencia Git comun deben exponer ambos artefactos como `commit` sin crear una autorreferencia en la distribucion Claude versionada.
- Como se materializara y retargeteara la raiz autocontenida `dist/claude/` sin perder hooks, Skills, MCP, scripts y metadata.
- Que valor de modelo exponen realmente los hooks de inicio de sesion en cada runtime; cuando no exista debera persistirse `null` sin inferencia.

## Referencias

Issues creados: #1123, #1124, #1125, #1126, #1128 y #1129.

Issues refinados/actualizados: #1063, #1058, #1059 y #1066.
