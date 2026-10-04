#!/usr/bin/env bash
# Contrato de localizacion NuGet para los tres agentes de inspeccion (#1845).
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../.." && pwd -P)"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

check_agent() {
    local agent="$1" source="$REPO_ROOT/src/published/agents/$agent.md" file runtime
    for runtime in source claude opencode; do
        case "$runtime" in
            source) file="$source" ;;
            *) file="$WORK/release/dist/$runtime/agents/$agent.md" ;;
        esac
        if grep -Fq 'resolve-nuget-resources.sh' "$file" && grep -Fq ' --worktree-root "$WORKTREE_ROOT"' "$file" && \
            grep -Fq '.roots[].physicalRoot' "$file" && grep -Fq 'cmp -s "$SELECTED_ASSEMBLY" "${CANDIDATES[$index]}"' "$file" && \
           grep -Fq 'queda no verificada' "$file" && ! grep -Fq '.nuget/packages' "$file"; then
            pass "$agent ($runtime) usa el resolver, envelope y conflicto de duplicados"
        else
            fail "$agent ($runtime) conserva una localizacion fija o una salida incompleta"
        fi
    done
}

"$GENERATOR" --out "$WORK/release" >/dev/null
for agent in test-writer reviewer bug-investigator; do check_agent "$agent"; done

BUG="$REPO_ROOT/src/published/agents/bug-investigator.md"
if [ "$(grep -Fc 'resolve-nuget-resources.sh --worktree-root' "$BUG")" -ge 1 ] && \
   grep -Fq 'OLD_ASSEMBLY' "$BUG" && grep -Fq 'NEW_ASSEMBLY' "$BUG" && \
   grep -Fq 'Una version vieja y una nueva pueden vivir en roots distintas' "$BUG"; then
    pass 'bug-investigator conserva selecciones separadas para versiones vieja y nueva'
else
    fail 'bug-investigator no separa las versiones'
fi

# Fixture acotado: roots con espacios, assets antes que CLI y versiones en roots distintas.
mkdir -p "$WORK/assets root/pkg/1.0/lib/net10.0" "$WORK/cli root/pkg/1.0/lib/net10.0" "$WORK/cli root/pkg/2.0/lib/net10.0"
printf vieja > "$WORK/assets root/pkg/1.0/lib/net10.0/Assembly.Real.dll"
printf nueva > "$WORK/cli root/pkg/2.0/lib/net10.0/Assembly.Real.dll"
roots=("$WORK/assets root" "$WORK/cli root")
select_assembly() {
    local version="$1" candidate root
    CANDIDATES=()
    for root in "${roots[@]}"; do
        candidate="$root/pkg/$version/lib/net10.0/Assembly.Real.dll"
        [ -f "$candidate" ] && CANDIDATES+=("$candidate")
    done
    [ "${#CANDIDATES[@]}" -gt 0 ] || return 1
    SELECTED_ASSEMBLY="${CANDIDATES[0]}"
}
select_assembly 1.0 && old="$SELECTED_ASSEMBLY"; select_assembly 2.0 && new="$SELECTED_ASSEMBLY"
if [ "$old" = "$WORK/assets root/pkg/1.0/lib/net10.0/Assembly.Real.dll" ] && [ "$new" = "$WORK/cli root/pkg/2.0/lib/net10.0/Assembly.Real.dll" ]; then
    pass 'fixture selecciona casing, version y root efectiva distintos sin ejecutar ilspycmd'
else
    fail 'fixture no conserva roots/versiones separadas'
fi

cp "$old" "$WORK/cli root/pkg/1.0/lib/net10.0/Assembly.Real.dll"
select_assembly 1.0
if [ "${#CANDIDATES[@]}" -eq 2 ] && cmp -s "${CANDIDATES[0]}" "${CANDIDATES[1]}"; then
    pass 'duplicados identicos conservan el primer candidato en orden determinista'
else
    fail 'duplicados identicos no se comparan como exige el contrato'
fi
printf distinto > "$WORK/cli root/pkg/1.0/lib/net10.0/Assembly.Real.dll"
if ! cmp -s "${CANDIDATES[0]}" "${CANDIDATES[1]}"; then
    pass 'duplicados distintos quedan visibles como conflicto sin ejecutar ilspycmd'
else
    fail 'duplicados distintos no se distinguen'
fi

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
