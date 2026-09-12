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
#   S-4: el modo ACTUALIZAR califica el nombre del plugin con su marketplace al invocar
#        el CLI (issue #601): 'claude plugin update mefisto@<marketplace> --scope user',
#        no 'mefisto' a secas -- el CLI rechaza el nombre sin calificar. Es el unico
#        bloque que corre main() end-to-end.
#
# El script se sourcea (no se ejecuta): scripts/update-plugin.sh solo corre su main()
# cuando BASH_SOURCE[0] == $0, asi que sourcearlo aqui carga las funciones sin disparar el
# guard cwd != Mefisto ni el update real. S-4 llama a main() a proposito, pero en un
# subshell con las tres fronteras peligrosas neutralizadas: cwd de mentira (git repo
# temporal sin .claude-plugin/plugin.json), cache de mentira (MEFISTO_CACHE_ROOT) y un
# stub de 'claude' antepuesto al PATH -- nunca se toca el cache real ni se invoca el CLI.
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
echo "[S-4] modo ACTUALIZAR: 'claude plugin update' recibe el nombre calificado (issue #601)"

STUB_DIR="$(mktemp -d)"
CONSUMER_DIR="$(mktemp -d)"
FAKE_CACHE_S4="$(mktemp -d)"
CLAUDE_LOG="$(mktemp)"
trap 'rm -rf "$FAKE_CACHE" "$STUB_DIR" "$CONSUMER_DIR" "$FAKE_CACHE_S4" "$CLAUDE_LOG"' EXIT

# Marketplace de mentira (los asserts de abajo lo derivan de esta variable, no lo
# hardcodean): clava que el fix tambien funciona en un fork publicado bajo otro nombre de
# marketplace, la misma regla que protege S-3.
MARKETPLACE_FIXTURE="un-fork-de-mentira"
mkdir -p "$FAKE_CACHE_S4/$MARKETPLACE_FIXTURE/mefisto/0.20.0" \
         "$FAKE_CACHE_S4/$MARKETPLACE_FIXTURE/mefisto/0.21.0"
printf '## [0.21.0]\n- nada relevante\n\n## [0.20.0]\n- nada relevante\n' \
    > "$FAKE_CACHE_S4/$MARKETPLACE_FIXTURE/mefisto/0.21.0/CHANGELOG.md"

# Stub de 'claude' en PATH: registra los argumentos recibidos y simula exito, sin tocar
# ningun cache real ni invocar el CLI de verdad.
cat > "$STUB_DIR/claude" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$CLAUDE_LOG"
exit 0
EOF
chmod +x "$STUB_DIR/claude"

# Cwd de mentira (git repo sin .claude-plugin/plugin.json) con la version 0.20.0 cargada,
# para que main() corra el modo ACTUALIZAR completo (pasos 3-5) contra el cache fixture.
mkdir -p "$CONSUMER_DIR/.claude/pipeline"
printf '%s' "$FAKE_CACHE_S4/$MARKETPLACE_FIXTURE/mefisto/0.20.0" \
    > "$CONSUMER_DIR/.claude/pipeline/.plugin-root"

(
    cd "$CONSUMER_DIR" || exit 1
    git init -q .
    export PATH="$STUB_DIR:$PATH"
    export MEFISTO_CACHE_ROOT="$FAKE_CACHE_S4"
    export CLAUDE_LOG
    main
) >/dev/null 2>&1
resultado_main=$?

assert_igual "0" "$resultado_main" "el modo actualizar corre completo (exit 0) con el stub de claude"
assert_igual "plugin marketplace update $MARKETPLACE_FIXTURE" "$(sed -n '1p' "$CLAUDE_LOG")" \
    "actualiza el catalogo del marketplace derivado del fixture"
assert_igual "plugin update mefisto@$MARKETPLACE_FIXTURE --scope user" "$(sed -n '2p' "$CLAUDE_LOG")" \
    "el update del plugin recibe el nombre calificado mefisto@<marketplace-del-fixture>"
assert_igual "$FAKE_CACHE_S4/$MARKETPLACE_FIXTURE/mefisto/0.21.0" \
    "$(cat "$CONSUMER_DIR/.claude/pipeline/.plugin-root" 2>/dev/null)" \
    "de paso, reescribe .plugin-root a la version mas nueva del cache"

