#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../.." && pwd -P)"
RESOLVER="$REPO_ROOT/scripts/resolve-nuget-resources.sh"
FIXTURES="$HERE/fixtures/resolve-nuget-resources"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0

pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_json() {
    local description="$1" expression="$2" json="$3"
    if jq -e "$expression" >/dev/null 2>&1 <<< "$json"; then pass "$description"; else fail "$description"; fi
}

mkdir -p "$WORK/bin" "$WORK/tree/src/obj" "$WORK/tree/custom" "$WORK/empty-tree" \
    "$WORK/packages primary" "$WORK/packages fallback" "$WORK/outside/obj"
cp "$FIXTURES/one.assets.json" "$WORK/tree/src/obj/project.assets.json"
cp "$FIXTURES/duplicate.assets.json" "$WORK/tree/custom/other.assets.json"
cp "$FIXTURES/corrupt.assets.json" "$WORK/tree/custom/corrupt.assets.json"
cp "$FIXTURES/one.assets.json" "$WORK/outside/obj/project.assets.json"
ln -s "$WORK/outside" "$WORK/tree/linked-outside"
cat > "$WORK/tree/NuGet.Config" <<'EOF'
<configuration><packageSources><add key="sentinel" value="https://user:SECRET@example.invalid/v3/index.json" /></packageSources></configuration>
EOF
CONFIG_HASH="$(shasum -a 256 "$WORK/tree/NuGet.Config")"; CONFIG_HASH="${CONFIG_HASH%% *}"

cat > "$WORK/bin/dotnet" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$DOTNET_ARGS"
printf '%s\n' "$PWD" > "$DOTNET_CWD"
printf '%s\n' "${NUGET_PACKAGES-}" > "$DOTNET_ENV"
case "$DOTNET_MODE" in
    ok) printf '%s\n' "$DOTNET_OUTPUT" ;;
    environment) printf 'global-packages: %s\n' "${NUGET_PACKAGES:-$DOTNET_OUTPUT}" ;;
    error) printf '%s\n' 'CLI_STDOUT_SECRET'; printf '%s\n' 'CLI_STDERR_SECRET' >&2; exit 127 ;;
esac
EOF
chmod +x "$WORK/bin/dotnet"

RUN_TREE="$WORK/tree"
run() {
    local mode="$1" output="$2"
    shift 2
    PATH="$WORK/bin:$PATH" DOTNET_ARGS="$WORK/args" DOTNET_CWD="$WORK/cwd" \
        DOTNET_ENV="$WORK/environment" DOTNET_MODE="$mode" DOTNET_OUTPUT="$output" \
        bash "$RESOLVER" --worktree-root "$RUN_TREE" "$@"
}

OUTPUT="$(run ok "info : global-packages: $WORK/packages primary")"; RC=$?
CLI_PHYSICAL="$(cd "$WORK/packages primary" && pwd -P)"
assert_json 'prefijo info, espacios y assets v3 producen el envelope cerrado' \
    '(. | keys | sort) == ["assets","coverage","diagnostics","roots","schemaVersion","status","worktreeRoot"] and .schemaVersion == 1 and .status == "resolved" and .coverage == "observed-assets" and (.assets | length == 1)' "$OUTPUT"
if jq -e --arg cli "$CLI_PHYSICAL" --arg primary /fixtures/packages-primary --arg fallback /fixtures/packages-fallback \
    '([.roots[] | select(.physicalRoot == $cli and .exists == true and .sources == [{"kind":"cli"}])] | length) == 1 and ([.roots[].logicalRoot] | index($primary)) and ([.roots[].logicalRoot] | index($fallback))' >/dev/null <<< "$OUTPUT"; then
    pass 'locals y packageFolders distintos conservan roots existentes y planned'
else
    fail 'locals y packageFolders distintos conservan roots existentes y planned'
fi
if [ "$(wc -l < "$WORK/args" | tr -d ' ')" = 4 ] && \
   [ "$(sed -n '1p' "$WORK/args")" = nuget ] && [ "$(sed -n '2p' "$WORK/args")" = locals ] && \
   [ "$(sed -n '3p' "$WORK/args")" = global-packages ] && [ "$(sed -n '4p' "$WORK/args")" = --list ] ; then
    fail 'CLI omite --force-english-output'
elif [ "$(printf '%s|' "$(sed -n '1p' "$WORK/args")" "$(sed -n '2p' "$WORK/args")" "$(sed -n '3p' "$WORK/args")" "$(sed -n '4p' "$WORK/args")" "$(sed -n '5p' "$WORK/args")")" = 'nuget|locals|global-packages|--list|--force-english-output|' ] && \
     [ "$(< "$WORK/cwd")" = "$(cd "$WORK/tree" && pwd -P)" ]; then
    pass 'CLI usa exactamente cinco argumentos y el cwd físico del worktree'
