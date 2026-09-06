#!/usr/bin/env bash
# runtime-claude.sh -- Adaptador de runtime Claude Code (MEF-ADR-0049, issue
# #859). Unico lugar del repo (fuera de tests/fixtures/shims generados) que
# compone la invocacion `claude -p` y traduce su stream-json al JSONL neutral
# de src/internal/contract/run-events.schema.json -- ver
# src/internal/contract/README.md, "Protocolo de ejecucion y eventos".
#
# Claude Code sigue siendo runtime soportado por compatibilidad, nunca
# dependencia del nucleo (MEF-ADR-0049): ningun otro archivo del harness debe
# nombrar `claude`, `--permission-mode`, `--append-system-prompt` ni
# `--output-format stream-json` -- eso vive aqui.
#
# Implementa la interfaz de dos funciones que todo adaptador de runtime debe
# exponer (ver src/internal/contract/README.md, "Interfaz de adaptador: dos
# funciones por runtime"):
#   runtime_claude_build_cmd <agent> <cwd> <prompt_file> <model> <system_file>
#     Rellena MEFISTO_RUNTIME_CMD con el argv de `claude -p` (sin `eval`,
#     paridad con run_agent_with_watchdog -- ver #424/_mefisto-common.sh):
#     el contenido de <prompt_file> viaja como UN elemento del array bash, sin
#     volver a interpretarse. <agent>/<cwd> no participan del argv: <cwd> ya
#     lo aplica run_agent_with_watchdog (`cd "$workdir"` antes de invocar),
#     igual que runtime-fake.sh.
#   runtime_claude_translate <raw_file> <runtime_id> <model>
#     Delega en runtime-claude.jq (`jq -R -s -c -f`, mismo idiom que
#     jsonschema-lite.jq vs. validate-internal-artifacts.sh): traduce la
#     traza cruda de <raw_file> al JSONL neutral. Nunca emite `run.started`
#     -- eso lo hace mefisto-run-agent.sh directo (issue #858).
#
# Flags que compone build_cmd (CA-1): `--permission-mode bypassPermissions`
# y `--output-format stream-json --verbose` siempre; `--append-system-prompt
# "$(cat <system_file>)"` solo si <system_file> no es vacio; `--model <model>`
# solo si el runner entrego un modelo no vacio (CA-1 de #858: vacio/ausente =
# heredar, el adaptador real nunca debe ver un `--model ""`). El orden de los
# flags es irrelevante para quien los consume (el CLI real, y el stub de
# test-runtime-claude.sh que solo comprueba presencia/ausencia).
#
# Bash 3.2 + jq 1.7 (MEF-ADR-0049 CA-6): sin arrays asociativos.

# --- runtime_claude_build_cmd ------------------------------------------------

runtime_claude_build_cmd() {
    local agent="$1" cwd="$2" prompt_file="$3" model="$4" system_file="$5"
    local prompt
    prompt="$(cat "$prompt_file")"

    MEFISTO_RUNTIME_CMD=(claude -p "$prompt" --permission-mode bypassPermissions --output-format stream-json --verbose)

    if [ -n "$model" ]; then
        MEFISTO_RUNTIME_CMD+=(--model "$model")
    fi

    if [ -n "$system_file" ]; then
        MEFISTO_RUNTIME_CMD+=(--append-system-prompt "$(cat "$system_file")")
    fi
}

# --- runtime_claude_translate -------------------------------------------------

runtime_claude_translate() {
    local raw_file="$1" runtime_id="$2" model="$3"
    [ -f "$raw_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    local self_dir
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local jq_program="$self_dir/runtime-claude.jq"
    [ -f "$jq_program" ] || return 0

    jq -R -s -c \
        --arg runtime "$runtime_id" \
        --arg model_param "$model" \
        -f "$jq_program" \
        "$raw_file" 2>/dev/null
    return 0
}
