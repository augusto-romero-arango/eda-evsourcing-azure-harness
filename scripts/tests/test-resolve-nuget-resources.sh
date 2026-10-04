#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; REPO_ROOT="$(cd "$HERE/../.." && pwd -P)"
RESOLVER="$REPO_ROOT/scripts/resolve-nuget-resources.sh"; FIXTURES="$HERE/fixtures/resolve-nuget-resources"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }; fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
mkdir -p "$WORK/bin" "$WORK/tree/src/obj" "$WORK/tree/custom" "$WORK/packages primary" "$WORK/packages fallback"
cp "$FIXTURES/one.assets.json" "$WORK/tree/src/obj/project.assets.json"
cp "$FIXTURES/duplicate.assets.json" "$WORK/tree/custom/other.assets.json"
cp "$FIXTURES/corrupt.assets.json" "$WORK/tree/custom/corrupt.assets.json"
cat > "$WORK/bin/dotnet" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$DOTNET_ARGS"; printf '%s\n' "$PWD" > "$DOTNET_CWD"
case "$DOTNET_MODE" in ok) printf '%s\n' "$DOTNET_OUTPUT" ;; error) exit 127 ;; esac
EOF
chmod +x "$WORK/bin/dotnet"
run() { PATH="$WORK/bin:$PATH" DOTNET_ARGS="$WORK/args" DOTNET_CWD="$WORK/cwd" DOTNET_MODE="$1" DOTNET_OUTPUT="$2" bash "$RESOLVER" --worktree-root "$WORK/tree" "${@:3}"; }
OUTPUT="$(run ok "info : global-packages: $WORK/packages primary")"; RC=$?
CLI_PHYSICAL="$(cd "$WORK/packages primary" && pwd -P)"
[ "$RC" -eq 0 ] && jq -e --arg cli "$CLI_PHYSICAL" --arg primary /fixtures/packages-primary --arg fallback /fixtures/packages-fallback '.status == "resolved" and .coverage == "observed-assets" and ([.roots[].physicalRoot] | index($cli)) and ([.roots[].logicalRoot] | index($primary)) and ([.roots[].logicalRoot] | index($fallback)) and (.assets | length == 1)' >/dev/null <<< "$OUTPUT" && pass 'CLI con prefijo y espacios se combina con assets v3' || fail 'CLI/assets no conserva roots observadas'
[ "$(< "$WORK/args")" = 'nuget locals global-packages --list --force-english-output' ] && [ "$(< "$WORK/cwd")" = "$(cd "$WORK/tree" && pwd -P)" ] && pass 'CLI usa solo el argv fijado y cwd del worktree' || fail 'CLI uso argv o cwd inesperado'
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
"$GENERATOR" --out "$WORK/release" >/dev/null 2>&1
PACKAGED="$WORK/release/dist/claude/scripts/resolve-nuget-resources.sh"
PACKAGED_OUTPUT="$(PATH="$WORK/bin:$PATH" DOTNET_ARGS="$WORK/args" DOTNET_CWD="$WORK/cwd" DOTNET_MODE=ok DOTNET_OUTPUT="global-packages: $WORK/packages primary" bash "$PACKAGED" --worktree-root "$WORK/tree")"; PACKAGED_RC=$?
[ "$PACKAGED_RC" -eq 0 ] && jq -e '.schemaVersion == 1 and .status == "resolved"' >/dev/null <<< "$PACKAGED_OUTPUT" && [ -x "$WORK/release/dist/opencode/scripts/resolve-nuget-resources.sh" ] && [ -f "$WORK/release/dist/claude/src/published/scripts/lib/resource-paths.sh" ] && pass 'copias distribuidas contienen la clausura ejecutable' || fail 'la clausura distribuida no se ejecuta desde dist'
OUTPUT="$(run ok "global-packages: $WORK/packages primary" --assets-file "$WORK/tree/custom/other.assets.json")"; RC=$?
[ "$RC" -eq 0 ] && jq -e --arg primary /fixtures/packages-primary '[.roots[] | select(.logicalRoot == $primary) | .sources | length] == [2] and (.assets | length == 2)' >/dev/null <<< "$OUTPUT" && pass 'deduplica roots fisicas y conserva procedencias de assets' || fail 'deduplicacion/procedencia incorrecta'
OUTPUT="$(run ok $'global-packages: /uno\nglobal-packages: /dos')"; RC=$?
[ "$RC" -eq 1 ] && jq -e '.status == "unavailable" and (.diagnostics | index("CLI_OUTPUT_INVALID"))' >/dev/null <<< "$OUTPUT" && pass 'salida ambigua no usa fallback del home' || fail 'salida ambigua no queda unavailable'
OUTPUT="$(run error ignored)"; RC=$?
[ "$RC" -eq 1 ] && jq -e '.status == "unavailable" and (.diagnostics | index("CLI_UNAVAILABLE"))' >/dev/null <<< "$OUTPUT" && pass 'SDK ausente queda unavailable sin instalarlo' || fail 'SDK ausente no queda unavailable'
OUTPUT="$(run ok "global-packages: $WORK/packages primary" --assets-file "$WORK/tree/custom/corrupt.assets.json")"; RC=$?
[ "$RC" -eq 1 ] && jq -e '.status == "conflict" and (.diagnostics | index("ASSET_INVALID"))' >/dev/null <<< "$OUTPUT" && pass 'assets explicito corrupto es conflicto' || fail 'assets corrupto no es conflicto'
OUTPUT="$(run ok "global-packages: $WORK/packages primary" --assets-file "$WORK/ajeno.assets.json")"; RC=$?
[ "$RC" -eq 1 ] && jq -e '.status == "conflict"' >/dev/null <<< "$OUTPUT" && pass 'assets explicito ajeno es conflicto' || fail 'assets ajeno no es conflicto'
printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"; exit "$FAIL"
