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

# Clasificacion del par OpenCode: la autoridad es `upgrade.sh --status` (#1680/#1712),
# ejecutado desde un consumidor git fixture contra un launcher fixture.
UPGRADE="$REPO_ROOT/scripts/upgrade.sh"
mkdir -p "$WORK/home" "$WORK/consumer"
git -C "$WORK/consumer" init -q
discovery_status() {
    local launcher="$1"
    (cd "$WORK/consumer" && HOME="$WORK/home" MEFISTO_RUNTIME=claude MEFISTO_OPENCODE_LAUNCHER="$launcher" \
        bash "$UPGRADE" --status 2>/dev/null) | jq -r '.peer.state // empty' 2>/dev/null
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
assert_contains "$content" 'Solo si responde exactamente `si`, usa `--align-peer`' 'legacy exige si exacto y alineacion del par'
assert_contains "$content" 'si declina o no responde, actualiza solo el runtime activo' 'declinar legacy no alinea el par'
assert_contains "$content" '`conflict` / `operation-in-progress` / `unavailable`' 'estados fail-closed conservan su rama'
assert_contains "$content" 'Nunca pases `--align-peer`.' 'estados fail-closed no habilitan alineacion'

echo '[Herdr] refresh automatico desde la release destino'
refresh_section=$(printf '%s\n' "$content" | awk '/^### 4\. Refrescar agentes herdr/{capture=1} /^### 5\./{capture=0} capture')
assert_contains "$refresh_section" 'Solo si `HERDR_ENV=1`' 'el refresh solo se ejecuta dentro de Herdr'
assert_contains "$refresh_section" 'herdr-pipeline.sh" --refresh-agents' 'invoca el refresh desde la release destino'
assert_contains "$refresh_section" 'best-effort' 'tolera fallos del refresh'
assert_contains "$refresh_section" 'Sin panes Herdr que refrescar' 'declara el reporte para una salida vacia'
assert_contains "$refresh_section" '`Pane`, `Runtime` y `Accion`' 'declara la tabla sin reinterpretar acciones'
assert_contains "$content" 'Si el reporte herdr incluyo `omitido:working` u `omitido:blocked`' 'los panes ocupados conservan el reload manual diferido'
assert_contains "$content" 'nunca interrumpe un pane ocupado ni el pane propio' 'las reglas protegen panes ocupados y el propio'

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
