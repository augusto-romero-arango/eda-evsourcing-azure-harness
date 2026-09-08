#!/usr/bin/env bash
# Shim temporal de compatibilidad para los pipelines internos (issue #1045).
# Conserva el default interno de events.log sin filtrarlo al nucleo comun.
_internal_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_has_events_log=false
for _arg in "$@"; do
    [ "$_arg" = "--events-log" ] && _has_events_log=true
done
if [ "$_has_events_log" = false ]; then
    source "$_internal_dir/lib/mefisto-state.sh"
    set -- "$@" --events-log "$(mefisto_state_path events.log)"
fi
exec "$(cd "$_internal_dir/../../.." && pwd)/src/runtime/mefisto-run-agent.sh" "$@"
