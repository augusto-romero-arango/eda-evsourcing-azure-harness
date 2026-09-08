#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
HOOKS="$REPO_ROOT/src/published/hooks"
VALIDATOR="$REPO_ROOT/src/published/scripts/validate-interactive-hooks.sh"
FIXTURES="$HOOKS/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "[pre] contrato y schema"
for file in "$HOOKS/interactive-hooks.json" "$HOOKS/interactive-hooks.schema.json" "$VALIDATOR"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT"/}" || fail "falta ${file#"$REPO_ROOT"/}"; done
jq empty "$HOOKS/interactive-hooks.schema.json" >/dev/null 2>&1 && pass "schema JSON valido" || fail "schema JSON invalido"
bash -n "$VALIDATOR" && pass "validador Bash valido" || fail "validador Bash invalido"

echo "[valid] descriptor y fixture"
out=$(bash "$VALIDATOR" "$HOOKS/interactive-hooks.json" 2>&1); [ $? -eq 0 ] && pass "descriptor vigente" || fail "descriptor vigente: $out"
out=$(bash "$VALIDATOR" "$FIXTURES/valid/interactive-hooks.json" 2>&1); [ $? -eq 0 ] && pass "fixture valido" || fail "fixture valido: $out"

expected_error() {
    case "$1" in
        action-without-contract.jq) echo "accion sin contrato" ;;
        additional-persisted-field.jq) echo "allowlist de campos persistibles divergente" ;;
        delivery-divergent.jq) echo "delivery divergente" ;;
        duplicate-destination.jq) echo "destinos duplicados" ;;
        duplicate-id.jq) echo "id duplicado" ;;
        extra-property.jq) echo "propiedad adicional o faltante" ;;
        legacy-destination-on-other-binding.jq) echo "destinos no coinciden con su contrato" ;;
        missing-canonical-destination.jq) echo "falta el destino canonico obligatorio" ;;
        runtime-reference.jq) echo "referencia a runtime" ;;
        sensitive-field.jq) echo "campo persistible sensible" ;;
        unknown-action.jq) echo "accion desconocida" ;;
        unknown-destination.jq) echo "destino desconocido" ;;
        unknown-field.jq) echo "allowlist de campos persistibles divergente" ;;
        unknown-pair.jq) echo "par signal/action desconocido" ;;
        unknown-signal.jq) echo "signal desconocida" ;;
        *) echo "fixture sin expectativa" ;;
    esac
}

for fixture in "$FIXTURES"/invalid/*.jq; do
    candidate="$WORK/$(basename "$fixture" .jq).json"
    jq -f "$fixture" "$FIXTURES/valid/interactive-hooks.json" > "$candidate"
    out=$(bash "$VALIDATOR" "$candidate" 2>&1)
    rc=$?
    expected=$(expected_error "$(basename "$fixture")")
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "$expected"; then
        pass "$(basename "$fixture"): $expected"
    elif [ "$rc" -eq 0 ]; then
        fail "$(basename "$fixture") fue aceptado"
    else
        fail "$(basename "$fixture") fue rechazado por otro motivo: $out"
    fi
done

echo "[legacy-release-marker] reservado a record-active-release"
for index in 1 2 3 4 5; do
    candidate="$WORK/legacy-release-marker-$index.json"
    jq ".bindings[$index].destinations += [\"legacy-release-marker\"]" "$FIXTURES/valid/interactive-hooks.json" > "$candidate"
    out=$(bash "$VALIDATOR" "$candidate" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "destinos no coinciden con su contrato"; then
        pass "binding $index rechaza legacy-release-marker"
    elif [ "$rc" -eq 0 ]; then
        fail "binding $index acepto legacy-release-marker"
    else
        fail "binding $index rechazo legacy-release-marker por otro motivo: $out"
    fi
done

echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
