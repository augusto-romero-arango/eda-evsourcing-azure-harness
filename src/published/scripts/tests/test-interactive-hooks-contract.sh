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
for index in 1 2 3 4 5 6; do
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

echo "[sessions.jsonl] fixtures de compatibilidad y append-only"
SESSION_FIXTURES="$FIXTURES/sessions"
for fixture in "$SESSION_FIXTURES"/*.jsonl; do
    if jq -e . "$fixture" >/dev/null 2>&1; then
        pass "$(basename "$fixture"): JSONL valido"
    else
        fail "$(basename "$fixture"): JSONL invalido"
    fi
done

started_keys='["cwd","harness_commit","harness_version","model","record_type","runtime","session_id","source","timestamp","transcript_path"]'
observed_keys='["harness_commit","harness_version","model","record_type","runtime","session_id","timestamp"]'
for fixture in started-complete.jsonl started-null-model.jsonl missing-manifest.jsonl; do
    if jq -e --argjson keys "$started_keys" 'keys == $keys and .record_type == "session.started" and (.runtime == "claude" or .runtime == "opencode") and (.model == null or (type == "string" and length > 0)) and (.harness_version == null or type == "string") and (.harness_commit == null or test("^[0-9a-f]{40}$"))' "$SESSION_FIXTURES/$fixture" >/dev/null 2>&1; then
        pass "$fixture: inicio con identidad completa o degradada"
    else
        fail "$fixture: inicio no cumple el contrato"
    fi
done
if jq -e --argjson keys "$observed_keys" 'keys == $keys and .record_type == "session.model-observed" and (.model | type == "string" and length > 0) and .runtime == "opencode"' "$SESSION_FIXTURES/first-model-observation.jsonl" >/dev/null 2>&1; then
    pass "first-model-observation.jsonl: observacion opaca no vacia"
else
    fail "first-model-observation.jsonl: observacion invalida"
fi
if jq -s '.[0].model == .[1].model and .[2].model != .[1].model and ([.[] | .record_type] == ["session.started", "session.model-observed", "session.model-observed"])' "$SESSION_FIXTURES/model-repeat-and-change.jsonl" >/dev/null 2>&1; then
    pass "model-repeat-and-change.jsonl: A repetido se omite y A->B conserva ambos hechos"
else
    fail "model-repeat-and-change.jsonl: semantica append-only invalida"
fi
if jq -s 'length == 2 and (.[0] | has("record_type") | not) and .[1].record_type == "session.started"' "$SESSION_FIXTURES/legacy-and-new.jsonl" >/dev/null 2>&1; then
    pass "legacy-and-new.jsonl: la linea historica se conserva sin migracion"
else
    fail "legacy-and-new.jsonl: compatibilidad historica invalida"
fi

echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
