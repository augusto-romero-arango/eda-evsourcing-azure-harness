#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
LIB="$REPO_ROOT/src/published/scripts/adapters/lib/opencode-resource-roots.sh"
PATHS="$REPO_ROOT/src/published/scripts/lib/resource-paths.sh"
CASES="$HERE/fixtures/opencode-resource-roots/root-cases.json"
WORK="$(mktemp -d)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT
PASS=0; FAIL=0; ERR="$WORK/stderr"

pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_json() {
    local output="$1" label="$2"; shift 2
    jq -e "$@" >/dev/null <<< "$output" && pass "$label" || fail "$label"
}
make_release() {
    local version="$1" store="$2" root
    root="$store/releases/$version"
    mkdir -p "$root/commands"
    printf 'fixture %s\n' "$version" > "$root/commands/mefisto:fixture.md"
    jq -n --arg version "$version" '{schemaVersion:1,runtime:"opencode",version:$version,commit:"0123456789abcdef0123456789abcdef01234567",minimumRuntimeVersion:"1.18.29"}' > "$root/mefisto-manifest.json"
}
envelope() {
    jq -cn --arg platform "$1" --arg osHome "$2" --arg home "$3" --argjson data "$4" --argjson config "$5" --argjson override "$6" \
        '{schemaVersion:1,platform:$platform,osHome:$osHome,home:$home,xdgDataHome:$data,xdgConfigHome:$config,opencodeConfigDir:$override}'
}
invoke() {
    local input="$1" root="$2"
    : > "$ERR"
    OUT="$(printf '%s' "$input" | opencode_resource_roots "$root" 2> "$ERR")"; RC=$?
}
write_ledger() {
    local config="$1" release="$2" path="${3:-commands/mefisto:fixture.md}"
    mkdir -p "$config/commands"
    jq -n --arg release "$release" --arg path "$path" '{schemaVersion:1,release:$release,paths:[$path],directories:[".","commands"]}' > "$config/.mefisto-projection.json"
}

START_PWD="$PWD"; CALLER_SENTINEL='sin-cambios'
SOURCE_OUTPUT="$(source "$LIB")"
[ -z "$SOURCE_OUTPUT" ] && [ "$PWD" = "$START_PWD" ] && [ "$CALLER_SENTINEL" = sin-cambios ] && pass 'source no produce salida ni altera al caller' || fail 'source tuvo efectos laterales'
source "$PATHS"; source "$LIB"

OS_HOME="$WORK/os home"; HOME_SENTINEL="$WORK/home del matcher que no debe usarse"
XDG_DATA="$WORK/XDG data"; XDG_CONFIG="$WORK/XDG config"; CONFIG_OVERRIDE="$WORK/config override"
mkdir -p "$OS_HOME" "$HOME_SENTINEL"
while IFS= read -r item; do
    NAME="$(jq -r .name <<< "$item")"; PLATFORM="$(jq -r .platform <<< "$item")"
    DATA_VALUE="$(jq -c --arg data "$XDG_DATA" 'if .xdgDataHome == "{{XDG_DATA}}" then $data else .xdgDataHome end' <<< "$item")"
    CONFIG_VALUE="$(jq -c --arg config "$XDG_CONFIG" 'if .xdgConfigHome == "{{XDG_CONFIG}}" then $config else .xdgConfigHome end' <<< "$item")"
    OVERRIDE_VALUE="$(jq -c --arg override "$CONFIG_OVERRIDE" 'if .opencodeConfigDir == "{{CONFIG_OVERRIDE}}" then $override else .opencodeConfigDir end' <<< "$item")"
    if [ "$(jq -r '. // empty' <<< "$DATA_VALUE")" ]; then MEFISTO="$XDG_DATA/mefisto"; RUNTIME="$XDG_DATA/opencode"
    else MEFISTO="$OS_HOME$(jq -r .mefistoSuffix <<< "$item")"; RUNTIME="$OS_HOME$(jq -r .runtimeSuffix <<< "$item")"; fi
    if [ "$(jq -r '. // empty' <<< "$OVERRIDE_VALUE")" ]; then CONFIG="$CONFIG_OVERRIDE"
    elif [ "$(jq -r '. // empty' <<< "$CONFIG_VALUE")" ]; then CONFIG="$XDG_CONFIG/opencode"
    else CONFIG="$OS_HOME$(jq -r .configSuffix <<< "$item")"; fi
    make_release 1.2.3 "$MEFISTO"
    INPUT="$(envelope "$PLATFORM" "$OS_HOME" "$HOME_SENTINEL" "$DATA_VALUE" "$CONFIG_VALUE" "$OVERRIDE_VALUE")"
    invoke "$INPUT" "$MEFISTO/releases/1.2.3"
    [ "$RC" -eq 0 ] && [ ! -s "$ERR" ] && jq -e --arg mefisto "$MEFISTO" --arg config "$CONFIG" --arg runtime "$RUNTIME" \
        '.status == "resolved" and .paths.mefistoDataRoot.logicalRoot == $mefisto and .paths.configRoot.logicalRoot == $config and .paths.runtimeDataRoot.logicalRoot == $runtime and .paths.toolOutputRoot.logicalRoot == ($runtime + "/tool-output") and .paths.toolOutputRoot.exists == false' <<< "$OUT" >/dev/null \
        && pass "$NAME" || fail "$NAME"
