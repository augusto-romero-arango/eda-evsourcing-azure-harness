---
fecha: 2026-08-26
hora: 16:34
sesion: mefisto-planner
tema: refinamiento del draft 706 (gate de projections en el modo --parallel de tmux)
---

## Contexto

Continuacion de la sesion del dia (field notes 2026-08-26-1443): quedaba un
solo draft abierto, #706, detectado durante el port de --parallel a herdr
(#705).

## Descubrimientos

- El help de `tmux-pipeline.sh` promete serializacion de `tipo:projection` en
  `--parallel`, pero `cmd_parallel` lanza cada issue directo en su pane sin
  pasar por el scheduler de `parallel-pipeline.sh` (`can_launch_now`, issue
  #372): la promesa es falsa en ese camino.
- herdr ya resolvio el mismo problema en #705 con un gate que rechaza lotes
  con >=2 projections (mensaje apuntando a /sequential o parallel-pipeline.sh).

## Decisiones

- **#706** (listo, bug): opcion 2 — replicar el gate de herdr en
  `cmd_parallel` (copia local, mismo texto de error, aborto antes de crear la
  sesion tmux) + corregir el help para decir la verdad. 4 CAs.

## Descartado

- Opcion 1 (serializacion real entre panes via spinlock): duplicaria un
  scheduler que ya existe a un pane de distancia.
- Opcion 3 sola (solo corregir el help): dejaba viva la colision de dos PRs
  read-side sobre los mismos archivos del worker (MEF-ADR-0034).

## Preguntas abiertas

Ninguna.

## Referencias

Issues refinados a `estado:listo`: #706 (+`bug`)
Issues creados: ninguno
Issues cerrados: ninguno
