#!/usr/bin/env bash
# Contrato del comando runtimes neutral y sus adaptaciones publicadas.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/commands/runtimes.md"
CLAUDE="$REPO_ROOT/dist/claude/commands/runtimes.md"
OPENCODE="$REPO_ROOT/dist/opencode/commands/mefisto:runtimes.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[fuente] contrato neutral'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "command" and .id == "runtimes" and .arguments == "[status | enable opencode | disable opencode]" and (keys | sort) == ["arguments", "description", "id", "kind"]' >/dev/null; then pass 'metadata neutral sin perfil ni runtime'; else fail 'metadata neutral invalida'; fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
contains "$body" '{{mefisto:lifecycle-launcher}}' 'delegacion de launcher adaptable presente'
contains "$body" 'Los argumentos de la invocacion estan en: `$ARGUMENTS`' 'consume los argumentos reales de la invocacion'
contains "$body" 'Antes de ejecutar cualquier bloque' 'valida argumentos antes de consultar estado'
contains "$body" 'Uso: /mefisto:runtimes [status | enable opencode | disable opencode]' 'uso unico para entrada invalida'
contains "$body" 'selector' 'sin argumentos ofrece selector confirmado'
contains "$body" 'unavailable' 'declara unavailable'
contains "$body" 'installed-disabled' 'declara installed-disabled'
contains "$body" 'Normaliza el estado estructurado `disabled` como `installed-disabled`' 'normaliza disabled del launcher'
contains "$body" 'enabled' 'declara enabled'
contains "$body" 'stale' 'declara stale'
contains "$body" 'conflict' 'declara conflict'
contains "$body" 'configRoot' 'muestra raiz efectiva'
contains "$body" 'activeVersion' 'muestra release activa'
contains "$body" 'ledgerRelease' 'muestra release del ledger'
contains "$body" 'administrado externamente' 'declara lifecycle externo del plugin'
contains "$body" 'Claude Code (plugin)' 'identifica el lifecycle externo sin simular simetria'
contains "$body" '"$MEFISTO_LIFECYCLE_LAUNCHER" project' 'enable usa solo proyeccion'
contains "$body" '"$MEFISTO_LIFECYCLE_LAUNCHER" deactivate' 'disable usa solo retirada de proyeccion'
contains "$body" 'No consulta red' 'enable no usa red'
contains "$body" '/mefisto:upgrade' 'remite upgrade si falta release activa'
contains "$body" 'dejara de estar disponible' 'advierte auto-desactivacion'
contains "$body" 'sin inspeccionar archivos de configuracion' 'estado no inspecciona configuracion ajena'
contains "$body" 'stores de autenticacion' 'estado no inspecciona stores de autenticacion'
contains "$body" 'una sola vez por invocacion' 'cada accion consulta estado una sola vez'
contains "$body" 'disabled:0' 'valida estado y codigo de salida conjuntamente'
contains "$body" 'no reproduzcas una respuesta invalida' 'respuesta no confiable no se filtra'
contains "$body" 'MEFISTO_LIFECYCLE_CONFIG_ROOT' 'unavailable conserva evidencia de raiz efectiva'
absent "$body" 'opencode.json' 'no inspecciona opencode.json'
VALIDATOR_FIXTURE="$(mktemp -d)/runtimes.md"
trap 'rm -rf "$(dirname "$VALIDATOR_FIXTURE")"' EXIT
cp "$SOURCE" "$VALIDATOR_FIXTURE"
printf '\nRuta prohibida: .opencode/commands\n' >> "$VALIDATOR_FIXTURE"
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$VALIDATOR_FIXTURE" >/dev/null 2>&1; then fail 'la excepcion de ids no permite rutas de runtime'; else pass 'la excepcion de ids no permite rutas de runtime'; fi

echo '[salidas] adaptadores'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
for file in "$CLAUDE" "$OPENCODE"; do
    rendered="$(< "$file")"
    contains "$rendered" 'MEFISTO_LIFECYCLE_LAUNCHER' "${file#"$REPO_ROOT/"} materializa launcher"
    contains "$rendered" 'projection-status' "${file#"$REPO_ROOT/"} materializa status"
    contains "$rendered" 'mefisto-opencode' "${file#"$REPO_ROOT/"} resuelve launcher estable"
    contains "$rendered" 'OPENCODE_CONFIG_DIR+x' "${file#"$REPO_ROOT/"} respeta config root alterno"
    contains "$rendered" 'MEFISTO_LIFECYCLE_CONFIG_ROOT' "${file#"$REPO_ROOT/"} expone raiz efectiva incluso unavailable"
    contains "$rendered" '$ARGUMENTS' "${file#"$REPO_ROOT/"} recibe argumentos del runtime"

    execution_root="$(dirname "$VALIDATOR_FIXTURE")/execution-${file##*/}"
    data_root="$execution_root/data"
    config_root="$execution_root/config alterno"
    mkdir -p "$data_root/mefisto/releases/1.2.3/bin" "$config_root"
    launcher="$data_root/mefisto/releases/1.2.3/bin/mefisto-opencode"
    stable_launcher="$data_root/mefisto/active/bin/mefisto-opencode"
    printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in' \
        'projection-status) printf '\''{"schemaVersion":1,"status":"%s","configRoot":"%s","activeVersion":"1.2.3","ledgerRelease":"1.1.0"}\n'\'' "${TEST_STATE:-stale}" "$OPENCODE_CONFIG_DIR"; [ "${TEST_STATE:-stale}" != conflict ] ;;' \
        '*) exit 1 ;;' 'esac' > "$launcher"
    chmod +x "$launcher"
    ln -s releases/1.2.3 "$data_root/mefisto/active"
    preamble="$(awk '$0 == "```bash" && !seen { seen=1; next } seen && $0 == "```" { exit } seen { print }' "$file")"
    binding="$execution_root/binding.sh"
    printf '%s\n%s\n' "$preamble" 'printf "%s|%s\n" "$MEFISTO_LIFECYCLE_LAUNCHER" "$MEFISTO_LIFECYCLE_CONFIG_ROOT"' > "$binding"
    resolved="$(HOME="$execution_root/home" XDG_DATA_HOME="$data_root" OPENCODE_CONFIG_DIR="$config_root" bash "$binding")"
    [ "$resolved" = "$stable_launcher|$config_root" ] && pass "${file#"$REPO_ROOT/"} ejecuta binding con config root alterno" || fail "${file#"$REPO_ROOT/"} no ejecuta binding con config root alterno (obtenido: $resolved; esperado: $stable_launcher|$config_root)"
    status_json="$(TEST_STATE=stale OPENCODE_CONFIG_DIR="$config_root" "$launcher" projection-status)"; rc=$?
    [ "$rc" -eq 0 ] && jq -e --arg root "$config_root" '.status == "stale" and .configRoot == $root' <<< "$status_json" >/dev/null && pass "${file#"$REPO_ROOT/"} consume estado stale estructurado" || fail "${file#"$REPO_ROOT/"} no consume estado stale estructurado"
    status_json="$(TEST_STATE=conflict OPENCODE_CONFIG_DIR="$config_root" "$launcher" projection-status)"; rc=$?
    [ "$rc" -eq 1 ] && jq -e '.status == "conflict"' <<< "$status_json" >/dev/null && pass "${file#"$REPO_ROOT/"} conserva conflicto con codigo no cero" || fail "${file#"$REPO_ROOT/"} no conserva conflicto estructurado"
done
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi
printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
