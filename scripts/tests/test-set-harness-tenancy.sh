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

echo '[4] Token ausente conserva el default o materializa el cambio solicitado'
DEFAULTED="$WORK/defaulted"; new_repo "$DEFAULTED"; copy_config without-token.json "$DEFAULTED/.mefisto/harness.config.json"
DEFAULTED_BEFORE="$(cksum "$DEFAULTED/.mefisto/harness.config.json")"
if run_setter "$DEFAULTED" "$SCRIPT" --strategy mono-tenant-transitorio \
    && jq -e '.strategy == "mono-tenant-transitorio" and .changed == false' "$WORK/out" >/dev/null \
    && [ "$DEFAULTED_BEFORE" = "$(cksum "$DEFAULTED/.mefisto/harness.config.json")" ]; then
    pass 'token ausente equivale al default sin reescribir'
else fail "token ausente/default: $(<"$WORK/err")"; fi
ABSENT="$WORK/absent"; new_repo "$ABSENT"; copy_config without-token.json "$ABSENT/.mefisto/harness.config.json"
if run_setter "$ABSENT" "$SCRIPT" --strategy multi-tenant-header \
    && jq -e '.changed == true' "$WORK/out" >/dev/null \
    && jq -e '.tenancy.strategy == "multi-tenant-header" and .other.value == true' "$ABSENT/.mefisto/harness.config.json" >/dev/null; then
    pass 'token ausente se crea cuando cambia respecto del default'
else fail "token ausente/cambio: $(<"$WORK/err")"; fi

echo '[5] Valor vigente y errores no reescriben ni emiten exito'
CURRENT="$WORK/current"; new_repo "$CURRENT"; copy_config current.json "$CURRENT/.mefisto/harness.config.json"
CURRENT_BEFORE="$(cksum "$CURRENT/.mefisto/harness.config.json")"
if run_setter "$CURRENT" "$SCRIPT" --strategy multi-tenant-header \
    && jq -e '.changed == false' "$WORK/out" >/dev/null \
    && [ "$CURRENT_BEFORE" = "$(cksum "$CURRENT/.mefisto/harness.config.json")" ]; then pass 'valor vigente devuelve changed=false sin reescribir'; else fail 'valor vigente se reescribio'; fi
BROKEN="$WORK/broken"; new_repo "$BROKEN"; copy_config canonical.json "$BROKEN/.mefisto/harness.config.json"; touch "$BROKEN/state-file"
BROKEN_BEFORE="$(cksum "$BROKEN/.mefisto/harness.config.json")"
if ! (cd "$BROKEN" && MEFISTO_STATE_DIR="$BROKEN/state-file" bash "$SCRIPT" --strategy multi-tenant-header) >"$WORK/out" 2>"$WORK/err" \
    && [ "$BROKEN_BEFORE" = "$(cksum "$BROKEN/.mefisto/harness.config.json")" ] \
    && ! jq -e '.schemaVersion == 1' "$WORK/out" >/dev/null 2>&1; then pass 'fallo de temporal no altera el destino ni emite exito'; else fail 'fallo de temporal altero el destino o emitio exito'; fi

FAKE_BIN="$WORK/fake-bin"; mkdir -p "$FAKE_BIN"
printf '%s\n' '#!/bin/sh' 'exit 73' > "$FAKE_BIN/mv"
chmod +x "$FAKE_BIN/mv"
MOVE_FAIL="$WORK/move-fail"; new_repo "$MOVE_FAIL"; copy_config canonical.json "$MOVE_FAIL/.mefisto/harness.config.json"
MOVE_BEFORE="$(cksum "$MOVE_FAIL/.mefisto/harness.config.json")"
if ! (cd "$MOVE_FAIL" && PATH="$FAKE_BIN:$PATH" bash "$SCRIPT" --strategy multi-tenant-header) >"$WORK/out" 2>"$WORK/err" \
    && [ "$MOVE_BEFORE" = "$(cksum "$MOVE_FAIL/.mefisto/harness.config.json")" ] \
    && [ -z "$(git -C "$MOVE_FAIL" status --porcelain --untracked-files=all -- .mefisto/pipeline)" ] \
    && ! jq -e '.schemaVersion == 1' "$WORK/out" >/dev/null 2>&1; then
    pass 'fallo de sustitucion conserva el destino y limpia su temporal'
else fail "fallo de sustitucion: $(<"$WORK/err")"; fi

BAD_VALUE="$WORK/bad-value"; new_repo "$BAD_VALUE"; copy_config canonical.json "$BAD_VALUE/.mefisto/harness.config.json"
jq '.tenancy.strategy = "desconocida"' "$BAD_VALUE/.mefisto/harness.config.json" > "$BAD_VALUE/config.tmp"
mv "$BAD_VALUE/config.tmp" "$BAD_VALUE/.mefisto/harness.config.json"
BAD_BEFORE="$(cksum "$BAD_VALUE/.mefisto/harness.config.json")"
if ! run_setter "$BAD_VALUE" "$SCRIPT" --strategy multi-tenant-header \
    && [ "$BAD_BEFORE" = "$(cksum "$BAD_VALUE/.mefisto/harness.config.json")" ]; then pass 'enum vigente invalido se rechaza'; else fail 'enum vigente invalido fue aceptado'; fi

if ! run_setter "$CANON" "$SCRIPT" --strategy otro \
    && ! jq -e '.schemaVersion == 1' "$WORK/out" >/dev/null 2>&1; then pass 'argumento fuera del enum se rechaza sin JSON de exito'; else fail 'argumento fuera del enum fue aceptado'; fi

PLUGIN="$WORK/plugin"; new_repo "$PLUGIN"; mkdir -p "$PLUGIN/.claude-plugin" "$PLUGIN/.mefisto"
copy_config canonical.json "$PLUGIN/.mefisto/harness.config.json"; printf '{}\n' > "$PLUGIN/.claude-plugin/plugin.json"
if ! run_setter "$PLUGIN" "$SCRIPT" --strategy multi-tenant-header \
    && grep -Fq 'solo aplica al consumidor' "$WORK/err"; then pass 'guard impide ejecutar sobre Mefisto'; else fail 'guard de consumidor no bloqueo'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
