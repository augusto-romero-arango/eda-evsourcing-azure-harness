---
fecha: 2026-08-11
hora: 09:45
sesion: mefisto-planner
tema: refinamiento del issue 601 - nombre del plugin sin calificar en update-plugin.sh
---

## Contexto

El draft #601 reportaba desde el consumidor Bitakora.ControlAsistencia que `/mefisto:upgrade`
aborta en el paso de update: `scripts/update-plugin.sh:286` invoca `claude plugin update
mefisto --scope user` sin calificar el nombre con su marketplace, y el CLI exige
`mefisto@<marketplace>`. El draft traia la causa ya aislada en campo (tabla A/B/C separando
nombre vs scope) y una duda abierta: que scope deberia usar el script.

Tambien se respondio una consulta previa: el trabajo de las tres islas de eventos
(MEF-ADR-0039, issues #543/#544/#546/#548/#549) ya esta en `domain-scaffolder` en main,
pero sin release — v0.20.0 es del 2026-08-05 y hay ~22 fragmentos pendientes en
`changelog.d/` esperando `/mefisto-release`.

## Descubrimientos

- La causa raiz del #601 se confirmo en el codigo del harness: el script ya deriva
  `$marketplace_name` (sin hardcode, compatible con forks via `repoSlug`) y lo usa dos
  lineas arriba para el `marketplace update`; solo el update del plugin quedo sin calificar.
- `scripts/tests/test-update-plugin.sh` cubre deliberadamente solo el modo poda, sin
  invocar el CLI: el camino del update no tenia red de tests.
- El scope `user` es doctrina del README (requisito de pipelines: los agentes corren en un
  worktree hermano que scope `project` no carga), no una eleccion arbitraria del script.

## Decisiones

- **Scope: se mantiene `--scope user`** (fix minimo). Un consumidor solo-`project` esta
  fuera de doctrina; `/upgrade` no lo acomoda, pero el mensaje de ERROR enriquecido le
  da el remedio correcto (reinstalar a scope `user`).
- El fix trae su propia red: extender el test con stub de `claude` en PATH + cache fixture,
  con el marketplace del assert derivado del fixture (clava tambien la compatibilidad fork).
- #601 promovido a `estado:listo` con 4 CAs; contexto de campo preservado en `## Origen`.

## Descartado

- Detectar el scope declarado o actualizar ambos scopes: parsing y combinatoria sin
  beneficio en la instalacion canonica; ademas maquillaria el problema real de un
  consumidor solo-`project` en vez de exponerlo.

## Preguntas abiertas

- La release pendiente: 22+ fragmentos en `changelog.d/` (#543-#601 cuando mergeen) sin
  consolidar desde v0.20.0. El usuario no pidio planearla aun.

## Referencias

Issues creados: ninguno (refinado: #601)
