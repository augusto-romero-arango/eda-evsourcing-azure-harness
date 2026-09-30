#!/usr/bin/env bash
# Test de scripts/upgrade.sh bajo OpenCode (issue #1679): estado del par Claude y alineacion.
# claude, gh y launcher son stubs; nunca se toca el CLI ni el cache reales.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

command -v jq >/dev/null 2>&1 || { echo "jq requerido"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
CONSUMER="$TMP/consumer"; STUBS="$TMP/scripts"; BIN="$TMP/bin"; NOCLAUDE="$TMP/nobin"
mkdir -p "$CONSUMER" "$STUBS" "$BIN" "$NOCLAUDE" "$TMP/src/published/scripts" "$TMP/oc/active/bin"
git -C "$CONSUMER" init -q
cp "$REPO_ROOT/scripts/upgrade.sh" "$STUBS/upgrade.sh"
cp "$REPO_ROOT/src/published/scripts/diagnose-installation-identity.sh" "$TMP/src/published/scripts/"
chmod +x "$STUBS/upgrade.sh"

# Manifiestos: OpenCode 1.1.0 activo; cache Claude con 1.0.0 y 1.1.0.
COMMIT=$(printf 'a%.0s' $(seq 40))
CACHE="$TMP/cache"
for v in 1.0.0 1.1.0; do
    mkdir -p "$CACHE/mkt-x/mefisto/$v"
    printf '{"schemaVersion":1,"runtime":"claude","version":"%s","commit":"%s"}\n' "$v" "$COMMIT" > "$CACHE/mkt-x/mefisto/$v/mefisto-manifest.json"
done
printf '{"schemaVersion":1,"runtime":"opencode","version":"1.1.0","commit":"%s"}\n' "$COMMIT" > "$TMP/oc/active/mefisto-manifest.json"

LAUNCHER="$TMP/oc/active/bin/mefisto-opencode"
cat > "$LAUNCHER" <<'S'
#!/usr/bin/env bash
echo "launcher $*" >> "$STUB_LOG"
case "$1" in
    projection-status)
        printf '{"schemaVersion":1,"status":"enabled","configRoot":"/c","activeVersion":"%s","ledgerRelease":"%s"}\n' "${STUB_ACTIVE:-1.0.0}" "${STUB_ACTIVE:-1.0.0}" ;;
    prune) echo "No hay releases podables." ;;
esac
exit 0
S
cat > "$BIN/gh" <<'S'
#!/usr/bin/env bash
printf 'v1.1.0\n'
S
# claude stub: STUB_CLAUDE_MODE = enabled | disabled | weird | fail. Tras update/install,
# la version pasa a STUB_CLAUDE_AFTER.
cat > "$BIN/claude" <<'S'
#!/usr/bin/env bash
echo "claude $*" >> "$STUB_LOG"
state="$STUB_TMP/claude-version"
case "$1 $2" in
    "plugin list")
        case "${STUB_CLAUDE_MODE:-enabled}" in
            fail) echo "boom" >&2; exit 2 ;;
            weird) echo "???"; exit 0 ;;
            disabled) [ -f "$state" ] || { printf 'Installed plugins:\n\n  other@mkt-x\n    Version: 9.9.9\n'; exit 0; } ;;
        esac
        v=$(cat "$state" 2>/dev/null || echo "${STUB_CLAUDE_BEFORE:-1.0.0}")
        printf 'Installed plugins:\n\n  > mefisto@mkt-x\n    Version: %s\n    Scope: user\n' "$v" ;;
    "plugin update"|"plugin install") printf '%s' "${STUB_CLAUDE_AFTER:-1.1.0}" > "$state" ;;
    "plugin marketplace")
        if [ "$3" = list ]; then printf '  > mkt-x\n    Source: GitHub (augusto-romero-arango/eda-evsourcing-azure-harness)\n'; fi ;;
