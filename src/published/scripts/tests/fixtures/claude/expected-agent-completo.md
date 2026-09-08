---
name: "agent-completo"
description: "Lee: \"edita\"."
tools: "Read, Glob, Grep, Edit, Write, Bash, WebFetch, WebSearch, Skill, Task, mcp__microsoft-learn__*, mcp__terraform__*"
skills: ["projections"]
model: "sonnet"
---
<!-- GENERADO por prueba desde fixture. No editar a mano. -->
```bash
mefisto_claude_root=''
mefisto_claude_candidate="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$mefisto_claude_candidate" ]; then
    mefisto_claude_cursor="$PWD"
    while :; do
        if [ -f "$mefisto_claude_cursor/.mefisto/pipeline/.plugin-root" ]; then
            mefisto_claude_candidate="$(< "$mefisto_claude_cursor/.mefisto/pipeline/.plugin-root")"
            break
        fi
        if [ "$mefisto_claude_cursor" = / ]; then break; fi
        mefisto_claude_cursor="$(cd "$mefisto_claude_cursor/.." && pwd -P)"
    done
fi
if [ -z "$mefisto_claude_candidate" ]; then
    mefisto_claude_cursor="$PWD"
    while :; do
        if [ -f "$mefisto_claude_cursor/.claude/pipeline/.plugin-root" ]; then
            mefisto_claude_candidate="$(< "$mefisto_claude_cursor/.claude/pipeline/.plugin-root")"
            break
        fi
        if [ "$mefisto_claude_cursor" = / ]; then break; fi
        mefisto_claude_cursor="$(cd "$mefisto_claude_cursor/.." && pwd -P)"
    done
fi
case "$mefisto_claude_candidate" in
    /*) ;;
    *) printf '%s\n' 'ERROR Claude: no se encontro una raiz absoluta valida; reabra o reinstale el plugin.' >&2; exit 1 ;;
esac
mefisto_claude_root="$(cd "$mefisto_claude_candidate" 2>/dev/null && pwd -P)" || {
    printf '%s\n' 'ERROR Claude: la raiz del plugin no existe; reabra o reinstale el plugin.' >&2; exit 1;
}
if ! jq -e '
  .name == "mefisto" and
  (.version | type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$"))
' "$mefisto_claude_root/.claude-plugin/plugin.json" >/dev/null 2>&1; then
    printf '%s\n' 'ERROR Claude: metadata del plugin invalida; reabra o reinstale el plugin.' >&2; exit 1
fi
MEFISTO_PACKAGE_ROOT="$mefisto_claude_root"
export MEFISTO_PACKAGE_ROOT
```
Antes de continuar, aborta si existe `src/internal/scripts/generate-internal-adapters.sh`: ese directorio es el repositorio de Mefisto, no un consumidor.
Rutas: .mefisto/harness.config.json y ${MEFISTO_PACKAGE_ROOT}.
.mefisto/pipeline/logs/con-espacio.log
Ejecuta ${MEFISTO_PACKAGE_ROOT}/scripts/prueba.sh "$ARGUMENTS con espacios" ahora.
Consulta /mefisto:otra-orden.
Guard inline: Antes de continuar, aborta si existe `src/internal/scripts/generate-internal-adapters.sh`: ese directorio es el repositorio de Mefisto, no un consumidor. Fin.
