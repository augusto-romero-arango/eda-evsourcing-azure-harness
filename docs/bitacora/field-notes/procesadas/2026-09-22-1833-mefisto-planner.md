---
fecha: 2026-09-22
hora: 18:33
sesion: mefisto-planner
tema: Refinar #1563 (confirmar arranque del runner en herdr-pipeline.sh)
---

## Descubrimientos
- `dispatch_to_pane` y `cmd_parallel` reportan exito solo porque `herdr pane run` devolvio 0; nada confirma que `--_pane-runner` arranco.
- El porte interno `mefisto-herdr-pipeline.sh` tiene el mismo patron.

## Decisiones
- Opcion A: marcador de arranque con token unico + timeout; reintento unico en pane nuevo (split); fallo visible si no confirma. Paralelo: confirmacion sin reintento.
- Marcador por archivo preferido a `herdr pane wait-output` (independiente de la pantalla, simulable en stub).

## Descartado
- Fallar sin reintento (B); no reutilizar nunca panes (C, rompe #799).

## Referencias
Issues refinados: #1563. Draft creado: #1571 (porte interno, bloqueado por #1563).