esac
exit 0
S
chmod +x "$BIN/gh" "$BIN/claude" "$LAUNCHER"
for t in bash env git jq dirname basename cat sed awk grep head uname mktemp seq rm cp ls tr; do
    p=$(command -v "$t") && ln -sf "$p" "$NOCLAUDE/$t"
done
export STUB_TMP="$TMP" STUB_LOG="$TMP/log" MEFISTO_OPENCODE_LAUNCHER="$LAUNCHER" MEFISTO_CACHE_ROOT="$CACHE" MEFISTO_RUNTIME=opencode
run() { : > "$STUB_LOG"; rm -f "$TMP/claude-version"; (cd "$CONSUMER" && PATH="$BIN:$PATH" "$STUBS/upgrade.sh" "$@" 2>&1); }
log() { cat "$STUB_LOG"; }

echo "[a] --status: tres estados del par Claude"
out=$(run --status)
echo "$out" | jq -e '.peer.runtime=="claude" and .peer.state=="enabled" and .peer.version=="1.0.0"' >/dev/null && ok "enabled con version" || ko "enabled: $out"
out=$(STUB_CLAUDE_MODE=disabled run --status)
echo "$out" | jq -e '.peer.state=="disabled" and .peer.version==null' >/dev/null && ok "disabled (CLI sin mefisto)" || ko "disabled: $out"
: > "$STUB_LOG"
out=$(cd "$CONSUMER" && PATH="$NOCLAUDE" "$STUBS/upgrade.sh" --status 2>&1)
echo "$out" | jq -e '.peer.state=="disabled" and .peer.version==null' >/dev/null && ok "disabled (sin CLI)" || ko "sin CLI: $out"
out=$(STUB_CLAUDE_MODE=weird run --status)
echo "$out" | jq -e '.peer.state=="unavailable"' >/dev/null && ok "unavailable (respuesta inesperada)" || ko "weird: $out"
out=$(STUB_CLAUDE_MODE=fail run --status)
echo "$out" | jq -e '.peer.state=="unavailable"' >/dev/null && ok "unavailable (CLI falla)" || ko "fail: $out"

echo "[b] enabled: marketplace update + plugin update con marketplace derivado"
out=$(run --align-peer)
seq=$(log | grep '^claude' | grep -v 'plugin list' | tr '\n' '|')
[ "$seq" = "claude plugin marketplace update mkt-x|claude plugin update mefisto@mkt-x --scope user|" ] && ok "secuencia" || ko "secuencia: $seq"
has "$out" '"status":"aligned"' && ok "identidad alineada (JSON)" || ko "identidad: $out"

echo "[c] disabled con CLI: install"
out=$(STUB_CLAUDE_MODE=disabled run --align-peer)
has "$(log)" "claude plugin install mefisto@mkt-x --scope user" && ok "install" || ko "install: $(log)"
has "$(log)" "claude plugin update" && ko "no debia hacer update" || ok "sin update"

echo "[d] unavailable: sin mutacion"
out=$(STUB_CLAUDE_MODE=weird run --align-peer); rc=$?
has "$(log)" "plugin update" || has "$(log)" "plugin install" || has "$(log)" "marketplace update" && ko "muto Claude: $(log)" || ok "sin mutacion"
has "$out" "no se muta Claude" && ok "lo informa" || ko "no informa: $out"
has "$(log)" "launcher install" && ok "OpenCode se actualizo" || ko "OpenCode no se actualizo"

echo "[e] deriva cuando la version resultante difiere"
out=$(STUB_CLAUDE_AFTER=1.0.5 run --align-peer)
has "$out" "DERIVA VISIBLE" && ok "reporta deriva" || ko "sin deriva: $out"
has "$(log)" "launcher activate" && ok "OpenCode no se revierte" || ko "revirtio"

echo "[f] nunca poda el cache Claude"
run --align-peer >/dev/null
has "$(log)" "claude plugin prune" && ko "podo" || ok "sin poda de Claude"
has "$(log)" "update-plugin.sh --prune" && ko "update-plugin --prune" || ok "sin --prune"

echo ""; echo "Resultado: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
