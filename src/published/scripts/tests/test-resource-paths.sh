#!/usr/bin/env bash
# Pruebas locales de observaciones puntuales; no certifican un walker seguro.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
LIBRARY="$REPO_ROOT/src/published/scripts/lib/resource-paths.sh"
CORPUS="$HERE/fixtures/resource-paths/relative-corpus.json"
WORK="$(mktemp -d)"; trap 'chmod -R u+rwx "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_json() {
    local output="$1" label="$2"
    shift 2
    jq -e "$@" >/dev/null <<< "$output" && pass "$label" || fail "$label"
}

source "$LIBRARY"
START_PWD="$PWD"
MEFISTO_RUNTIME='runtime-sentinel'; MEFISTO_PACKAGE_ROOT='root-sentinel'
mkdir -p "$WORK/raiz con espacios/niño/directorio" "$WORK/raiz con espacios/otro" "$WORK/relativos/base/left/child" "$WORK/relativos/base/right" "$WORK/relativos/base/same"
printf 'archivo\n' > "$WORK/raiz con espacios/archivo"
ln -s "niño/directorio" "$WORK/raiz con espacios/enlace-directorio"
ln -s "niño" "$WORK/raiz con espacios/ancestro-enlazado"
ln -s "ausente" "$WORK/raiz con espacios/enlace-roto"
ln -s ciclo-b "$WORK/raiz con espacios/ciclo-a"
ln -s ciclo-a "$WORK/raiz con espacios/ciclo-b"
ROOT_PHYSICAL="$(cd "$WORK/raiz con espacios" && pwd -P)"

OUTPUT="$(resource_path_resolve "$WORK/raiz con espacios/niño/directorio" existing)"; RC=$?
[ "$RC" -eq 0 ] && assert_json "$OUTPUT" 'resuelve directorio existente con espacios y Unicode' --arg logical "$WORK/raiz con espacios/niño/directorio" --arg physical "$ROOT_PHYSICAL/niño/directorio" '.logicalRoot == $logical and .physicalRoot == $physical and .exists == true' || fail 'no resuelve directorio existente'
OUTPUT="$(resource_path_resolve "$WORK//raiz con espacios/niño/directorio/" existing)"; RC=$?
[ "$RC" -eq 0 ] && assert_json "$OUTPUT" 'normaliza separadores y barra final en la raiz logica' --arg logical "$WORK/raiz con espacios/niño/directorio" '.logicalRoot == $logical' || fail 'no normaliza la raiz logica'
OUTPUT="$(resource_path_resolve "$WORK/raiz con espacios/enlace-directorio" existing)"; RC=$?
[ "$RC" -eq 0 ] && assert_json "$OUTPUT" 'resuelve enlace a directorio sin perder la raiz logica' --arg logical "$WORK/raiz con espacios/enlace-directorio" --arg physical "$ROOT_PHYSICAL/niño/directorio" '.logicalRoot == $logical and .physicalRoot == $physical and .exists == true' || fail 'no resuelve enlace a directorio'
OUTPUT="$(resource_path_resolve "$WORK/raiz con espacios/ancestro-enlazado/directorio" existing)"; RC=$?
[ "$RC" -eq 0 ] && assert_json "$OUTPUT" 'resuelve ancestro enlazado' --arg physical "$ROOT_PHYSICAL/niño/directorio" '.physicalRoot == $physical' || fail 'no resuelve ancestro enlazado'
OUTPUT="$(resource_path_resolve "$WORK/raiz con espacios/ancestro-enlazado/futuro/recurso" planned)"; RC=$?
[ "$RC" -eq 0 ] && assert_json "$OUTPUT" 'planned conserva sufijo ausente sin crearlo' --arg physical "$ROOT_PHYSICAL/niño/futuro/recurso" '.physicalRoot == $physical and .exists == false' || fail 'planned no conserva sufijo ausente'
[ ! -e "$WORK/raiz con espacios/niño/futuro" ] && pass 'planned no crea directorios' || fail 'planned escribio el filesystem'
for candidate in "$WORK/raiz con espacios/enlace-roto" "$WORK/raiz con espacios/ciclo-a" "$WORK/raiz con espacios/archivo"; do
    resource_path_resolve "$candidate" planned >/dev/null 2>/dev/null; [ "$?" -eq 1 ] && pass 'planned no confunde un objeto no resoluble con un sufijo ausente' || fail 'planned acepto un objeto no resoluble'
    resource_path_resolve "$candidate" existing >/dev/null 2>/dev/null; [ "$?" -eq 1 ] && pass 'error de filesystem no se confunde con ruta existente' || fail 'error de filesystem tiene codigo incorrecto'
