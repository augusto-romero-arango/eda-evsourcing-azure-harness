#!/usr/bin/env bash
# Estructural: politica de cero warnings nuevos en tooling-pipeline.sh (#2409, MEF-ADR-0056).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIPE="$ROOT/scripts/tooling-pipeline.sh"
FAILS=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

S1=$(awk '/STAGE1_PROMPT="/,/run_agent "1"/' "$PIPE")
S2=$(awk '/STAGE2_PROMPT="/,/run_agent "2"/' "$PIPE")
grep -qF 'Commit base: ${SNAPSHOT_COMMIT}' <<<"$S1" && pass "STAGE1_PROMPT incluye el commit base" || fail "STAGE1_PROMPT sin commit base"
grep -qF 'warnings-diff.sh' <<<"$S1" && pass "STAGE1_PROMPT nombra warnings-diff.sh" || fail "STAGE1_PROMPT sin warnings-diff.sh"
grep -qF 'warnings-diff.sh' <<<"$S2" && pass "STAGE2_PROMPT nombra warnings-diff.sh" || fail "STAGE2_PROMPT sin warnings-diff.sh"

L_DEC=$(grep -n '^## Decisiones del pipeline' "$PIPE" | head -1 | cut -d: -f1)
L_REM=$(grep -n 'render_warning_remnants_section "\$WORKTREE_PATH"' "$PIPE" | head -1 | cut -d: -f1)
L_COM=$(awk -v d="${L_DEC:-0}" 'NR>d && /^## Commits/ {print NR; exit}' "$PIPE")
if [ -n "$L_DEC" ] && [ -n "$L_REM" ] && [ -n "$L_COM" ] && [ "$L_DEC" -lt "$L_REM" ] && [ "$L_REM" -lt "$L_COM" ]; then
    pass "el body del PR interpola los remanentes entre Decisiones y Commits"
else
    fail "orden incorrecto en el body del PR (dec=$L_DEC rem=$L_REM com=$L_COM)"
fi
[ "$FAILS" -eq 0 ] && echo "OK" || { echo "$FAILS fallo(s)"; exit 1; }
