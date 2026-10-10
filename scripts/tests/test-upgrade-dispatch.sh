#!/usr/bin/env bash
# Test de scripts/upgrade.sh (issue #1678): despacho por runtime, JSON de --status,
# secuencia de auto-actualizacion OpenCode y poda. gh, launcher y update-plugin.sh son stubs.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

command -v jq >/dev/null 2>&1 || { echo "jq requerido"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
CONSUMER="$TMP/consumer"; STUBS="$TMP/scripts"; BIN="$TMP/bin"
mkdir -p "$CONSUMER/.claude/pipeline" "$STUBS" "$BIN"
git -C "$CONSUMER" init -q
cp "$REPO_ROOT/scripts/upgrade.sh" "$REPO_ROOT/scripts/_plugin-scopes.sh" "$STUBS/"
printf '/x/cache/mkt/mefisto/1.0.0' > "$CONSUMER/.claude/pipeline/.plugin-root"

cat > "$STUBS/update-plugin.sh" <<'S'
#!/usr/bin/env bash
echo "update-plugin $*" >> "$STUB_LOG"
S
cat > "$BIN/gh" <<'S'
#!/usr/bin/env bash
echo "gh $*" >> "$STUB_LOG"
printf '%s\n' "${STUB_GH_TAG:-v1.1.0}"
S
cat > "$BIN/claude" <<'S'
#!/usr/bin/env bash
echo "unexpected"; exit 2
S
LAUNCHER="$TMP/mefisto-opencode"
cat > "$LAUNCHER" <<'S'
#!/usr/bin/env bash
echo "launcher $*" >> "$STUB_LOG"
case "$1" in
    projection-status)
        printf '{"schemaVersion":1,"status":"%s","configRoot":"/c","activeVersion":"%s","ledgerRelease":"%s"}\n' \
            "${STUB_PROJ:-enabled}" "${STUB_ACTIVE:-1.0.0}" "${STUB_ACTIVE:-1.0.0}" ;;
    prune) echo "No hay releases podables." ;;