done < <(jq -c '.[]' "$CASES")

# El resto de los escenarios comparte las roots XDG con espacios.
MEFISTO="$XDG_DATA/mefisto"; CONFIG="$XDG_CONFIG/opencode"; RUNTIME="$XDG_DATA/opencode"
INPUT="$(envelope darwin "$OS_HOME" "$HOME_SENTINEL" "$(jq -Rn --arg value "$XDG_DATA" '$value')" "$(jq -Rn --arg value "$XDG_CONFIG" '$value')" null)"
mkdir -p "$RUNTIME/tool-output/session-a" "$RUNTIME/tool-output/session-b" "$RUNTIME/auth" "$RUNTIME/log" "$RUNTIME/storage"
printf 'sensible\n' > "$RUNTIME/tool-output/session-a/result"; printf 'vecino\n' > "$RUNTIME/auth/secret"
invoke "$INPUT" "$MEFISTO/releases/1.2.3"
assert_json "$OUT" 'solo tool-output aparece como root candidato dentro de datos globales' --arg runtime "$RUNTIME" \
    '.paths.toolOutputRoot.exists == true and ([.paths[] | .logicalRoot | select(startswith($runtime + "/"))] == [$runtime + "/tool-output"]) and (tostring | (contains("session-a") or contains("auth/secret")) | not)'

for field in xdgDataHome xdgConfigHome; do
    BAD="$(jq --arg field "$field" '.[$field]="relative"' <<< "$INPUT")"; invoke "$BAD" "$MEFISTO/releases/1.2.3"
    [ "$RC" -eq 1 ] && jq -e '.status == "conflict" and (.diagnostics | all(keys == ["code"]))' <<< "$OUT" >/dev/null && [ ! -s "$ERR" ] && pass "$field relativo produce envelope sanitizado" || fail "$field relativo no fue rechazado"
done
BAD="$(jq '.opencodeConfigDir=""' <<< "$INPUT")"; invoke "$BAD" "$MEFISTO/releases/1.2.3"
[ "$RC" -eq 1 ] && jq -e 'any(.diagnostics[]; .code == "EMPTY_OPENCODE_CONFIG_DIR")' <<< "$OUT" >/dev/null && pass 'override config vacio difiere de ausente' || fail 'override config vacio no fue conflicto'
BAD="$(jq '.opencodeConfigDir="__ABSENT__"' <<< "$INPUT")"; invoke "$BAD" "$MEFISTO/releases/1.2.3"
[ "$RC" -eq 1 ] && jq -e 'any(.diagnostics[]; .code == "RELATIVE_OPENCODE_CONFIG_DIR")' <<< "$OUT" >/dev/null && pass 'valor del override no colisiona con marcadores internos' || fail 'override fue confundido con ausencia'
BAD="$(jq '.xdgDataHome="/control\u000a"' <<< "$INPUT")"; invoke "$BAD" "$MEFISTO/releases/1.2.3"
[ "$RC" -eq 1 ] && jq -e 'any(.diagnostics[]; .code == "INVALID_XDG_DATA_HOME")' <<< "$OUT" >/dev/null && pass 'override no representable no se adivina' || fail 'override no representable fue aceptado'