echo ""
echo "[S-5] --align-opencode: usa solo el manifiesto Claude destino y valida la identidad final"

OPENCODE_ROOT="$(mktemp -d)"
OPENCODE_LOG="$(mktemp)"
ALIGN_CONSUMER="$(mktemp -d)"
ALIGN_CACHE="$(mktemp -d)"
ALIGN_STUB="$(mktemp -d)"
trap 'rm -rf "$FAKE_CACHE" "$STUB_DIR" "$CONSUMER_DIR" "$FAKE_CACHE_S4" "$CLAUDE_LOG" "$OPENCODE_ROOT" "$ALIGN_CONSUMER" "$ALIGN_CACHE" "$ALIGN_STUB" "$OPENCODE_LOG"' EXIT

ALIGN_MARKETPLACE="marketplace-alineado"
ALIGN_CLAUDE="$ALIGN_CACHE/$ALIGN_MARKETPLACE/mefisto/1.2.3"
mkdir -p "$ALIGN_CLAUDE" "$ALIGN_CONSUMER/.claude/pipeline" "$OPENCODE_ROOT"
printf '%s' "$ALIGN_CACHE/$ALIGN_MARKETPLACE/mefisto/1.2.2" > "$ALIGN_CONSUMER/.claude/pipeline/.plugin-root"
jq -n '{schemaVersion:1,runtime:"claude",version:"1.2.3",commit:"0123456789abcdef0123456789abcdef01234567"}' > "$ALIGN_CLAUDE/mefisto-manifest.json"
jq -n '{schemaVersion:1,runtime:"opencode",version:"1.2.3",commit:"0123456789abcdef0123456789abcdef01234567",minimumRuntimeVersion:"1.18.29"}' > "$OPENCODE_ROOT/mefisto-manifest.json"
cp "$REPO_ROOT/src/published/scripts/diagnose-installation-identity.sh" "$OPENCODE_ROOT/diagnose-installation-identity.sh"
chmod +x "$OPENCODE_ROOT/diagnose-installation-identity.sh"
cat > "$ALIGN_STUB/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$ALIGN_STUB/claude"
cat > "$ALIGN_STUB/mefisto-opencode" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1 ${2:-}" >> "$OPENCODE_LOG"
case "$1" in
  install|activate|project|status) exit 0 ;;
  package-root) printf '%s\n' "$OPENCODE_ROOT" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$ALIGN_STUB/mefisto-opencode"

(
    cd "$ALIGN_CONSUMER" || exit 1
    git init -q .
    export PATH="$ALIGN_STUB:$PATH" MEFISTO_CACHE_ROOT="$ALIGN_CACHE" MEFISTO_OPENCODE_LAUNCHER="$ALIGN_STUB/mefisto-opencode" OPENCODE_LOG OPENCODE_ROOT
    main --align-opencode
) >/dev/null 2>&1
assert_igual "0" "$?" "alinea una instalacion OpenCode existente"
assert_igual $'status \npackage-root \ninstall 1.2.3\nactivate 1.2.3\nproject \nstatus \npackage-root ' "$(cat "$OPENCODE_LOG")" \
    "valida el launcher, instala, activa, proyecta, consulta status y resuelve package-root con la version del manifiesto"

# Repetir la operacion completa conserva el resultado y vuelve a usar la identidad exacta.
: > "$OPENCODE_LOG"
(
    cd "$ALIGN_CONSUMER" || exit 1
    export PATH="$ALIGN_STUB:$PATH" MEFISTO_CACHE_ROOT="$ALIGN_CACHE" MEFISTO_OPENCODE_LAUNCHER="$ALIGN_STUB/mefisto-opencode" OPENCODE_LOG OPENCODE_ROOT
    main --align-opencode
) >/dev/null 2>&1
assert_igual "0" "$?" "repetir la alineacion es idempotente"
assert_igual $'status \npackage-root \ninstall 1.2.3\nactivate 1.2.3\nproject \nstatus \npackage-root ' "$(cat "$OPENCODE_LOG")" \
    "la repeticion conserva la secuencia y la version exacta"

