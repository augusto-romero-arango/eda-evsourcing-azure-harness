# Smoke manual: shim `CLAUDE.md` -> `AGENTS.md`

Verificacion de sesion (no automatizable con `bash + jq`) de que ambos runtimes cargan la doctrina canonica de `AGENTS.md` tras el shim del issue #855 (MEF-ADR-0049 CA-3). El gate automatizado (`.claude/scripts/tests/test-agents-md-shim.sh`) solo valida la forma de los archivos; este smoke valida que cada runtime realmente los carga.

## Claude Code

1. Abrir el repo con Claude Code.
2. Correr `/memory` (lista los archivos de memoria cargados) o `/context`, y confirmar que `AGENTS.md` aparece importado desde `CLAUDE.md` (sintaxis `@AGENTS.md`, ver Referencias [7] en `docs/adr/mef-adr-0049-arquitectura-neutral-runtime-proveedor.md`).

## OpenCode

1. Abrir el repo con OpenCode (`opencode`).
2. Confirmar que `AGENTS.md` carga como instrucciones de proyecto (OpenCode Docs, "Rules": https://opencode.ai/docs/rules/).
3. Anotar si OpenCode ademas carga el shim `CLAUDE.md` como fallback (duplicacion inofensiva, ~4 lineas de ruido). Registrar el resultado aqui para que el issue #868 decida si excluye `CLAUDE.md` via `instructions` de `opencode.json`.

## Resultado (completar en cada corrida)

| Fecha | Runtime | `AGENTS.md` cargado | `CLAUDE.md` tambien cargado | Notas |
|---|---|---|---|---|
| 2026-09-05 | Claude Code (sesion headless del pipeline de #855) | si | n/a (es el archivo que dispara el import) | El import `@AGENTS.md` resolvio: el runtime inyecto el contenido integro de `AGENTS.md` como project instructions. Falta la comprobacion interactiva con `/memory` |
| _pendiente_ | Claude Code (sesion interactiva) | | | |
| 2026-09-06 | OpenCode 1.18.29 (issue #868) | si | no | `Instruction.systemPaths` recorre los candidatos de proyecto `["AGENTS.md", "CLAUDE.md", "CONTEXT.md"]` y corta (`break`) en el primero con alguna coincidencia: con `AGENTS.md` en la raiz, `CLAUDE.md` **no se lee**. Por eso `opencode.json` no declara `instructions` |
