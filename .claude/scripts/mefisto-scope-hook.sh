#!/usr/bin/env bash
# mefisto-scope-hook.sh -- Hook PostToolUse (matcher Edit|Write) del pipeline
# interno de Mefisto (issue #523, paso 2 del plan de velocidad -- ver #481/#482).
#
# Avisa EN EL INSTANTE en que un Edit/Write cae fuera del scope permitido para
# el propio plugin, gratis (bash deterministico, cero turnos), para que el
# agente no tenga motivo para inspeccionar el arbol preventivamente contra un
# gate que validate_mefisto_scope_changes ya evalua al final de cada stage.
# Este hook es feedback temprano, NO reemplaza ese gate final.
#
# Lee el input JSON del tool call por stdin (docs de hooks de Claude Code,
# https://docs.claude.com/en/docs/claude-code/hooks): extrae tool_input.file_path,
# lo relativiza a la raiz del repo y lo valida con is_path_in_mefisto_scope
# (_mefisto-common.sh). Semantica de PostToolUse + exit 2: el tool ya corrio (no
# se puede bloquear retroactivamente), pero el stderr se muestra a Claude como
# feedback del tool call -- exactamente lo que sustituye la auto-inspeccion.
#
# Degrada seguro (exit 0) ante cualquier entrada no parseable o archivo fuera
# del worktree: este hook nunca es la fuente de verdad, solo un aviso -- el
# gate final (validate_mefisto_scope_changes) sigue siendo el juez.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_mefisto-common.sh"

command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat)"

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

case "$FILE_PATH" in
    /*) ABS_PATH="$FILE_PATH" ;;
    *)  ABS_PATH="$REPO_ROOT/$FILE_PATH" ;;
esac

case "$ABS_PATH" in
    "$REPO_ROOT"/*) REL_PATH="${ABS_PATH#"$REPO_ROOT"/}" ;;
    *) exit 0 ;;
esac

is_path_in_mefisto_scope "$REL_PATH" && exit 0

{
    echo "BLOQUEADO por el gate de scope de Mefisto: '$REL_PATH' cae fuera de la allowlist interna (is_path_in_mefisto_scope, .claude/scripts/_mefisto-common.sh)."
    echo "Rutas permitidas: commands/, skills/, agents/, scripts/, hooks/, docs/, .claude-plugin/, .claude/{commands,skills,agents,scripts}/, .claude/settings.json, changelog.d/, README.md, CHANGELOG.md, CLAUDE.md, .gitignore."
    echo "Si esta ruta deberia estar permitida, MEF-ADR-0019 seccion E exige registrarla PRIMERO en un PR aparte (is_path_in_mefisto_scope + is_path_in_consumer_blocklist) antes de poblarla -- no crees este archivo en este PR."
} >&2
exit 2