done
resource_path_resolve "$WORK/raiz con espacios/ausente" existing >/dev/null 2>"$WORK/diagnostico"; RC=$?
[ "$RC" -eq 1 ] && [ "$(< "$WORK/diagnostico")" = 'resource-paths: FILESYSTEM_UNRESOLVABLE' ] && pass 'ausencia existing usa codigo y diagnostico estables sin filtrar la ruta' || fail 'ausencia existing no respeta el protocolo de error'
mkdir "$WORK/sin-acceso"; chmod 000 "$WORK/sin-acceso"
if [ ! -x "$WORK/sin-acceso" ]; then
    resource_path_resolve "$WORK/sin-acceso/hijo" planned >/dev/null 2>/dev/null; [ "$?" -eq 1 ] && pass 'fallo de acceso no se confunde con sufijo planned' || fail 'fallo de acceso tiene codigo incorrecto'
else
    pass 'entorno con privilegios permite omitir fixture de acceso denegado'
fi
chmod 700 "$WORK/sin-acceso"

while IFS= read -r item; do
    BASE="$WORK/relativos/$(jq -r '.base' <<< "$item")"; TARGET="$WORK/relativos/$(jq -r '.target' <<< "$item")"; EXPECTED="$(jq -r '.relative' <<< "$item")"
    ACTUAL="$(resource_path_relative "$BASE" "$TARGET")"; RC=$?
    NODE_EXPECTED="$(node -e 'process.stdout.write(require("path").relative(process.argv[1], process.argv[2]))' "$BASE" "$TARGET")"
    [ "$RC" -eq 0 ] && [ "$(jq -r . <<< "$ACTUAL")" = "$EXPECTED" ] && [ "$(jq -r . <<< "$ACTUAL")" = "$NODE_EXPECTED" ] && pass 'relative coincide con el corpus y node:path.relative' || fail 'relative difiere del corpus o Node'
done < <(jq -c '.[]' "$CORPUS")
resource_path_contains "$WORK/relativos/base" "$WORK/relativos/base"; [ "$?" -eq 0 ] && pass 'contains acepta igualdad' || fail 'contains rechazo igualdad'
resource_path_contains "$WORK/relativos/base" "$WORK/relativos/base/right"; [ "$?" -eq 0 ] && pass 'contains acepta descendencia por segmentos' || fail 'contains rechazo descendencia'
resource_path_contains "$WORK/relativos/base" "$WORK/relativos/baseball"; [ "$?" -eq 1 ] && pass 'contains respeta limite de segmento' || fail 'contains confundio prefijos'
for invalid in relativo "$WORK/raiz con espacios/./niño" "$WORK/raiz con espacios/../niño" $'/control\n'; do
    resource_path_resolve "$invalid" existing >/dev/null 2>/dev/null; [ "$?" -eq 2 ] && pass 'resolve rechaza input ambiguo o no absoluto' || fail 'resolve acepto input invalido'
done
resource_path_relative relativo /destino >/dev/null 2>/dev/null; [ "$?" -eq 2 ] && pass 'relative rechaza input no absoluto' || fail 'relative acepto input invalido'
resource_path_contains /padre /padre/../hijo >/dev/null 2>/dev/null; [ "$?" -eq 2 ] && pass 'contains rechaza componentes ambiguos' || fail 'contains acepto input invalido'
resource_path_resolve /destino invalido >/dev/null 2>"$WORK/diagnostico"; RC=$?
[ "$RC" -eq 2 ] && [ "$(< "$WORK/diagnostico")" = 'resource-paths: INVALID_MODE' ] && pass 'resolve reserva codigo 2 para modo invalido' || fail 'resolve no rechazo un modo invalido'
resource_path_resolve /destino >/dev/null 2>"$WORK/diagnostico"; RC=$?
[ "$RC" -eq 2 ] && [ "$(< "$WORK/diagnostico")" = 'resource-paths: INVALID_ARGUMENTS' ] && pass 'resolve valida aridad sin inspeccionar el filesystem' || fail 'resolve no rechazo aridad invalida'
LITERAL="$WORK/\$(touch $WORK/no-ejecutar)"; resource_path_resolve "$LITERAL" planned >/dev/null 2>/dev/null
[ ! -e "$WORK/no-ejecutar" ] && pass 'resolve conserva interpolaciones como caracteres literales' || fail 'resolve ejecuto una interpolacion'
OUTPUT="$(resource_path_relative /ruta/que/no/existe /otra/tampoco)"; RC=$?
[ "$RC" -eq 0 ] && [ "$(jq -r . <<< "$OUTPUT")" = '../../../../otra/tampoco' ] && pass 'relative opera lexicalmente sin resolver el filesystem' || fail 'relative consulto el filesystem'
resource_path_contains / /cualquier/ruta; [ "$?" -eq 0 ] && pass 'contains trata la raiz como ancestro' || fail 'contains rechazo descendencia de la raiz'
resource_path_relative /base /base >/dev/null
[ "$?" -eq 0 ] && [ "$PWD" = "$START_PWD" ] && [ "$MEFISTO_RUNTIME" = runtime-sentinel ] && [ "$MEFISTO_PACKAGE_ROOT" = root-sentinel ] && pass 'consultas preservan cwd y estado de runtime del caller' || fail 'consulta cambio estado del caller'

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
