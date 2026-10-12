#!/usr/bin/env bash
# test-detect-smoke-only.sh — Tests de detect_smoke_only() (scripts/_pipeline-common.sh),
# carril "solo smoke" de scripts/tdd-pipeline.sh (issue #2357, MEF-ADR-0013).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export HARNESS_NAMESPACE_PREFIX="Acme"
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/_pipeline-common.sh" 2>/dev/null || true

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

new_repo() {
    local d; d=$(mktemp -d)
    git -C "$d" init -q -b main
    git -C "$d" config user.email t@t; git -C "$d" config user.name t
    echo base > "$d/README.md"
    git -C "$d" add -A; git -C "$d" commit -qm base
    echo "$d"
}
mk() { mkdir -p "$(dirname "$1/$2")"; echo x > "$1/$2"; }
commit() { git -C "$1" add -A; git -C "$1" commit -qm c; }

expect() { # nombre esperado(0|1) repo snapshot [flag]
    local name="$1" want="$2" repo="$3" snap="$4" flag="${5:-}" rc=0
    detect_smoke_only "$repo" "$snap" $flag >/dev/null || rc=$?
    [ "$rc" -eq "$want" ] && ok "$name" || fail "$name (rc=$rc, esperado $want)"
}

S="tests/Acme.Dominio.SmokeTests/FooSmokeTests.cs"

r=$(new_repo); snap=$(git -C "$r" rev-parse HEAD)
mk "$r" "$S"; commit "$r"
expect "solo SmokeTests: si" 0 "$r" "$snap"

r=$(new_repo); snap=$(git -C "$r" rev-parse HEAD)
mk "$r" "$S"; mk "$r" docs/adr/mef-adr-0099-x.md; commit "$r"
expect "SmokeTests + docs/adr: si" 0 "$r" "$snap"

r=$(new_repo); snap=$(git -C "$r" rev-parse HEAD)
mk "$r" "$S"; mk "$r" src/Acme.Dominio/Foo.cs; commit "$r"
expect "SmokeTests + src/: no" 1 "$r" "$snap"
out=$(detect_smoke_only "$r" "$snap" || true)
echo "$out" | grep -q '^otro: src/Acme.Dominio/Foo.cs' && ok "lista el archivo que impide la deteccion" || fail "lista el archivo que impide la deteccion"

r=$(new_repo); snap=$(git -C "$r" rev-parse HEAD)
mk "$r" docs/adr/x.md; commit "$r"
expect "solo docs/: no" 1 "$r" "$snap"

r=$(new_repo); snap=$(git -C "$r" rev-parse HEAD)
mk "$r" "$S"; mk "$r" tests/Acme.Dominio.Tests/FooTests.cs; commit "$r"
expect "Tests unitarios + SmokeTests: no" 1 "$r" "$snap"

# Retomar: SNAPSHOT..HEAD con --committed ignora lo no commiteado
r=$(new_repo); snap=$(git -C "$r" rev-parse HEAD)
mk "$r" "$S"; commit "$r"
mk "$r" src/Acme.Dominio/Sucio.cs
expect "--committed ignora cambios sin commitear: si" 0 "$r" "$snap" --committed
expect "sin --committed ve archivos nuevos sin commitear: no" 1 "$r" "$snap"

# Sin commitear (stage 1 antes del auto-commit): smoke nuevo sin commit
r=$(new_repo); snap=$(git -C "$r" rev-parse HEAD)
mk "$r" "$S"; mk "$r" pipeline-state/x.md
expect "smoke sin commitear + pipeline-state: si" 0 "$r" "$snap"

echo "Resultado: $PASS ok, $FAIL fallos"
[ "$FAIL" -eq 0 ]
