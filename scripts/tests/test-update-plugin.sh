#!/usr/bin/env bash
# test-update-plugin.sh -- Tests de scripts/update-plugin.sh (issue #531).
#
# Cubre la parte del script que no se puede probar a mano sin arriesgar el cache real de
# plugins ni invocar el CLI 'claude': la seleccion de que versiones se borran. El
# invariante que protege (CA-4) es que la poda NUNCA borra la version que la sesion
# activa tiene cargada -- si el skill en ejecucion se borra a si mismo, la sesion rompe a
# mitad de camino.
#
#   S-1: _protegidas() conserva {nueva, cargada} y, cuando la version cargada es
#        desconocida, infiere y protege la N-1 en vez de dejarla podable.
#   S-2: _podables() es la diferencia de conjuntos (todas - protegidas): poda las viejas
#        acumuladas y nunca la cargada, ni cuando la cargada NO es la N-1 (el caso de dos
#        corridas de /mefisto:upgrade en la misma sesion, que es el que rompia cuando la
#        version cargada se re-leia de .plugin-root ya reescrito).
#   S-3: _marketplace_dir() detecta el marketplace sin hardcodear su nombre (CA-2):
#        derivandolo del .plugin-root cargado, o por glob sobre el cache, y falla cuando
#        no hay ningun 'mefisto'.
#
# El script se sourcea (no se ejecuta): scripts/update-plugin.sh solo corre su main()
# cuando BASH_SOURCE[0] == $0, asi que sourcearlo aqui carga las funciones sin disparar el
# guard cwd != Mefisto ni el update real.
#
# Uso: scripts/tests/test-update-plugin.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# assert_igual <esperado> <obtenido> <descripcion>
assert_igual() {
    if [ "$1" = "$2" ]; then
        pass "$3"
    else
        fail "$3 (esperado: '$1' / obtenido: '$2')"
    fi
}

source "$REPO_ROOT/scripts/update-plugin.sh"

# Cache real observado en el issue #531 (0.10.0 ... 0.19.0), mas la version recien traida.
TODAS=$'0.10.0\n0.15.0\n0.16.0\n0.17.0\n0.18.0\n0.19.0'
TODAS_TRAS_UPDATE="$TODAS"$'\n0.20.0'

echo "[S-1] _protegidas(): conserva {nueva, cargada} e infiere la N-1 si no la conoce"

salida=$(printf '%s\n' "$TODAS_TRAS_UPDATE" | _protegidas "0.20.0" "0.19.0" "0.20.0" | tr '\n' ' ')
assert_igual "0.19.0 0.20.0 " "$salida" "protege exactamente {cargada 0.19.0, nueva 0.20.0}"

# Version cargada desconocida: se infiere la N-1 (la mas nueva distinta de la nueva).
salida=$(printf '%s\n' "$TODAS" | _protegidas "0.19.0" "" "" | tr '\n' ' ')
assert_igual "0.18.0 0.19.0 " "$salida" "sin version cargada conocida protege la N-1 (0.18.0)"

# .plugin-root apuntando a una tercera version (marker desactualizado): se suma, no se
# reemplaza -- conservar una version de mas es preferible a borrar la cargada.
salida=$(printf '%s\n' "$TODAS" | _protegidas "0.19.0" "0.17.0" "0.18.0" | tr '\n' ' ')
assert_igual "0.17.0 0.18.0 0.19.0 " "$salida" "protege la union {nueva, cargada, .plugin-root}"

echo ""
echo "[S-2] _podables(): diferencia de conjuntos, y nunca la version cargada"

salida=$(printf '%s\n' "$TODAS" | _podables 0.19.0 0.20.0 | tr '\n' ' ')
assert_igual "0.10.0 0.15.0 0.16.0 0.17.0 0.18.0 " "$salida" "poda las 5 viejas acumuladas"

# Dos corridas de /mefisto:upgrade en la misma sesion: la sesion sigue con 0.18.0 cargada
# aunque .plugin-root ya apunte a 0.19.0. 0.18.0 NO puede quedar podable.
salida=$(printf '%s\n' "$TODAS" | _podables $(printf '%s\n' "$TODAS" | _protegidas "0.19.0" "0.18.0" "0.19.0") | tr '\n' ' ')
assert_igual "0.10.0 0.15.0 0.16.0 0.17.0 " "$salida" "la cargada (0.18.0) queda fuera de la poda aunque no sea la nueva"

salida=$(printf '%s\n' $'0.19.0\n0.20.0' | _podables 0.19.0 0.20.0)
assert_igual "" "$salida" "cache ya limpio: no hay nada podable"

echo ""
echo "[S-3] _marketplace_dir(): deteccion sin hardcodear el nombre del marketplace"

FAKE_CACHE="$(mktemp -d)"
trap 'rm -rf "$FAKE_CACHE"' EXIT
mkdir -p "$FAKE_CACHE/un-fork-cualquiera/mefisto/0.19.0"

salida=$(_marketplace_dir "$FAKE_CACHE/un-fork-cualquiera/mefisto/0.19.0" "$FAKE_CACHE")
assert_igual "$FAKE_CACHE/un-fork-cualquiera/mefisto" "$salida" "lo deriva del .plugin-root cargado (fork con otro marketplace)"

salida=$(_marketplace_dir "" "$FAKE_CACHE" 2>/dev/null)
assert_igual "$FAKE_CACHE/un-fork-cualquiera/mefisto" "$salida" "cae al glob del cache cuando no hay .plugin-root"

VACIO="$(mktemp -d)"
if _marketplace_dir "" "$VACIO" >/dev/null 2>&1; then
    fail "sin ningun 'mefisto' en el cache deberia retornar 1"
else
    pass "sin ningun 'mefisto' en el cache retorna 1"
fi
rmdir "$VACIO"

echo ""
echo "===================================================================="
echo "  test-update-plugin.sh: $PASS pasaron, $FAIL fallaron"
echo "===================================================================="

[ "$FAIL" -eq 0 ]