# Sin el flag no se invoca ninguna ruta OpenCode; conserva la semantica Claude previa.
: > "$OPENCODE_LOG"
(
    cd "$ALIGN_CONSUMER" || exit 1
    export PATH="$ALIGN_STUB:$PATH" MEFISTO_CACHE_ROOT="$ALIGN_CACHE" MEFISTO_OPENCODE_LAUNCHER="$ALIGN_STUB/mefisto-opencode" OPENCODE_LOG OPENCODE_ROOT
    main
) >/dev/null 2>&1
assert_igual "" "$(cat "$OPENCODE_LOG")" "sin --align-opencode no invoca OpenCode"

# Sin launcher, usa el bootstrap incluido en la raiz Claude ya validada. El fixture
# representa al entrypoint remoto seguro: crea el launcher solo despues de su exito.
BOOTSTRAP_XDG="$(mktemp -d)"
trap 'rm -rf "$FAKE_CACHE" "$STUB_DIR" "$CONSUMER_DIR" "$FAKE_CACHE_S4" "$CLAUDE_LOG" "$OPENCODE_ROOT" "$ALIGN_CONSUMER" "$ALIGN_CACHE" "$ALIGN_STUB" "$OPENCODE_LOG" "$BOOTSTRAP_XDG"' EXIT
mkdir -p "$ALIGN_CLAUDE/src/published/scripts"
cat > "$ALIGN_CLAUDE/src/published/scripts/install-opencode-release.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = bootstrap ] && [ "$2" = 1.2.3 ] || exit 2
mkdir -p "$XDG_DATA_HOME/mefisto/active/bin"
cp "$ALIGN_STUB/mefisto-opencode" "$XDG_DATA_HOME/mefisto/active/bin/mefisto-opencode"
EOF
chmod +x "$ALIGN_CLAUDE/src/published/scripts/install-opencode-release.sh"
(
    cd "$ALIGN_CONSUMER" || exit 1
    export PATH="$ALIGN_STUB:$PATH" MEFISTO_CACHE_ROOT="$ALIGN_CACHE" XDG_DATA_HOME="$BOOTSTRAP_XDG" ALIGN_STUB OPENCODE_LOG OPENCODE_ROOT
    unset MEFISTO_OPENCODE_LAUNCHER
    main --align-opencode
) >/dev/null 2>&1
assert_igual "0" "$?" "la primera instalacion usa el bootstrap confiable de la raiz Claude destino"

# Si el bootstrap falla no queda un launcher ni una activacion parcial que se presente como exito.
rm -rf "$BOOTSTRAP_XDG/mefisto"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$ALIGN_CLAUDE/src/published/scripts/install-opencode-release.sh"
chmod +x "$ALIGN_CLAUDE/src/published/scripts/install-opencode-release.sh"
(
    cd "$ALIGN_CONSUMER" || exit 1
    export PATH="$ALIGN_STUB:$PATH" MEFISTO_CACHE_ROOT="$ALIGN_CACHE" XDG_DATA_HOME="$BOOTSTRAP_XDG" ALIGN_STUB OPENCODE_LOG OPENCODE_ROOT
    unset MEFISTO_OPENCODE_LAUNCHER
    main --align-opencode
) >/dev/null 2>&1
assert_igual "1" "$?" "la falla del bootstrap es visible y retorna error"

# Un launcher activo y valido cuya instalacion falla debe propagar el error.
cat > "$ALIGN_STUB/mefisto-opencode-install-fail" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  status) exit 0 ;;
  package-root) printf '%s\n' "$OPENCODE_ROOT" ;;
  install) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$ALIGN_STUB/mefisto-opencode-install-fail"
(
    cd "$ALIGN_CONSUMER" || exit 1
    export PATH="$ALIGN_STUB:$PATH" MEFISTO_CACHE_ROOT="$ALIGN_CACHE" MEFISTO_OPENCODE_LAUNCHER="$ALIGN_STUB/mefisto-opencode-install-fail" OPENCODE_ROOT
    main --align-opencode
) >/dev/null 2>&1
assert_igual "1" "$?" "la falla de install del launcher es visible y retorna error"