else
    fail 'CLI usa exactamente cinco argumentos y el cwd físico del worktree'
fi

OUTPUT="$(NUGET_PACKAGES='' run environment "$WORK/packages primary")"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$(< "$WORK/environment")" ] && jq -e --arg root "$CLI_PHYSICAL" '.roots | any(.physicalRoot == $root and .sources == [{"kind":"cli"}])' >/dev/null <<< "$OUTPUT"; then
    pass 'el doble de CLI cubre la ubicación default sin consultar el home real'
else
    fail 'el doble de CLI no cubre de forma determinista la ubicación default'
fi
NUGET_PACKAGES="$WORK/packages fallback" OUTPUT="$(NUGET_PACKAGES="$WORK/packages fallback" run environment ignored)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(< "$WORK/environment")" = "$WORK/packages fallback" ] && jq -e --arg root "$(cd "$WORK/packages fallback" && pwd -P)" '.roots | any(.physicalRoot == $root and .sources == [{"kind":"cli"}])' >/dev/null <<< "$OUTPUT"; then
    pass 'el entorno efectivo permite que la CLI resuelva NUGET_PACKAGES'
else
    fail 'el entorno efectivo permite que la CLI resuelva NUGET_PACKAGES'
fi

OUTPUT="$(run ok "global-packages: $WORK/packages primary" --assets-file "$WORK/tree/custom/other.assets.json")"; RC=$?
if [ "$RC" -eq 0 ] && jq -e --arg primary /fixtures/packages-primary \
    '[.roots[] | select(.logicalRoot == $primary) | .sources | length] == [2] and (.assets | length == 2) and all(.assets[]; (.path | startswith("/") | not) and (.sha256 | test("^[0-9a-f]{64}$")))' >/dev/null <<< "$OUTPUT"; then
    pass 'archivo personalizado deduplica roots y conserva procedencias, rutas relativas y hashes'
else
    fail 'archivo personalizado deduplica roots y conserva procedencias, rutas relativas y hashes'
fi

RUN_TREE="$WORK/empty-tree"
OUTPUT="$(run ok "global-packages: $WORK/not-created")"; RC=$?
if [ "$RC" -eq 0 ] && jq -e --arg logical "$WORK/not-created" \
    '.status == "resolved" and .coverage == "global-only" and (.assets | length == 0) and (.roots | length == 1) and .roots[0].logicalRoot == $logical and .roots[0].exists == false and .roots[0].sources == [{"kind":"cli"}]' >/dev/null <<< "$OUTPUT"; then
    pass 'sin assets la cobertura es global-only y la root se reporta planned'
else
    fail 'sin assets la cobertura es global-only y la root se reporta planned'
fi
RUN_TREE="$WORK/tree"

for invalid_output in '' $'global-packages: /uno\nglobal-packages: /dos' $'global-packages: /uno\nmensaje inesperado' $'global-packages: /uno\n\nglobal-packages: /dos' $'global-packages: /uno\n'; do
    OUTPUT="$(run ok "$invalid_output")"; RC=$?
    if [ "$RC" -eq 1 ] && jq -e '.status == "unavailable" and (.diagnostics | index("CLI_OUTPUT_INVALID"))' >/dev/null <<< "$OUTPUT"; then pass 'cero, múltiples o líneas inesperadas de CLI fallan cerradas'; else fail 'salida CLI inválida no falla cerrada'; fi
done
OUTPUT="$(run ok 'global-packages: ')"; RC=$?
assert_json 'una root vacía es conflicto, no fallback a home' '.status == "conflict" and (.diagnostics | index("EMPTY_PACKAGE_FOLDER"))' "$OUTPUT"
OUTPUT="$(run error ignored)"; RC=$?
if [ "$RC" -eq 1 ] && jq -e '.status == "unavailable" and (.diagnostics | index("CLI_UNAVAILABLE"))' >/dev/null <<< "$OUTPUT" && [[ "$OUTPUT" != *SECRET* ]]; then pass 'SDK ausente no propaga stdout ni stderr crudos'; else fail 'error de CLI filtra salida o no queda unavailable'; fi

