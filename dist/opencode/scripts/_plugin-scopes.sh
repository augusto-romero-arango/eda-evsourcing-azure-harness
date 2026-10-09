#!/usr/bin/env bash
# _plugin-scopes.sh -- scopes de instalacion de mefisto que aplican al proyecto activo
# (issue #2130). Sourceado por update-plugin.sh y upgrade.sh; no se ejecuta directo.
#
# Precedencia de Claude Code cuando el mismo plugin esta en varios scopes:
# local > project > user (https://code.claude.com/docs/en/discover-plugins,
# "Choose an install scope"). Actualizar solo 'user' deja vieja la instalacion que
# la sesion realmente carga. 'managed' queda fuera: no lo controla el usuario.
#
# Todas las funciones degradan en silencio: sin jq o sin salida JSON valida del CLI,
# _scopes_aplicables devuelve 'user' (comportamiento previo) y _instalacion_efectiva
# no devuelve nada.

# JSON de 'claude plugin list --json' (vacio si no hay jq, el CLI falla o no es un array).
_plugin_list_json() {
    local out
    command -v jq >/dev/null 2>&1 || return 0
    out=$(claude plugin list --json 2>/dev/null) || return 0
    printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || return 0
    printf '%s' "$out"
}

# _instalaciones_aplicables <marketplace> <json> <toplevel>: una linea por instalacion de
# mefisto@<marketplace> en scope user o en project/local con projectPath == toplevel.
# Formato: scope<TAB>version<TAB>installPath
_instalaciones_aplicables() {
    local mkt="$1" json="$2" top="$3"
    [ -n "$json" ] || return 0
    printf '%s' "$json" | jq -r --arg id "mefisto@$mkt" --arg top "$top" '
        .[] | select(.id == $id and
            (.scope == "user" or
             ((.scope == "project" or .scope == "local") and .projectPath == $top)))
        | [.scope, (.version // ""), (.installPath // "")] | @tsv' 2>/dev/null
}

# _scopes_aplicables <marketplace> <json> <toplevel>: un scope por linea; 'user' si no hay nada.
_scopes_aplicables() {
    local scopes
    scopes=$(_instalaciones_aplicables "$@" | cut -f1 | sort -u)
    if [ -z "$scopes" ]; then echo user; else printf '%s\n' "$scopes"; fi
}

# _instalacion_efectiva <marketplace> <json> <toplevel>: la de mayor precedencia
# (local > project > user), como scope<TAB>version<TAB>installPath. Vacio si no hay datos.
_instalacion_efectiva() {
    local lista s linea
    lista=$(_instalaciones_aplicables "$@")
    for s in local project user; do
        linea=$(printf '%s\n' "$lista" | awk -F'\t' -v s="$s" '$1 == s {print; exit}')
        if [ -n "$linea" ]; then printf '%s\n' "$linea"; return 0; fi
    done
}

# _actualizar_scopes <marketplace> <json> <toplevel>: 'claude plugin update' una vez por scope aplicable.
_actualizar_scopes() {
    local mkt="$1" scope
    while IFS= read -r scope; do
        [ -n "$scope" ] || continue
        echo "Actualizando el plugin mefisto@$mkt (scope $scope)..."
        if ! claude plugin update "mefisto@$mkt" --scope "$scope"; then
            echo "ERROR: 'claude plugin update mefisto@$mkt --scope $scope' fallo." >&2
            return 1
        fi
    done < <(_scopes_aplicables "$@")
}
