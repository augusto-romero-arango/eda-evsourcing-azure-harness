# Workspace Herdr de consumidores

`scripts/herdr-workspace.sh` monta siempre dos filas en un consumidor: Claude
arriba y OpenCode abajo. Sus identidades estables son
`planner [claude]`/`ejecucion [claude]` y
`planner [opencode]`/`ejecucion [opencode]`; cada pane hereda su
`MEFISTO_RUNTIME` y usa el `--kind` correspondiente. Claude conserva
`--agent mefisto:planner`; OpenCode abre el planner publicado con
`--agent planner` (nombre con que la proyeccion global expone
`agents/planner.md`). Si la release OpenCode activa no proyecta ese agente
(por ejemplo, una anterior a #1640), el pane arranca sin `--agent` y el script
imprime un aviso `DEGRADACION VISIBLE` con la version activa que remite a
`/mefisto:upgrade`. En el repo de Mefisto ambas filas usan `mefisto-planner`.
El script se distribuye en `dist/{claude,opencode}/scripts/`.

Al reenfocar un workspace creado antes de esta convencion, el script detecta
los labels exactos legacy `planner` y `ejecucion` y los renombra in-place. No
cierra ni divide panes, no reinicia agentes y no modifica el cwd. La migracion
se completa por rol para poder reintentarse si un rename anterior quedo a
medias. Si falta el planner, un mismo rol esta duplicado o conserva a la vez
su label legacy y normalizado, informa un warning accionable y conserva el
layout existente. Si hubo una normalizacion, la invocacion solo enfoca: una
ejecucion posterior, ya sobre los dos labels Claude normalizados, agrega
solamente la fila OpenCode. Esta separacion evita dividir una topologia legacy
parcial o ambigua.

Antes de montar o enfocar, el script consulta el diagnostico de identidad con
la raiz Claude derivada de su propio directorio y la release OpenCode activa.
Muestra version y commit disponibles; drift, metadata ausente o runtime ausente
son degradaciones accionables que no activan ni seleccionan releases y no
impiden conservar la otra fila.

La cobertura con el stub de Herdr esta en
`scripts/tests/test-herdr-workspace.sh`: verifica argv, paths con espacios,
diagnosticos aligned/drift/metadata ausente/runtime ausente, fallos de arranque,
migracion legacy, ambiguedad e idempotencia de ambas filas.
