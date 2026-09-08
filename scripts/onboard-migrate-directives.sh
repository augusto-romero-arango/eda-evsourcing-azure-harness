#!/usr/bin/env bash
# onboard-migrate-directives.sh --- Migración conservadora de directivas (issue #1080).
# Uso: onboard-migrate-directives.sh --preview | --apply (cwd = raíz del consumidor).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:---preview}"

if [ "$#" -gt 1 ] || { [ "$MODE" != "--preview" ] && [ "$MODE" != "--apply" ]; }; then
    echo "Uso: $(basename "$0") --preview | --apply" >&2
    exit 2
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /onboard no aplica al repo de Mefisto." >&2
    echo "       scripts/onboard-migrate-directives.sh es del plugin publicado y solo aplica al consumidor." >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq no esta instalado. Requerido para leer harness.config.json." >&2
    exit 1
fi

source "$SCRIPT_DIR/_pipeline-common.sh"
source "$SCRIPT_DIR/onboard-diagnose.sh"
if ! load_harness_config >/dev/null; then
    echo "ERROR: no se modifico ninguna directiva porque el config efectivo no es valido." >&2
    exit 1
fi

AGENTS="$REPO_ROOT/AGENTS.md"
CLAUDE="$REPO_ROOT/CLAUDE.md"
CREATE_AGENTS=0
CREATE_CLAUDE=0
ADD_IMPORT=0

# Rechazar enlaces evita que una operación publicada escape del consumidor.
for destination in "$AGENTS" "$CLAUDE"; do
    if [ -L "$destination" ]; then
        echo "ERROR: $(basename "$destination") es un enlace simbólico; no se siguen destinos fuera del consumidor." >&2
        echo "       Reemplázalo conscientemente por un archivo regular y reintenta; no se modificó nada." >&2
        exit 1
    fi
    if [ -e "$destination" ] && [ ! -f "$destination" ]; then
        echo "ERROR: $(basename "$destination") existe pero no es un archivo regular; no se modificó nada." >&2
        exit 1
    fi
done

# Preflight completo: ningún destino se toca antes de poder ejecutar todas las
# acciones deterministas. Un AGENTS existente e incompleto no se fusiona.
_check_consumer_directives "$AGENTS" "$CLAUDE"
if [ -e "$AGENTS" ]; then
    if [ ! -r "$AGENTS" ]; then
        echo "ERROR: AGENTS.md existe pero no es legible; no se modifico nada." >&2
        exit 1
    fi
    if [ "$AGENTS_DIRECTIVES_STATE" != "OK" ]; then
        echo "ERROR: AGENTS.md existe pero esta incompleto; no se fusiona por heurística." >&2
        echo "       Complétalo manualmente con \"Tokens del harness\" y \"Verificación de fuentes\", y reintenta." >&2
        exit 1
    fi
else
    [ -w "$REPO_ROOT" ] || { echo "ERROR: no hay permiso para crear AGENTS.md; no se modifico nada." >&2; exit 1; }
    CREATE_AGENTS=1
fi

if [ -e "$CLAUDE" ]; then
    if [ ! -r "$CLAUDE" ]; then
        echo "ERROR: CLAUDE.md existe pero no es legible; no se modifico nada." >&2
        exit 1
    fi
    if [ "$CLAUDE_BRIDGE_HAS_IMPORT" -eq 0 ]; then
        [ -w "$CLAUDE" ] || { echo "ERROR: CLAUDE.md no es escribible; no se modifico nada." >&2; exit 1; }
        ADD_IMPORT=1
    fi
else
    [ -w "$REPO_ROOT" ] || { echo "ERROR: no hay permiso para crear CLAUDE.md; no se modifico nada." >&2; exit 1; }
    CREATE_CLAUDE=1
fi

echo "Plan de migración de directivas:"
[ "$CREATE_AGENTS" -eq 1 ] && echo "  - Crear AGENTS.md con las dos secciones contractuales y tokens derivados de $HARNESS_CONFIG_PATH." || echo "  - Conservar AGENTS.md completo sin cambios."
if [ "$CREATE_CLAUDE" -eq 1 ]; then
    echo "  - Crear CLAUDE.md con el puente mínimo @AGENTS.md."
elif [ "$ADD_IMPORT" -eq 1 ]; then
    echo "  - Añadir una línea @AGENTS.md a CLAUDE.md, preservando todo su contenido."
else
    echo "  - Conservar CLAUDE.md: ya contiene el puente exacto."
