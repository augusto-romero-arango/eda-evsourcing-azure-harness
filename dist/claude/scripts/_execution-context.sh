#!/usr/bin/env bash
# Callbacks sourceables para pipelines publicados (MEF-ADR-0055). Hacer source no
# tiene efectos: solo define funciones. Los resultados viajan en variables, nunca
# por stdout del source ni por el entorno global de tmux:
#   MEFISTO_EXECUTION_ENABLED  0|1
#   MEFISTO_EXECUTION_CONTEXT  ruta del contexto (solo ruta)
#   MEFISTO_EXECUTION_DIGEST   contractDigest (solo digest)
# La presencia de las variables no acredita nada: siempre se valida.

_EC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
_EC_OWNED=0
_EC_ROOT=""
_EC_RUN=""
_EC_CTX=""

_ec_cli() { "${EC_EXECUTION_CONTEXT_CMD:-$_EC_LIB_DIR/execution-context.sh}" "$@"; }

_ec_reset() {
    MEFISTO_EXECUTION_ENABLED=0
    MEFISTO_EXECUTION_CONTEXT=""
    MEFISTO_EXECUTION_DIGEST=""
    _EC_OWNED=0; _EC_ROOT=""; _EC_RUN=""; _EC_CTX=""
}

_ec_publish() { # respuesta JSON del CLI
    MEFISTO_EXECUTION_CONTEXT="$(printf '%s' "$1" | jq -r '.path // empty')"
    MEFISTO_EXECUTION_DIGEST="$(printf '%s' "$1" | jq -r '.digest // empty')"
    MEFISTO_EXECUTION_ENABLED=1
}

_ec_has_config() { [ -f "$1/.mefisto/harness.config.json" ] || [ -f "$1/.claude/harness.config.json" ]; }

