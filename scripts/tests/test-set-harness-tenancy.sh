#!/usr/bin/env bash
# test-set-harness-tenancy.sh -- Contrato del setter de tenancy del consumidor.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/set-harness-tenancy.sh"
FIXTURES="$HERE/fixtures/set-harness-tenancy"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

new_repo() { mkdir -p "$1"; git -C "$1" init -q; }
run_setter() { (cd "$1" && bash "${@:2}") >"$WORK/out" 2>"$WORK/err"; }
copy_config() { mkdir -p "$(dirname "$2")"; cp "$FIXTURES/$1" "$2"; }

echo '[1] Canonico: preserva datos y devuelve JSON de exito'
CANON="$WORK/canon"; new_repo "$CANON"
copy_config canonical.json "$CANON/.mefisto/harness.config.json"
if run_setter "$CANON" "$SCRIPT" --strategy multi-tenant-header \
    && jq -e '.schemaVersion == 1 and .strategy == "multi-tenant-header" and .changed == true and (.configPath | endswith("/.mefisto/harness.config.json"))' "$WORK/out" >/dev/null \
    && jq -e '.tenancy.strategy == "multi-tenant-header" and .tenancy.extra == "preservar" and .other.value == true' "$CANON/.mefisto/harness.config.json" >/dev/null; then
    pass 'actualiza solo la estrategia y devuelve changed=true'
else fail "canonico: $(<"$WORK/err")"; fi

echo '[2] Canonico y legacy: el canonico conserva autoridad'
BOTH="$WORK/both"; new_repo "$BOTH"
copy_config canonical.json "$BOTH/.mefisto/harness.config.json"; copy_config legacy.json "$BOTH/.claude/harness.config.json"
LEGACY_BEFORE="$(cksum "$BOTH/.claude/harness.config.json")"
if run_setter "$BOTH" "$SCRIPT" --strategy multi-tenant-header \
    && grep -Fq 'se ignora el legacy' "$WORK/err" \
    && [ "$LEGACY_BEFORE" = "$(cksum "$BOTH/.claude/harness.config.json")" ]; then
    pass 'advierte coexistencia y solo escribe el canonico'
else fail "coexistencia: $(<"$WORK/err")"; fi

echo '[3] Solo legacy, invalido y ausente no escriben'
LEGACY="$WORK/legacy"; new_repo "$LEGACY"; copy_config legacy.json "$LEGACY/.claude/harness.config.json"
LEGACY_BEFORE="$(cksum "$LEGACY/.claude/harness.config.json")"
if ! run_setter "$LEGACY" "$SCRIPT" --strategy multi-tenant-header \
    && [ "$LEGACY_BEFORE" = "$(cksum "$LEGACY/.claude/harness.config.json")" ] \
    && [ ! -e "$LEGACY/.mefisto/harness.config.json" ]; then pass 'solo legacy se rechaza sin migrar'; else fail 'solo legacy fue alterado'; fi
INVALID="$WORK/invalid"; new_repo "$INVALID"; copy_config invalid.json "$INVALID/.mefisto/harness.config.json"
INVALID_BEFORE="$(cksum "$INVALID/.mefisto/harness.config.json")"
if ! run_setter "$INVALID" "$SCRIPT" --strategy multi-tenant-header \
    && [ "$INVALID_BEFORE" = "$(cksum "$INVALID/.mefisto/harness.config.json")" ]; then pass 'config invalido no deja escritura parcial'; else fail 'config invalido fue alterado'; fi
MISSING="$WORK/missing"; new_repo "$MISSING"
if ! run_setter "$MISSING" "$SCRIPT" --strategy multi-tenant-header \
    && [ ! -e "$MISSING/.mefisto/harness.config.json" ]; then pass 'config ausente no se crea'; else fail 'config ausente fue creado'; fi

echo '[4] Valor vigente y error de temporal no reescriben'
CURRENT="$WORK/current"; new_repo "$CURRENT"; copy_config current.json "$CURRENT/.mefisto/harness.config.json"
CURRENT_BEFORE="$(cksum "$CURRENT/.mefisto/harness.config.json")"
if run_setter "$CURRENT" "$SCRIPT" --strategy multi-tenant-header \
    && jq -e '.changed == false' "$WORK/out" >/dev/null \
    && [ "$CURRENT_BEFORE" = "$(cksum "$CURRENT/.mefisto/harness.config.json")" ]; then pass 'valor vigente devuelve changed=false sin reescribir'; else fail 'valor vigente se reescribio'; fi
BROKEN="$WORK/broken"; new_repo "$BROKEN"; copy_config canonical.json "$BROKEN/.mefisto/harness.config.json"; touch "$BROKEN/state-file"
BROKEN_BEFORE="$(cksum "$BROKEN/.mefisto/harness.config.json")"
if ! (cd "$BROKEN" && MEFISTO_STATE_DIR="$BROKEN/state-file" bash "$SCRIPT" --strategy multi-tenant-header) >"$WORK/out" 2>"$WORK/err" \
    && [ "$BROKEN_BEFORE" = "$(cksum "$BROKEN/.mefisto/harness.config.json")" ]; then pass 'fallo de temporal no altera el destino'; else fail 'fallo de temporal altero el destino'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