fi
[ "$CLAUDE_BRIDGE_HAS_LEGACY" -eq 1 ] && echo "  - AVISO: CLAUDE.md conserva secciones contractuales legacy duplicadas; retíralas manualmente."

if [ "$MODE" = "--preview" ]; then
    echo "Previsualización: no se escribió ningún archivo. Usa --apply solo tras la confirmación explícita de /onboard."
    exit 0
fi

TMP_AGENTS=""
TMP_CLAUDE=""
cleanup() {
    [ -z "$TMP_AGENTS" ] || rm -f "$TMP_AGENTS"
    [ -z "$TMP_CLAUDE" ] || rm -f "$TMP_CLAUDE"
}
trap cleanup EXIT HUP INT TERM

if [ "$CREATE_AGENTS" -eq 1 ]; then
    TMP_AGENTS=$(mktemp "$REPO_ROOT/.onboard-agents.XXXXXX") || {
        echo "ERROR: no se pudo preparar AGENTS.md; no se modificó nada." >&2
        exit 1
    }
    if ! cat > "$TMP_AGENTS" <<EOF
### Tokens del harness

- **RootNamespace**: $HARNESS_NAMESPACE_PREFIX
- **SolutionFile**: $HARNESS_SOLUTION_FILE
- **ProjectDisplayName**: $HARNESS_PROJECT_NAME
- **BoundedContext**: $HARNESS_BC_NAME
- **BoundedContextDomains**: ${HARNESS_BC_DOMAINS// /, }

### Verificación de fuentes (obligatorio para agentes)

Antes de proponer o aplicar un ajuste técnico, verifica el enfoque contra la
**documentación oficial y vigente** de las tecnologías del stack (.NET, Azure
Functions, Marten, Wolverine, Azure Service Bus, Terraform, …). No te apoyes en
conocimiento memorizado: puede estar desactualizado. Al afirmar una best practice
o recomendación, **cita la fuente** (URL oficial, versión del paquete, ADR). Si un
dato no pudiste verificarlo contra la fuente, decláralo como *no verificado* en
tu propuesta en vez de darlo por cierto.
EOF
    then
        echo "ERROR: no se pudo preparar AGENTS.md; no se modificó ningún destino." >&2
        exit 1
    fi
    chmod 644 "$TMP_AGENTS" || {
        echo "ERROR: no se pudieron preparar los permisos de AGENTS.md; no se modificó ningún destino." >&2
        exit 1
    }
fi

if [ "$CREATE_CLAUDE" -eq 1 ] || [ "$ADD_IMPORT" -eq 1 ]; then
    TMP_CLAUDE=$(mktemp "$REPO_ROOT/.onboard-claude.XXXXXX") || {
        echo "ERROR: no se pudo preparar CLAUDE.md; no se modificó ningún destino." >&2
        exit 1
    }
    if [ "$ADD_IMPORT" -eq 1 ]; then
        cp -p "$CLAUDE" "$TMP_CLAUDE" || {
            echo "ERROR: no se pudo copiar CLAUDE.md; no se modificó ningún destino." >&2
            exit 1
        }
        [ -s "$TMP_CLAUDE" ] && printf '\n' >> "$TMP_CLAUDE"
    else
        chmod 644 "$TMP_CLAUDE" || {
            echo "ERROR: no se pudieron preparar los permisos de CLAUDE.md; no se modificó ningún destino." >&2
            exit 1
        }
    fi
    printf '@AGENTS.md\n' >> "$TMP_CLAUDE" || {
        echo "ERROR: no se pudo preparar el puente CLAUDE.md; no se modificó ningún destino." >&2
        exit 1
    }
fi

if [ "$CREATE_AGENTS" -eq 1 ]; then
    mv "$TMP_AGENTS" "$AGENTS" || {
        echo "ERROR: no se pudo crear AGENTS.md; no se modificó ningún destino." >&2
        exit 1
    }
    TMP_AGENTS=""
fi
if [ -n "$TMP_CLAUDE" ]; then
    if ! mv "$TMP_CLAUDE" "$CLAUDE"; then
        [ "$CREATE_AGENTS" -eq 0 ] || rm -f "$AGENTS"
        echo "ERROR: no se pudo actualizar CLAUDE.md; se revirtió la creación de AGENTS.md." >&2
        exit 1
    fi
    TMP_CLAUDE=""
fi

echo "OK: migración conservadora aplicada."
[ "$CLAUDE_BRIDGE_HAS_LEGACY" -eq 1 ] && echo "AVISO: las secciones contractuales legacy de CLAUDE.md siguen allí y deben retirarse manualmente."
exit 0