invoke '{' "$MEFISTO/releases/1.2.3"; [ "$RC" -eq 2 ] && [ -z "$OUT" ] && [ ! -s "$ERR" ] && pass 'protocolo invalido retorna 2 sin salida lateral' || fail 'protocolo invalido filtro diagnostico'
invoke "$INPUT" relative; [ "$RC" -eq 1 ] && jq -e 'any(.diagnostics[]; .code == "INVALID_LOADED_RELEASE_ROOT")' <<< "$OUT" >/dev/null && pass 'root cargado relativo es conflicto de dominio' || fail 'root cargado relativo fue aceptado'

make_release 2.0.0 "$MEFISTO"; ln -s releases/2.0.0 "$MEFISTO/active"
invoke "$INPUT" "$MEFISTO/releases/1.2.3"
[ "$RC" -eq 0 ] && jq -e '.release.version == "1.2.3" and any(.diagnostics[]; .code == "ACTIVE_RELEASE_DRIFT")' <<< "$OUT" >/dev/null && pass 'active distinto no sustituye la release cargada' || fail 'active sustituyo la release cargada'

cp "$MEFISTO/releases/1.2.3/mefisto-manifest.json" "$WORK/manifest.valid"
printf '{\n' > "$MEFISTO/releases/1.2.3/mefisto-manifest.json"; invoke "$INPUT" "$MEFISTO/releases/1.2.3"
[ "$RC" -eq 1 ] && jq -e 'any(.diagnostics[]; .code == "INVALID_LOADED_RELEASE_MANIFEST")' <<< "$OUT" >/dev/null && pass 'manifiesto invalido es conflicto' || fail 'manifiesto invalido fue aceptado'
cp "$WORK/manifest.valid" "$MEFISTO/releases/1.2.3/mefisto-manifest.json"

OUTSIDE="$WORK/fuera del almacen"; make_release 1.2.3 "$OUTSIDE"
invoke "$INPUT" "$OUTSIDE/releases/1.2.3"
[ "$RC" -eq 1 ] && jq -e 'any(.diagnostics[]; .code == "LOADED_RELEASE_NOT_IN_STORE")' <<< "$OUT" >/dev/null && pass 'release fuera del almacen se rechaza' || fail 'release externa fue aceptada'
make_release 3.0.0 "$OUTSIDE"; ln -s "$OUTSIDE/releases/3.0.0" "$MEFISTO/releases/3.0.0"
invoke "$INPUT" "$OUTSIDE/releases/3.0.0"
[ "$RC" -eq 1 ] && jq -e 'any(.diagnostics[]; .code == "LOADED_RELEASE_NOT_IN_STORE")' <<< "$OUT" >/dev/null && pass 'entrada enlazada fuera del almacen no legitima una release' || fail 'alias externo fue aceptado como release'
ln -s "$WORK/no-existe" "$WORK/release rota"; invoke "$INPUT" "$WORK/release rota"
[ "$RC" -eq 1 ] && jq -e 'any(.diagnostics[]; .code == "LOADED_RELEASE_UNRESOLVABLE")' <<< "$OUT" >/dev/null && pass 'root roto se distingue de identidad invalida' || fail 'root roto no fue diagnosticado'

REAL_DATA="$WORK/data real"; ALIAS_DATA="$WORK/data alias"; make_release 4.0.0 "$REAL_DATA/mefisto"; ln -s "$REAL_DATA" "$ALIAS_DATA"
REAL_DATA_PHYSICAL="$(cd "$REAL_DATA" && pwd -P)"
ALIAS_INPUT="$(jq --arg data "$ALIAS_DATA" '.xdgDataHome=$data' <<< "$INPUT")"; invoke "$ALIAS_INPUT" "$ALIAS_DATA/mefisto/releases/4.0.0"
[ "$RC" -eq 0 ] && jq -e --arg logical "$ALIAS_DATA/mefisto" --arg physical "$REAL_DATA_PHYSICAL/mefisto" '.paths.mefistoDataRoot.logicalRoot == $logical and .paths.mefistoDataRoot.physicalRoot == $physical and .release.root == ($physical + "/releases/4.0.0")' <<< "$OUT" >/dev/null && pass 'conserva diferencia logica y fisica' || fail 'perdio identidad logica o fisica'