for explicit in "$WORK/tree/custom/corrupt.assets.json" "$WORK/tree/custom/missing.assets.json" "$WORK/outside/obj/project.assets.json" "$WORK/tree/linked-outside/obj/project.assets.json"; do
    OUTPUT="$(run ok "global-packages: $WORK/packages primary" --assets-file "$explicit")"; RC=$?
    if [ "$RC" -eq 1 ] && jq -e '.status == "conflict"' >/dev/null <<< "$OUTPUT"; then pass 'assets explícito corrupto, ausente o ajeno es conflicto'; else fail "assets explícito inválido no es conflicto: $explicit"; fi
done
OUTPUT="$(run ok "global-packages: $WORK/packages primary")"; RC=$?
assert_json 'discovery no sigue un directorio symlink fuera del worktree' '.status == "resolved" and (.assets | length == 1)' "$OUTPUT"

cat > "$WORK/tree/custom/remote.assets.json" <<'EOF'
{"version":3,"packageFolders":{"https://user:ASSET_SECRET@example.invalid/packages":{}}}
EOF
OUTPUT="$(run ok "global-packages: $WORK/packages primary" --assets-file "$WORK/tree/custom/remote.assets.json")"; RC=$?
if [ "$RC" -eq 1 ] && jq -e '.status == "conflict" and (.diagnostics | index("ASSET_PACKAGE_FOLDER_INVALID"))' >/dev/null <<< "$OUTPUT" && [[ "$OUTPUT" != *ASSET_SECRET* ]]; then pass 'packageFolders no local se rechaza sin filtrar endpoints'; else fail 'packageFolders no local se imprime o acepta'; fi

for broad in / "$HOME" "$WORK"; do
    OUTPUT="$(run ok "global-packages: $broad")"; RC=$?
    if [ "$RC" -eq 1 ] && jq -e '.status == "conflict" and (.diagnostics | index("BROAD_PACKAGE_FOLDER"))' >/dev/null <<< "$OUTPUT"; then pass 'filesystem, home o ancestro del worktree se rechaza'; else fail "root amplia no se rechaza: $broad"; fi
done
HOME="$WORK/tree" OUTPUT="$(HOME="$WORK/tree" run ok "global-packages: $WORK/packages primary")"; RC=$?
assert_json 'un worktree igual a home se rechaza antes de descubrir archivos' '.status == "conflict" and (.diagnostics | index("WORKTREE_TOO_BROAD"))' "$OUTPUT"
if bash "$RESOLVER" --worktree-root relative >/dev/null 2>&1; then RC=0; else RC=$?; fi
if [ "$RC" -eq 2 ]; then pass 'worktree relativo es error de protocolo'; else fail 'worktree relativo no retorna uso 2'; fi
if bash "$RESOLVER" --worktree-root "$WORK/tree" --worktree-root "$WORK/tree" >/dev/null 2>&1; then RC=0; else RC=$?; fi
if [ "$RC" -eq 2 ]; then pass 'worktree duplicado es error de protocolo'; else fail 'worktree duplicado no retorna uso 2'; fi

AFTER_CONFIG_HASH="$(shasum -a 256 "$WORK/tree/NuGet.Config")"; AFTER_CONFIG_HASH="${AFTER_CONFIG_HASH%% *}"
if [ "$CONFIG_HASH" = "$AFTER_CONFIG_HASH" ] && [[ "$OUTPUT" != *SECRET* ]]; then pass 'NuGet.Config no se modifica ni se vuelca'; else fail 'NuGet.Config fue modificado o expuesto'; fi

GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
"$GENERATOR" --out "$WORK/release" >/dev/null 2>&1
for runtime in claude opencode; do
    PACKAGED="$WORK/release/dist/$runtime/scripts/resolve-nuget-resources.sh"
    RUN_TREE="$WORK/empty-tree"
    PACKAGED_OUTPUT="$(PATH="$WORK/bin:$PATH" DOTNET_ARGS="$WORK/args" DOTNET_CWD="$WORK/cwd" DOTNET_ENV="$WORK/environment" DOTNET_MODE=ok DOTNET_OUTPUT="global-packages: $WORK/packages primary" bash "$PACKAGED" --worktree-root "$RUN_TREE")"; PACKAGED_RC=$?
    if [ "$PACKAGED_RC" -eq 0 ] && [ -x "$PACKAGED" ] && [ -f "$WORK/release/dist/$runtime/src/published/scripts/lib/resource-paths.sh" ] && jq -e '.schemaVersion == 1 and .status == "resolved"' >/dev/null <<< "$PACKAGED_OUTPUT"; then pass "copia $runtime ejecuta con su clausura, sin checkout fuente"; else fail "copia $runtime no es autocontenida"; fi
done

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
