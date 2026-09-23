---
fecha: 2026-09-08
hora: 21:06
sesion: mefisto-planner
tema: Filas Herdr multi-runtime para consumidores
---

## Contexto

Se refino #1064 para extender a consumidores el layout Herdr Claude/OpenCode que ya funciona dentro del repo Mefisto. El draft original no contemplaba la migracion de workspaces consumidores existentes ni que el planner publicado todavia no forma parte del primer corte OpenCode.

## Descubrimientos

- `herdr-workspace.sh` ya implementa para Mefisto geometria multi-runtime, labels por runtime, `--kind`, `MEFISTO_RUNTIME` e idempotencia por filas faltantes; la rama consumidor fuerza explicitamente una unica fila Claude.
- Los workspaces consumidores vigentes usan labels legacy `planner`/`ejecucion`. Agregar filas por labels `[runtime]` sin transicion duplicaria la fila Claude.
- MEF-ADR-0053 exige Claude arriba/OpenCode abajo, pero limita el primer corte publicado a `/mefisto:tooling`; no autoriza migrar el planner completo para llenar el pane OpenCode.
- El diagnostico de #1092 ya compara manifiestos sin leer auth/config de runtime y expresa estados aligned, drift, metadata missing/invalid y runtime ausente.
- #1059/#1063 no son dependencias tecnicas para crear filas: hooks y visor se conectan despues mediante #1065 y la certificacion #1066.

## Decisiones

- Se crea #1147 para normalizar primero la unica fila Claude de consumidores nuevos/existentes: labels, nombres y runtime explicito, sin agregar OpenCode.
- #1064 depende de #1147 y queda `estado:listo`/`bloqueado`; elimina las dependencias directas de #1059/#1063.
- Los consumidores reciben exactamente dos filas en orden fijo; `MEFISTO_RUNTIMES` sigue siendo una configuracion exclusiva del propio repo Mefisto.
- El pane planner Claude conserva `mefisto:planner`; el pane de rol planner OpenCode lanza el runtime sin `--agent` y declara la degradacion, porque ese agente no esta en el corte vertical.
- Runtime queda en labels; version/commit se muestran mediante el diagnostico, no se incorporan al label para evitar duplicados tras upgrades.
- Drift o metadata ausente se reportan sin activar/seleccionar otra release ni destruir la fila sana; #1066 sigue siendo el gate fail-closed de certificacion.

## Descartado

- Montar OpenCode directamente sobre labels legacy: rompe idempotencia y duplica panes.
- Lanzar `mefisto:planner` bajo OpenCode: ese agente no existe en la distribucion del corte tooling.
- Migrar el planner publicado dentro de #1064: contradice el rollout corte-vertical-primero.
- Poner version/commit en labels de panes: cada upgrade aparentaria una fila nueva.
- Mantener #1059/#1063 como dependencias del layout: mezcla observabilidad con composicion del workspace.

## Preguntas abiertas

- Una migracion futura del planner publicado debera retirar la degradacion del pane OpenCode sin cambiar de nuevo la identidad visual de la fila.
- #1065 debe usar `MEFISTO_RUNTIME`/labels normalizados para separar pools y conectar los visores correctos.

## Referencias

Issues creados: #1147 `Normalizar la fila Claude de Herdr en consumidores`.

Drafts refinados: #1064 `Montar filas Claude y OpenCode en Herdr para consumidores`.

Fuentes: `scripts/herdr-workspace.sh`, `scripts/tests/test-herdr-workspace.sh`, `src/published/scripts/diagnose-installation-identity.sh`, MEF-ADR-0019/0049/0050/0053 y issues #958/#1092.