rm "$MEFISTO/active"; ln -s releases/1.2.3 "$MEFISTO/active"
write_ledger "$CONFIG" 1.2.3; ln -s "$MEFISTO/active/commands/mefisto:fixture.md" "$CONFIG/commands/mefisto:fixture.md"
invoke "$INPUT" "$MEFISTO/releases/1.2.3"
[ "$RC" -eq 0 ] && jq -e '.projection.status == "aligned" and (.projection.ledgerDigest | test("^[0-9a-f]{64}$"))' <<< "$OUT" >/dev/null && pass 'ledger y metadata propios quedan aligned' || fail 'proyeccion valida no quedo aligned'
rm "$CONFIG/commands/mefisto:fixture.md"; invoke "$INPUT" "$MEFISTO/releases/1.2.3"
[ "$RC" -eq 1 ] && jq -e '.projection.status == "conflict" and any(.diagnostics[]; .code == "PROJECTION_LINK_MISSING")' <<< "$OUT" >/dev/null && pass 'enlace ausente se distingue de aligned' || fail 'enlace ausente no fue conflicto'
ln -s "$MEFISTO/releases/1.2.3/commands/mefisto:fixture.md" "$CONFIG/commands/mefisto:fixture.md"; invoke "$INPUT" "$MEFISTO/releases/1.2.3"
[ "$RC" -eq 1 ] && jq -e 'any(.diagnostics[]; .code == "PROJECTION_LINK_FOREIGN")' <<< "$OUT" >/dev/null && pass 'enlace extranjero se distingue aunque resuelva al mismo archivo' || fail 'enlace extranjero fue aceptado'
rm "$CONFIG/commands/mefisto:fixture.md" "$MEFISTO/active"; ln -s "$MEFISTO/active/commands/mefisto:fixture.md" "$CONFIG/commands/mefisto:fixture.md"; ln -s releases/2.0.0 "$MEFISTO/active"; invoke "$INPUT" "$MEFISTO/releases/1.2.3"
[ "$RC" -eq 1 ] && jq -e 'any(.diagnostics[]; .code == "PROJECTION_LINK_TARGET_DRIFT") and any(.diagnostics[]; .code == "ACTIVE_RELEASE_DRIFT")' <<< "$OUT" >/dev/null && pass 'cambio de target se distingue de enlace extranjero' || fail 'cambio de target fue aceptado'
rm "$MEFISTO/active"; ln -s releases/1.2.3 "$MEFISTO/active"
jq '.release="2.0.0"' "$CONFIG/.mefisto-projection.json" > "$WORK/ledger.tmp"; cp "$WORK/ledger.tmp" "$CONFIG/.mefisto-projection.json"; invoke "$INPUT" "$MEFISTO/releases/1.2.3"
[ "$RC" -eq 0 ] && jq -e '.projection.status == "drift" and any(.diagnostics[]; .code == "PROJECTION_RELEASE_DRIFT")' <<< "$OUT" >/dev/null && pass 'ledger de otra release queda drift sin repararse' || fail 'drift de ledger fue confundido'
jq '.paths=["../escape"]' "$CONFIG/.mefisto-projection.json" > "$WORK/ledger.tmp"; cp "$WORK/ledger.tmp" "$CONFIG/.mefisto-projection.json"; invoke "$INPUT" "$MEFISTO/releases/1.2.3"
[ "$RC" -eq 1 ] && jq -e '.projection.status == "conflict" and any(.diagnostics[]; .code == "INVALID_PROJECTION_PATH")' <<< "$OUT" >/dev/null && pass 'ledger drift tambien conserva validaciones estructurales' || fail 'ledger drift omitio validar rutas'
rm "$CONFIG/.mefisto-projection.json" "$CONFIG/commands/mefisto:fixture.md"; invoke "$INPUT" "$MEFISTO/releases/1.2.3"
[ "$RC" -eq 0 ] && jq -e '.projection == {status:"absent",ledgerDigest:null}' <<< "$OUT" >/dev/null && pass 'ledger ausente queda absent' || fail 'ausencia de ledger no fue preservada'

SOURCE="$(command cat "$LIB")"
case "$SOURCE" in *project-opencode-release*|*projection-status*|*opencode.json*|*'find '*|*'curl '*) fail 'biblioteca invoca superficies o walkers prohibidos' ;; *) pass 'biblioteca no usa proyector, red ni enumera datos globales' ;; esac
[ -f "$RUNTIME/tool-output/session-a/result" ] && [ -f "$RUNTIME/auth/secret" ] && [ ! -e "$RUNTIME/tool-output/nuevo" ] && pass 'descubrimiento no modifica datos, config ni tool-output' || fail 'descubrimiento produjo escrituras'

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