# Un manifiesto Claude invalido aborta antes de tocar el launcher.
printf '{invalido\n' > "$ALIGN_CLAUDE/mefisto-manifest.json"
: > "$OPENCODE_LOG"
(
    cd "$ALIGN_CONSUMER" || exit 1
    export PATH="$ALIGN_STUB:$PATH" MEFISTO_CACHE_ROOT="$ALIGN_CACHE" MEFISTO_OPENCODE_LAUNCHER="$ALIGN_STUB/mefisto-opencode" OPENCODE_LOG OPENCODE_ROOT
    main --align-opencode
) >/dev/null 2>&1
assert_igual "1" "$?" "un manifiesto Claude invalido falla cerrado"
assert_igual "" "$(cat "$OPENCODE_LOG")" "el manifiesto Claude invalido no toca OpenCode"

# Un identificador numerico de prerelease con cero inicial no es SemVer valido.
jq -n '{schemaVersion:1,runtime:"claude",version:"1.2.3-01",commit:"0123456789abcdef0123456789abcdef01234567"}' > "$ALIGN_CLAUDE/mefisto-manifest.json"
(
    cd "$ALIGN_CONSUMER" || exit 1
    export PATH="$ALIGN_STUB:$PATH" MEFISTO_CACHE_ROOT="$ALIGN_CACHE" MEFISTO_OPENCODE_LAUNCHER="$ALIGN_STUB/mefisto-opencode" OPENCODE_LOG OPENCODE_ROOT
    main --align-opencode
) >/dev/null 2>&1
assert_igual "1" "$?" "rechaza un prerelease que no cumple SemVer"

# Restaura el manifiesto y fuerza una proyeccion conflictiva: la alineacion debe fallar.
jq -n '{schemaVersion:1,runtime:"claude",version:"1.2.3",commit:"0123456789abcdef0123456789abcdef01234567"}' > "$ALIGN_CLAUDE/mefisto-manifest.json"
cat > "$ALIGN_STUB/mefisto-opencode-conflict" <<'EOF'
#!/usr/bin/env bash
case "$1" in project) exit 1 ;; package-root) printf '%s\n' "$OPENCODE_ROOT" ;; *) exit 0 ;; esac
EOF
chmod +x "$ALIGN_STUB/mefisto-opencode-conflict"
(
    cd "$ALIGN_CONSUMER" || exit 1
    export PATH="$ALIGN_STUB:$PATH" MEFISTO_CACHE_ROOT="$ALIGN_CACHE" MEFISTO_OPENCODE_LAUNCHER="$ALIGN_STUB/mefisto-opencode-conflict" OPENCODE_ROOT
    main --align-opencode
) >/dev/null 2>&1
assert_igual "1" "$?" "un conflicto de proyeccion falla cerrado"

# Una identidad OpenCode divergente no se acepta aunque install/activate hayan respondido bien.
jq '.commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$OPENCODE_ROOT/mefisto-manifest.json" > "$OPENCODE_ROOT/manifest.tmp" && mv "$OPENCODE_ROOT/manifest.tmp" "$OPENCODE_ROOT/mefisto-manifest.json"
(
    cd "$ALIGN_CONSUMER" || exit 1
    export PATH="$ALIGN_STUB:$PATH" MEFISTO_CACHE_ROOT="$ALIGN_CACHE" MEFISTO_OPENCODE_LAUNCHER="$ALIGN_STUB/mefisto-opencode" OPENCODE_LOG OPENCODE_ROOT
    main --align-opencode
) >/dev/null 2>&1
assert_igual "1" "$?" "un diagnostico divergente no se acepta como aligned"

# El modo de poda no puede aceptar silenciosamente una alineacion que no ejecutaria.
(
    cd "$ALIGN_CONSUMER" || exit 1
    export PATH="$ALIGN_STUB:$PATH" MEFISTO_CACHE_ROOT="$ALIGN_CACHE"
    main --prune --align-opencode
) >/dev/null 2>&1
assert_igual "1" "$?" "rechaza combinar --align-opencode con --prune"

echo ""
echo "===================================================================="
echo "  test-update-plugin.sh: $PASS pasaron, $FAIL fallaron"
echo "===================================================================="

[ "$FAIL" -eq 0 ]