# published_execution_open <pipeline-kind> <project-root> <package-root>
# Retorna 0 cuando el pipeline puede continuar (legacy o contexto valido) y 1 cuando
# no debe admitir trabajo controlado. Un contexto transportado que no valida nunca
# degrada a legacy.
published_execution_open() {
    local kind="${1:-}" project_root="${2:-}" package_root="${3:-}"
    # kind "root:<comando>" abre la ejecucion de un orquestador (sequential/parallel
    # o el wrapper de un multiplexor): sin pipelineKind propio, el alcance es el del
    # comando raiz y los hijos reservados lo reducen (issue #1861).
    local root_kind="" pipeline_kind="$kind"
    case "$kind" in root:?*) root_kind="${kind#root:}"; pipeline_kind="" ;; esac
    local rt="${MEFISTO_RUNTIME:-}"
    local ctx_path="${MEFISTO_EXECUTION_CONTEXT:-}" ctx_digest="${MEFISTO_EXECUTION_DIGEST:-}"
    _ec_reset
    [ -n "$kind" ] && [ -n "$project_root" ] && [ -n "$package_root" ] || return 1
    export EC_PACKAGE_ROOT="$package_root"
    local out rc

    if [ -n "$ctx_path" ] || [ -n "$ctx_digest" ]; then
        # Contexto transportado: se valida contra la raiz aprobada del propio contexto,
        # no contra la configuracion del worktree.
        [ -n "$ctx_path" ] && [ -n "$ctx_digest" ] || { _ec_reset; return 1; }
        case "$ctx_path" in
            */.mefisto/pipeline/autonomy/runs/*/contexts/*.json) ;;
            *) _ec_reset; return 1 ;;
        esac
        local base="${ctx_path%/.mefisto/pipeline/autonomy/runs/*}"
        local tail="${ctx_path#*/.mefisto/pipeline/autonomy/runs/}"
        local run="${tail%%/*}" ctx="${tail##*/}"; ctx="${ctx%.json}"
        local req
        req="$(jq -cn --arg r "$base" --arg run "$run" --arg c "$ctx" --arg d "$ctx_digest" --arg p "$pipeline_kind" --arg rt "$rt" \
            '{schemaVersion:1,projectRoot:$r,runId:$run,contextId:$c,digest:$d,pipelineKind:$p} + (if $rt=="" then {} else {runtime:{id:$rt}} end)')"
        out="$(printf '%s' "$req" | _ec_cli validate)"; rc=$?
        if [ "$rc" -ne 0 ]; then _ec_reset; return 1; fi
        if [ "$(printf '%s' "$out" | jq -r '.state // empty')" = prepared ]; then
            req="$(printf '%s' "$req" | jq -c --argjson pid "$$" '. + {ownerPid:$pid}')"
            out="$(printf '%s' "$req" | _ec_cli attach)"; rc=$?
            [ "$rc" -eq 0 ] || { _ec_reset; return 1; }
        fi
        _ec_publish "$out"
        MEFISTO_EXECUTION_CONTEXT="$ctx_path"
        _EC_ROOT="$base"; _EC_RUN="$run"; _EC_CTX="$ctx"
        return 0
    fi

    # Sin contexto: runtime legacy o sin configuracion conservan el flujo previo.
    case "$rt" in ''|claude) return 0 ;; esac
    _ec_has_config "$project_root" || return 0
    local root_command
    if [ -n "$root_kind" ]; then
        root_command="$(jq -r --arg c "$root_kind" 'if (.roots | has($c)) then $c else empty end' "$package_root/src/published/contract/agent-execution.json" 2>/dev/null)"
    else
        root_command="$(jq -r --arg k "$kind" '[.roots | to_entries[] | select(.value | index($k)) | .key] | first // empty' "$package_root/src/published/contract/agent-execution.json" 2>/dev/null)"
    fi
    [ -n "$root_command" ] || return 1
    local stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    local run="run-$stamp" ctx="ctx-$stamp"
    out="$(jq -cn --arg r "$project_root" --arg run "$run" --arg c "$ctx" --arg rc "$root_command" --arg k "$pipeline_kind" --arg rt "$rt" --arg lease "lease-$stamp" \
        '{schemaVersion:1,projectRoot:$r,runId:$run,contextId:$c,rootCommand:$rc,pipelineKind:$k,source:"pipeline",runtime:{id:$rt,version:(env.MEFISTO_RUNTIME_VERSION // "unknown")},leaseId:$lease}' | _ec_cli prepare)"; rc=$?
    [ "$rc" -eq 0 ] || { _ec_reset; return 1; }
    if [ "$(printf '%s' "$out" | jq -r '.status // empty')" = disabled ]; then return 0; fi
    local digest; digest="$(printf '%s' "$out" | jq -r '.digest // empty')"
    out="$(jq -cn --arg r "$project_root" --arg run "$run" --arg c "$ctx" --arg d "$digest" --argjson pid "$$" \
        '{schemaVersion:1,projectRoot:$r,runId:$run,contextId:$c,digest:$d,ownerPid:$pid}' | _ec_cli attach)"; rc=$?
    [ "$rc" -eq 0 ] || { _ec_reset; return 1; }
    _ec_publish "$out"
    _EC_OWNED=1; _EC_ROOT="$project_root"; _EC_RUN="$run"; _EC_CTX="$ctx"
    return 0
}

# published_execution_close <outcome>
# Cierra solo el uso propio (contexto preparado por este proceso). Un contexto
# transportado, sus hijos y las identidades unknown se conservan.
published_execution_close() {
    local outcome="${1:-succeeded}"
    [ "${MEFISTO_EXECUTION_ENABLED:-0}" = 1 ] && [ "$_EC_OWNED" = 1 ] || return 0
    case "$outcome" in succeeded|failed|aborted|held) ;; *) outcome=failed ;; esac
    jq -cn --arg r "$_EC_ROOT" --arg run "$_EC_RUN" --arg c "$_EC_CTX" --arg d "$MEFISTO_EXECUTION_DIGEST" --arg o "$outcome" \
        '{schemaVersion:1,projectRoot:$r,runId:$run,contextId:$c,digest:$d,outcome:$o}' | _ec_cli finish >/dev/null
    local rc=$?
    _EC_OWNED=0
    return "$rc"
}