esac
exit 0
S
chmod +x "$STUBS"/*.sh "$BIN/gh" "$BIN/claude" "$LAUNCHER"
mkdir -p "$TMP/xdg"
export STUB_LOG="$TMP/log" MEFISTO_OPENCODE_LAUNCHER="$LAUNCHER" PATH="$BIN:$PATH" XDG_CONFIG_HOME="$TMP/xdg"
run() { : > "$STUB_LOG"; (cd "$CONSUMER" && "$STUBS/upgrade.sh" "$@" 2>&1); }
log() { cat "$STUB_LOG"; }

echo "[a] claude: delegacion y traduccion de flags"
MEFISTO_RUNTIME=claude run >/dev/null; [ "$(log)" = "update-plugin " ] && ok "sin flags" || ko "sin flags: $(log)"
MEFISTO_RUNTIME=claude run --align-peer >/dev/null; has "$(log)" "update-plugin --align-opencode" && ok "--align-peer" || ko "--align-peer"
MEFISTO_RUNTIME=claude run --prune --only 0.8.0 --loaded 0.9.0 >/dev/null; [ "$(log)" = "update-plugin --prune --only 0.8.0 --loaded 0.9.0" ] && ok "--prune --loaded" || ko "--prune --loaded: $(log)"
MEFISTO_RUNTIME=claude run --prune --only 0.43.0,0.44.0 >/dev/null; [ "$(log)" = "update-plugin --prune --only 0.43.0,0.44.0" ] && ok "--prune reenvia --only y sin --loaded no lo infiere de .plugin-root" || ko "--prune: $(log)"

LR="$TMP/cache/mefisto"
for v in 0.44.0 0.44.1; do mkdir -p "$LR/$v/.claude-plugin"; printf '{"name":"mefisto","version":"%s"}' "$v" > "$LR/$v/.claude-plugin/plugin.json"; done
mkdir -p "$TMP/cache/otro/9.9.9/.claude-plugin"; printf '{"name":"otro","version":"9.9.9"}' > "$TMP/cache/otro/9.9.9/.claude-plugin/plugin.json"
MEFISTO_LOADED_ROOT="$LR/0.44.1" MEFISTO_RUNTIME=claude run >/dev/null; has "$(log)" "--loaded 0.44.1" && ok "MEFISTO_LOADED_ROOT valida reenvia --loaded (actualizar)" || ko "loaded actualizar: $(log)"
MEFISTO_LOADED_ROOT="$LR/0.44.1" MEFISTO_RUNTIME=claude run --align-peer >/dev/null; [ "$(log)" = "update-plugin --align-opencode --loaded 0.44.1" ] && ok "--align-peer reenvia --loaded" || ko "align loaded: $(log)"
MEFISTO_LOADED_ROOT="$LR/0.44.1" MEFISTO_RUNTIME=claude run --prune --only 0.43.0 >/dev/null; [ "$(log)" = "update-plugin --prune --only 0.43.0 --loaded 0.44.1" ] && ok "--prune reenvia --loaded desde MEFISTO_LOADED_ROOT" || ko "prune loaded: $(log)"
MEFISTO_LOADED_ROOT="$LR/0.44.1" MEFISTO_RUNTIME=claude run --prune --only 0.8.0 --loaded 0.9.0 >/dev/null; [ "$(log)" = "update-plugin --prune --only 0.8.0 --loaded 0.9.0" ] && ok "--loaded explicito gana" || ko "explicito: $(log)"
for bad in "" '${CLAUDE_PLUGIN_ROOT}' "$LR/0.44.0/../0.44.1" "$LR/9.9.9" "$TMP/cache/otro/9.9.9" "relativa/0.44.1"; do
    MEFISTO_LOADED_ROOT="$bad" MEFISTO_RUNTIME=claude run >/dev/null; [ "$(log)" = "update-plugin " ] && ok "MEFISTO_LOADED_ROOT '$bad' se ignora" || ko "invalida '$bad': $(log)"
done

echo "[b] --status JSON"
out=$(MEFISTO_RUNTIME=claude run --status)
echo "$out" | jq -e '.schemaVersion==2 and .runtime=="claude" and .installedVersion=="1.0.0" and (has("loadedVersion")|not) and .peer.runtime=="opencode" and .peer.state=="enabled" and .peer.version=="1.0.0"' >/dev/null && ok "claude" || ko "claude: $out"
out=$(MEFISTO_RUNTIME=opencode run --status)
echo "$out" | jq -e '.schemaVersion==2 and .runtime=="opencode" and has("installedVersion") and (has("loadedVersion")|not) and .peer.runtime=="claude" and .peer.state=="unavailable" and .peer.version==null' >/dev/null && ok "opencode" || ko "opencode: $out"

echo "[c] opencode: secuencia con la version de gh"
out=$(MEFISTO_RUNTIME=opencode run)
seq=$(log | grep '^launcher' | awk '{print $2}' | grep -v projection-status | head -4 | tr '\n' ' ')
[ "$seq" = "install activate status prune " ] && ok "secuencia sin proyeccion global (MEF-ADR-0053)" || ko "secuencia: $seq"
mkdir -p "$TMP/xdg/opencode"; echo '{}' > "$TMP/xdg/opencode/.mefisto-projection.json"
MEFISTO_RUNTIME=opencode run >/dev/null
seq=$(log | grep '^launcher' | awk '{print $2}' | grep -v projection-status | head -4 | tr '\n' ' ')
[ "$seq" = "install activate project status " ] && ok "con proyeccion global opt-in la refresca" || ko "secuencia con proyeccion: $seq"
rm -f "$TMP/xdg/opencode/.mefisto-projection.json"
out=$(MEFISTO_RUNTIME=opencode run)
has "$(log)" "launcher install 1.1.0" && has "$(log)" "gh release view --repo augusto-romero-arango/eda-evsourcing-azure-harness" && ok "version de gh" || ko "version de gh"
has "$out" "Version cargada en esta sesion: 1.0.0" && has "$out" "Version destino: 1.1.0" && ok "salida" || ko "salida: $out"

echo "[d] ya en la ultima version"
out=$(STUB_ACTIVE=1.1.0 MEFISTO_RUNTIME=opencode run)
has "$(log)" "launcher install" && ko "mutó" || ok "sin install"
has "$out" "Ya estas en la ultima version" && ok "lo reporta" || ko "no reporta: $out"

echo "[e] --prune nunca pasa la version activa"
MEFISTO_RUNTIME=opencode run --prune --keep 3 >/dev/null
[ "$(log)" = "launcher prune --keep 3 --yes" ] && ok "delega en prune" || ko "prune: $(log)"
has "$(log)" "1.0.0" && ko "paso version" || ok "sin version"

echo "[f] runtime desconocido"
out=$(MEFISTO_RUNTIME=zzz run --status); rc=$?
[ "$rc" -ne 0 ] && has "$out" "no soportado" && ok "aborta" || ko "no aborta: $out"

echo ""; echo "Resultado: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
