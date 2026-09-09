# Workspace Herdr de consumidores

`scripts/herdr-workspace.sh` monta en un consumidor una sola fila Claude. Su
identidad estable es `planner [claude]` y `ejecucion [claude]`; ambos panes
heredan `MEFISTO_RUNTIME=claude` y los agentes usan nombres con sufijo
`-claude`. Esto prepara la fila superior para el rollout multi-runtime de
MEF-ADR-0053 sin agregar todavia una fila OpenCode.

Al reenfocar un workspace creado antes de esta convencion, el script detecta
los labels exactos legacy `planner` y `ejecucion` y los renombra in-place. No
cierra ni divide panes, no reinicia agentes y no modifica el cwd. Si faltan,
se duplican o se mezclan labels legacy y normalizados, informa un warning
accionable y conserva el layout existente.

La cobertura con el stub de Herdr esta en
`scripts/tests/test-herdr-workspace.sh`: verifica argv, paths con espacios,
migracion completa y parcial, ambiguedad e idempotencia de una fila ya
normalizada.
