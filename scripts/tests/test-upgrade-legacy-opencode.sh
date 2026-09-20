#!/usr/bin/env bash
# Verifica la clasificacion estrecha del launcher anterior a projection-status y
# los contratos de confirmacion y refresco Herdr de commands/upgrade.md
# (issues #1270 y #1336).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMMAND="$REPO_ROOT/commands/upgrade.md"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_eq() { [ "$1" = "$2" ] && pass "$3" || fail "$3 (esperado: $1; obtenido: $2)"; }
assert_contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

# Ejecuta exactamente el bloque de discovery publicado contra un launcher fixture.
discovery_status() {
    local launcher="$1" output
    output="$(
        HOME="$WORK/home" MEFISTO_OPENCODE_LAUNCHER="$launcher" bash -s <<EOF
$(awk '/^PLUGIN_ROOT=\$\(cat \.claude\/pipeline\/\.plugin-root/{capture=1} capture {if (/^```$/) exit; print}' "$COMMAND")
EOF
    )"
    printf '%s\n' "$output" | awk -F': ' '/^Estado de proyeccion OpenCode:/ { print $2 }'
}

legacy="$WORK/legacy-launcher"
cat > "$legacy" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'ERROR: uso: mefisto-opencode install <semver> | activate <semver> | prune [--keep <n>] [--yes] | project | deactivate | status | diagnose | package-root'
exit 1
EOF
chmod +x "$legacy"

invalid="$WORK/invalid-launcher"
cat > "$invalid" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'ERROR: fallo ajeno'
exit 1
EOF
chmod +x "$invalid"

poisoned="$WORK/poisoned-launcher"
cat > "$poisoned" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'ERROR: fallo ajeno'
printf '%s\n' 'ERROR: uso: mefisto-opencode install <semver> | activate <semver> | prune [--keep <n>] [--yes] | project | deactivate | status | diagnose | package-root'
exit 1
EOF
chmod +x "$poisoned"

json_launcher() {
    local path="$1" status="$2" rc="$3"
    cat > "$path" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '{"schemaVersion":1,"status":"$status","configRoot":"/tmp/opencode","activeVersion":null,"ledgerRelease":null}'
exit $rc
EOF
    chmod +x "$path"
}
conflict="$WORK/conflict-launcher"; json_launcher "$conflict" conflict 1
in_progress="$WORK/in-progress-launcher"; json_launcher "$in_progress" operation-in-progress 1

echo '[clasificacion] launcher legado y estados fail-closed'
assert_eq legacy "$(discovery_status "$legacy")" 'el uso legado exacto se clasifica como legacy'
assert_eq unavailable "$(discovery_status "$invalid")" 'una salida arbitraria sigue unavailable'
assert_eq unavailable "$(discovery_status "$poisoned")" 'el uso legado debe ser la respuesta completa, no una linea entre errores'
assert_eq conflict "$(discovery_status "$conflict")" 'conflict no se reinterpreta como legacy'
assert_eq operation-in-progress "$(discovery_status "$in_progress")" 'operacion en curso no se reinterpreta como legacy'

content="$(< "$COMMAND")"
echo '[decision] confirmacion unica y mutacion condicionada'
assert_contains "$content" 'Solo si responde exactamente `si`, usa una vez `--align-opencode`' 'legacy exige si exacto y una sola alineacion'
assert_contains "$content" 'si declina o no responde, actualiza solo Claude y no modifica releases, ledger, enlaces ni configuracion OpenCode' 'declinar legacy no muta OpenCode'
assert_contains "$content" 'Para `conflict`, `operation-in-progress` o `unavailable`' 'estados fail-closed conservan su rama'
assert_contains "$content" 'Nunca pases `--align-opencode`; no los reinterpretes como `legacy` ni como consentimiento.' 'estados fail-closed no habilitan alineacion'

echo '[Herdr] refresh automatico desde la release destino'
refresh_section=$(printf '%s\n' "$content" | awk '/^### 4\. Refrescar agentes Herdr/{capture=1} /^### 5\./{capture=0} capture')
assert_contains "$refresh_section" 'if [ "${HERDR_ENV:-}" = "1" ]; then' 'el refresh solo se ejecuta dentro de Herdr'
assert_contains "$refresh_section" 'PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null || true)' 'relee best-effort la raiz escrita por el update'
assert_not_contains "$refresh_section" 'plugins/cache' 'no sustituye la raiz destino por una release inferida del cache'
assert_contains "$refresh_section" 'HERDR_REFRESH=$("$PLUGIN_SCRIPTS/herdr-pipeline.sh" --refresh-agents 2>/dev/null || true)' 'descarta stderr y tolera fallos del refresh'
assert_contains "$refresh_section" 'Sin panes Herdr que refrescar' 'declara el reporte para una salida vacia'
assert_contains "$refresh_section" 'Pane`, `Runtime` y `Accion' 'declara la tabla sin reinterpretar acciones'
assert_contains "$content" 'Si el reporte Herdr incluyo `omitido:working` u `omitido:blocked`' 'los panes ocupados conservan el reload manual diferido'
assert_contains "$content" 'automatico y best-effort; nunca interrumpe un pane ocupado ni el pane propio' 'las reglas protegen panes ocupados y el propio'

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
