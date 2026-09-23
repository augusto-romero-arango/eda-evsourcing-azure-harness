---
fecha: 2026-09-07
hora: 21:40
sesion: mefisto-planner
tema: Refinamiento del contrato neutral publicado
---

## Contexto

Se solicitó refinar el issue #1047. El issue ya estaba en `estado:listo`, pero sus
dependencias #1042/#1043 habían cerrado y el contrato todavía dejaba sin decidir cómo
representar acceso MCP con mínimo privilegio.

## Descubrimientos

- Los 20 agentes y 26 comandos publicados siguen escritos directamente en formato Claude
  Code y conservan acoplamientos a modelos/tools, `claude --agent`, `CLAUDE_PLUGIN_ROOT`,
  cache de marketplace y rutas `.claude/`.
- `src/published/` continúa sin contenido, pero #1043 ya registró `src/published/`,
  `src/runtime/` y `dist/` en los gates de scope; #1047 ya no tiene dependencia abierta.
- El contrato interno es un precedente mecánico útil, pero sus ids `mefisto-*`, guard inverso
  y allowlist interna no son reutilizables como autoridad del lado consumidor.
- Una capacidad escalar `mcp` no distingue los servidores que hoy requieren `planner`
  (`microsoft-learn`) e `infra-writer` (Terraform).

## Decisiones

- Mantener #1047 como un issue homogéneo de contrato: schema, documentación, validador,
  fixtures y test verifican una sola interfaz y sus seis CAs permanecen bajo el máximo.
- Representar MCP mediante el campo `mcp`, una lista de ids lógicos por servidor; decisión
  confirmada por el usuario. Los ids iniciales son `microsoft-learn` y `terraform` y cada
  adaptador debe fallar si no dispone de mapping.
- Separar `mcp` del vocabulario escalar de `capabilities` para no conceder acceso genérico.
- Fijar ids fuente sin `mefisto-`/`mefisto:` y dejar el namespace/prefijo exclusivamente a
  los adaptadores.
- Enumerar las directivas neutrales de body y exigir el guard de consumidor en todo
  artefacto válido.
- Retirar el label `bloqueado` de #1047. #1048 permanece bloqueado correctamente mientras
  #1047 siga abierto.

## Descartado

- Reutilizar una capacidad MCP genérica: no conserva mínimo privilegio por servidor.
- Diferir la representación MCP a #1056: habría dejado incompleto el contrato que #1048
  necesita y obligado a extenderlo antes de migrar los agentes existentes.
- Partir schema y validador en issues separados: el precedente interno y el alcance actual
  permiten entregar y verificar el contrato como una unidad coherente.

## Preguntas abiertas

- Ninguna para #1047. #1048 materializará las expansiones concretas por runtime y #1056
  adaptará la configuración MCP distribuida.

## Referencias

Issues creados: ninguno.

Issue refinado: #1047 — Definir el contrato neutral de agentes y comandos publicados.
