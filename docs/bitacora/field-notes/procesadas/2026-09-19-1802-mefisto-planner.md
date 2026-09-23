---
fecha: 2026-09-19
hora: 18:02
sesion: mefisto-planner
tema: Refinar #1500-#1505 y #1508 (config canonico .mefisto/harness.config.json) y partir #1507 (instrucciones canonicas AGENTS.md): scaffolders, purge-store, bootstrap-backend, install-apim, seed-secret y el skill interno de contrato e inventariar la deuda legacy hermana
---

## Contexto
Draft #1500 creado desde el consumidor `mefisto-consumer-certification` (preflight de la certificacion TDD, #1464): `/scaffold-projections` aborta en un consumidor canonico porque lee solo `.claude/harness.config.json`. Se pidio llevarlo a `estado:listo`; despues, refinar los drafts hermanos #1501 (`/scaffold-mcp`), #1502 (`/purge-store`), #1503 (`bootstrap-backend.sh`), #1504 (`/install-apim`) y #1505 (`/seed-secret`); partir el inventario #1507 (lectores de `CLAUDE.md`); y refinar #1508 (skill interno `harness-config-contract`).

## Descubrimientos
- Causa raiz confirmada en `main` (`519e7fc`): `commands/scaffold-projections.md:21,27,29,41,44` y `agents/projections-scaffolder.md:34,36` hardcodean la ruta legacy. Igual `commands/scaffold-mcp.md:41,43,51` y `agents/mcp-scaffolder.md:51,55,58,68,72,1754` (tres bloques: dominio de ejemplo, `tenancy.strategy`, dominios a wirear).
- Ninguno de esos cuatro archivos esta en `src/published/` ni en la clausura `dist/`: la correccion es inline (patron #1212, `infra-base-scaffolder`), no `{{mefisto:config-path}}` (#1427). Migrarlos a fuente neutral es otro issue.
- Tres politicas de coexistencia conviven hoy: `resolve_harness_config_path read` e `implement.md` emiten `AVISO`; `infra-base-scaffolder` (#1212) es silencioso. Vocabulario fijado: "AVISO de coexistencia" = el texto literal de `_pipeline-common.sh:92`. La salida Claude de `domain-scaffolder` (lineas 1-35) es la referencia de textos generados para config e instrucciones.
- Inventario de lectores/escritores legacy del **config** en publicados: `scaffold-mcp`/`mcp-scaffolder`, `purge-store.md`, `bootstrap-backend.sh:140` (lectura real de `azureLocation` pese a ya correr `load_harness_config`), `install-apim.md` (lectura + **escritura** legacy de `tenancy.strategy`), `seed-secret` (escribe bien al canonico via `upsert_harness_secret`, pero mensajes y `git add` nombran la legacy).
- Inventario verificado de lectores legacy del contrato de **instrucciones** (`CLAUDE.md` en vez de `AGENTS.md`): bloqueantes mcp-scaffolder (4 tokens), projections-scaffolder (2), workos-identity-scaffolder (1), install-apim (2b degrada, 9.1 bloquea); infra-base-scaffolder omite la alerta de proyecciones **en silencio** y pide duplicar el token en `CLAUDE.md`; bug-investigator es una linea de prosa. `historiador`/`fix-review` solo citan `CLAUDE.md` como referencia de politica: no aplican. Patron a copiar: salida Claude de `implementer.md` lineas 1-31 (`MEFISTO_INSTRUCTIONS_PATH`) y tests `test-*-instructions-contract.sh`.
- El skill interno `harness-config-contract` titula su seccion 1 y su `description` con la ruta legacy y su seccion 3 ubica `sessions.jsonl` bajo `.claude/pipeline/` (el hook ya escribe `.mefisto/pipeline/sessions.jsonl`); su seccion 2 (`AGENTS.md`) ya esta alineada y sirve de redaccion modelo. `.plugin-root.previous` bajo `.claude/pipeline/` (`update-plugin.sh:73`) es la excepcion transitoria que MEF-ADR-0053 d.4 (#1099) enumera, no un defecto. El gate de neutralidad tiene excepcion R2 para ese archivo y no detecta excepciones huerfanas.
- `README.md` tiene 5 menciones legacy del config y 0 canonicas: la instalacion (linea 170) induce a un consumidor nuevo a nacer legacy.
- `commands/purge-store.md:41-47` usa la ruta legacy **relativa al cwd** (sin `$REPO_ROOT`); `scripts/purge-store.sh` ya carga el config efectivo pero sus mensajes nombran la legacy -- `load_harness_config` exporta `HARNESS_CONFIG_PATH` (`_pipeline-common.sh:213`), precedente de uso en `onboard-migrate-directives.sh:42`.
- `scripts/bootstrap-backend.sh:140` lee `azureLocation` de la legacy **despues** de correr `load_harness_config`; su comentario (linea 137) cita como patron a `_pipeline-common.sh:2164` (`repoSlug`), que tambien lee la legacy directo -- y `_pipeline-common.sh` si esta en la clausura `dist/`. Los prompts de `tooling-pipeline.sh:649,770` listan solo la legacy en el alcance de escritura del consumidor.
- La politica de **escritura** ya existe y esta probada: paso 6 de `/onboard` (#1088) y `upsert_harness_secret` (#1082) usan `resolve_harness_config_path write`, cargan el efectivo y **rechazan** escribir si el efectivo es solo legacy ("migra primero"); si no hay ninguno, `load_harness_config` aborta. Vocabulario: "rechazo legacy-only". El `jq` del paso 6 de `/onboard` (`.tenancy = {strategy: $s}`) reemplaza el objeto `tenancy` completo.
- En `/seed-secret` no hay defecto de escritura: `upsert_harness_secret` escribe bien al canonico; el defecto es que script y skill *hablan* de la legacy y el `git add` apunta a ella -> el commit sale sin `secrets[]` y CI no siembra el valor. Tras un upsert exitoso, `HARNESS_CONFIG_PATH` == ruta escrita (el helper rechaza legacy-only), asi que no hace falta cambiar la firma del helper.

## Decisiones
- #1500-#1505 pasan a `estado:listo` + `bug` y #1508 a `estado:listo` (documentacion interna, sin `bug`); los tres primeros emiten el `AVISO` de coexistencia (alineado con el resolver de referencia y MEF-ADR-0018, no con el patron silencioso de infra-base).
- Alcance de cada uno: solo el componente (par skill+agente en #1500/#1501; skill+script en #1502) + test `test-{scaffold-projections,scaffold-mcp,purge-store}-config-path.sh` + changelog. En #1502 y #1503 los scripts no resuelven nada nuevo: reutilizan `HARNESS_CONFIG_PATH` (opcion (a), elegida por el usuario frente a exponer `HARNESS_AZURE_LOCATION` desde `load_harness_config`: el unico otro consumidor de `azureLocation` es prompt y no puede usar variables de entorno). Sin migracion a fuente neutral, sin regenerar `dist/`. #1501 no depende de #1500 (comparten patron, no codigo).
- Fuera de alcance de #1501, explicitamente: `.claude/pipeline/.plugin-root` (mirror autorizado por MEF-ADR-0053 d.4 enmienda #1099) y los tokens desde `CLAUDE.md` (contrato de instrucciones, draft aparte).
- La deuda hermana se captura como drafts independientes (regla "huecos de tooling -> drafts"), uno por componente. El inventario #1507 se partio (opcion (a), elegida por el usuario) en 5 issues listos, uno por componente bloqueante: #1507 (mcp-scaffolder), #1514 (projections-scaffolder), #1515 (workos-identity-scaffolder), #1516 (/install-apim), #1517 (infra-base-scaffolder, amplia `test-infra-base-config-path.sh`); `bug-investigator` se plego en #1512 (textos residuales). Ninguno depende de #1500/#1501/#1504 aunque compartan archivo: config e instrucciones son contratos distintos y el motor secuencial sincroniza main entre eslabones.

## Descartado
- Usar `{{mefisto:config-path}}` en #1500/#1501: exigiria migrar primero los archivos a `src/published/`.
- Un solo issue "migrar todos los lectores legacy": componentes distintos, algunos con escritura (install-apim) que requieren su propia decision.
- #1504 (`/install-apim`): opcion (b) elegida por el usuario -- copiar literal el bloque del paso 6 de `/onboard` (resolver `PLUGIN_SCRIPTS`, `source _pipeline-common.sh`, `resolve_harness_config_path write`, rechazo legacy-only, `mktemp`+`mv`), cambiando solo el filtro `jq` para preservar otros campos de `tenancy`; `git add "$CONFIG"`. `_pipeline-common.sh` no se toca.
- #1505 (`/seed-secret`): el script imprime la ruta escrita (`$HARNESS_CONFIG_PATH`) en el `OK` y en una linea capturable `Registro: <ruta>`; el skill hace `git add` de esa ruta impresa, sin resolver nada por su cuenta.
- #1508: alcance = todo el `SKILL.md` (description, seccion 1 con la regla lectores/escritores y punteros al resolver de referencia, bullet de `.mefisto/pipeline/` en la seccion 3), manteniendo honesta a mano la allowlist R2 del gate. Sin test nuevo: CAs verificables por `grep` + `test-guards [F]` + gate de neutralidad.
- Exponer `HARNESS_AZURE_LOCATION` en `load_harness_config` (#1503, opcion (b)): tocaria `_pipeline-common.sh` (clausura `dist/`) sin reutilizacion real hoy.
- Agrupar los lectores de `CLAUDE.md` por severidad en 2 issues (#1507, opcion (b)): 5 componentes en un issue.
- Resolver inline la politica de escritura en `/install-apim` (#1504, opcion (a)): duplicaria en prosa una politica ya codificada como funcion (tercera politica, MEF-ADR-0018).
- Declarar #1501 dependiente de #1500 para forzar orden en el batch: no hay dependencia real; el sync verificado entre eslabones cubre el archivo compartido (ninguno, de hecho).

## Preguntas abiertas
- Cuando migrar `scaffold-projections`/`projections-scaffolder`, `scaffold-mcp`/`mcp-scaffolder` e `infra-base` a fuente neutral `src/published/`: no hay issue abierto.

## Referencias
Issues refinados: #1500, #1501, #1502, #1503, #1504, #1505, #1507 (estado:listo, bug); #1508 (estado:listo)
Issues creados listos al partir #1507: #1514, #1515, #1516, #1517 (estado:listo, bug)
Issues creados (drafts, ya refinados en esta misma sesion): #1503, #1504, #1505
Issues creados (drafts pendientes): #1511 (repoSlug legacy en _pipeline-common.sh), #1512 (textos residuales legacy en tooling-pipeline.sh/setup-github-labels.sh/bug-investigator), #1513 (jq de /onboard que reemplaza el objeto tenancy), #1518 (README: config legacy en la instalacion, bug)
