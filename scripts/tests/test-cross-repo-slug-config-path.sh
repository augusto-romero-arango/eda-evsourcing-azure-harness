#!/usr/bin/env bash
# test-cross-repo-slug-config-path.sh -- Contrato de ruta efectiva para leer
# `repoSlug` en los tres caminos de draft cross-repo hacia Mefisto (#1534,
# MEF-ADR-0053 decision 4).
#
# Cubre agents/tooling-investigator.md y commands/fix-review.md (ambos con el
# anclaje "Lee el slug del repo de Mefisto (configurable para forks):"):
# canonico, ambos divergentes (prevalece canonico), solo legacy, ausencia de
# ambos y canonico sin el campo opcional `repoSlug`. Para estos dos (todavia
# hand-escritos, no migrados a la fuente neutral), el campo nunca aborta:
# siempre cae al default aunque no exista ningun config.
#
# agents/planner.md migro a la fuente neutral publicada (issue #1640): lee
# `repoSlug` via `{{mefisto:config-path}}`, asi que ahora comparte el mismo
# preambulo de resolucion efectiva que el resto de agentes publicados
# (canonico primero, fallback legacy con AVISO, ABORTA si no existe ninguno
# de los dos -- MEF-ADR-0053 seccion 4). El campo en si sigue siendo opcional
# (config presente sin `repoSlug` cae al default), pero la ausencia total del
# archivo de config ya no es tolerada solo para este agente: es una
# consecuencia deliberada de adoptar el contrato neutral compartido, no una
# regresion. La matriz de planner combina ese preambulo compartido con su
# propio bloque de resolucion del slug.
#
# Tambien evita que una lectura directa del config legacy reaparezca fuera
# del fallback sancionado en los cuatro artefactos que mencionan
# `repoSlug`/`domainLabels` (planner, investigator, fix-review, commands/draft.md).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLANNER="$REPO_ROOT/agents/planner.md"
INVESTIGATOR="$REPO_ROOT/agents/tooling-investigator.md"
FIX_REVIEW="$REPO_ROOT/commands/fix-review.md"
DRAFT="$REPO_ROOT/commands/draft.md"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

DEFAULT_SLUG="augusto-romero-arango/eda-evsourcing-azure-harness"

extract_after_anchor() {
    # $1: archivo, $2: substring literal del anclaje que precede el primer ```bash
    local file="$1" anchor="$2"
    awk -v anchor="$anchor" '
        index($0, anchor) { found=1 }
        found && /^```bash$/ { inside=1; next }
        found && inside && /^```$/ { exit }
        found && inside { print }
    ' "$file"
}

# extract_config_preamble <archivo>
#
# El preambulo compartido de resolucion efectiva (canonico/legacy/abort) que
# el adaptador antepone una sola vez cuando el body usa {{mefisto:config-path}}
# -- identico en todo artefacto migrado a la fuente neutral. Se identifica por
# contenido (la linea que exporta MEFISTO_CONFIG_PATH), no por posicion.
extract_config_preamble() {
    local file="$1"
    awk '
        /^```bash$/ { buf=""; inside=1; next }
        inside && /^```$/ { inside=0; if (buf ~ /export MEFISTO_CONFIG_PATH/) { printf "%s", buf; exit } next }
        inside { buf = buf $0 "\n" }
    ' "$file"
}

BLOCK_PLANNER_OWN="$(extract_after_anchor "$PLANNER" '### Slug del repo de Mefisto')"
CONFIG_PREAMBLE="$(extract_config_preamble "$PLANNER")"
BLOCK_PLANNER="$CONFIG_PREAMBLE"$'\n'"$BLOCK_PLANNER_OWN"
BLOCK_INVESTIGATOR="$(extract_after_anchor "$INVESTIGATOR" 'Lee el slug del repo de Mefisto (configurable para forks):')"
BLOCK_FIX_REVIEW="$(extract_after_anchor "$FIX_REVIEW" 'Lee el slug del repo de Mefisto (configurable para forks):')"

echo "[1] Extraccion de los tres bloques"
if [ -n "$BLOCK_PLANNER_OWN" ] && [ -n "$CONFIG_PREAMBLE" ] && [ -n "$BLOCK_INVESTIGATOR" ] && [ -n "$BLOCK_FIX_REVIEW" ]; then
    pass "los tres bloques (y el preambulo compartido de planner) se extrajeron desde sus anclajes"
else
    fail "no se pudo extraer alguno de los bloques esperados"
fi
if [ "$BLOCK_INVESTIGATOR" = "$BLOCK_FIX_REVIEW" ]; then
    pass "investigator y fix-review (sin migrar) siguen siendo literalmente identicos entre si"
else
    fail "investigator y fix-review divergen entre si"
fi
# planner ya NO comparte el bloque literal con los otros dos: migro a la
# fuente neutral (issue #1640) y ahora resuelve MEFISTO_CONFIG_PATH via el
# preambulo compartido en vez de reimplementar CONFIG="$REPO_ROOT/..." a mano.
contains "$BLOCK_PLANNER_OWN" 'MEFISTO_CONFIG_PATH' 'planner resuelve el slug via MEFISTO_CONFIG_PATH (preambulo compartido), no via CONFIG propio'
absent "$BLOCK_PLANNER_OWN" 'CONFIG="$REPO_ROOT' 'planner ya no reconstruye CONFIG=$REPO_ROOT/... a mano'

write_json() {
    local path="$1" slug="$2"
    mkdir -p "$(dirname "$path")"
    printf '{"repoSlug":"%s"}\n' "$slug" > "$path"
}

run_block() {
    # $1: bloque bash, $2: directorio raiz del repo temporal, $3: subdirectorio de trabajo relativo
    local block="$1" root="$2" subdir="$3"
    mkdir -p "$root/$subdir"
    (cd "$root/$subdir" && bash -c "$block")
}

run_matrix() {
    # $1: etiqueta, $2: bloque bash a ejecutar, $3: comportamiento esperado
    # sin ningun config -- "default" (cae al default, comportamiento legacy
    # de investigator/fix-review) o "abort" (preambulo compartido de
    # config-path aborta, comportamiento nuevo de planner migrado).
    # $4: modo de cwd -- "nested" (subdirectorio profundo; comportamiento
    # legacy, cwd-independiente porque el bloque hace su propio
    # 'git rev-parse --show-toplevel') o "root" (siempre desde la raiz del
    # repo temporal; el preambulo compartido de {{mefisto:config-path}}
    # resuelve relativo al cwd, MEF-ADR-0053 seccion 4 -- no reimplementa el
    # lookup de la raiz Git, asi que planner migrado ya NO ofrece la garantia
    # de independencia de cwd que su bloque hand-escrito si ofrecia).
    local label="$1" block="$2" no_config_mode="${3:-default}" cwd_mode="${4:-nested}"
    local subdir="nested/sub"
    [ "$cwd_mode" = "root" ] && subdir="."

    local s1="$TMP_DIR/$label-canonico"
    mkdir -p "$s1" && (cd "$s1" && git init -q)
    write_json "$s1/.mefisto/harness.config.json" "org/fork"
    local out
    out=$(run_block "$block" "$s1" "$subdir")
    if [ "$out" = "org/fork" ]; then
        pass "$label: solo canonico resuelve org/fork"
    else
        fail "$label: solo canonico esperaba org/fork y obtuvo '$out'"
    fi

    local s2="$TMP_DIR/$label-ambos"
    mkdir -p "$s2" && (cd "$s2" && git init -q)
    write_json "$s2/.mefisto/harness.config.json" "org/canonico"
    write_json "$s2/.claude/harness.config.json" "org/legacy"
    out=$(run_block "$block" "$s2" "$subdir")
    if [ "$out" = "org/canonico" ]; then
        pass "$label: coexistencia prevalece el canonico"
    else
        fail "$label: coexistencia esperaba org/canonico y obtuvo '$out'"
    fi

    local s3="$TMP_DIR/$label-legacy"
    mkdir -p "$s3" && (cd "$s3" && git init -q)
    write_json "$s3/.claude/harness.config.json" "org/legacy"
    out=$(run_block "$block" "$s3" "$subdir")
    if [ "$out" = "org/legacy" ]; then
        pass "$label: solo legacy resuelve org/legacy"
    else
        fail "$label: solo legacy esperaba org/legacy y obtuvo '$out'"
    fi

    local s4="$TMP_DIR/$label-sin-config"
    mkdir -p "$s4" && (cd "$s4" && git init -q)
    if [ "$no_config_mode" = "abort" ]; then
        out=$(run_block "$block" "$s4" "$subdir" 2>/dev/null); rc=$?
        if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
            pass "$label: sin ningun config aborta (preambulo compartido de config-path, MEF-ADR-0053)"
        else
            fail "$label: sin config esperaba abortar sin stdout y obtuvo rc=$rc out='$out'"
        fi
    else
        out=$(run_block "$block" "$s4" "$subdir")
        if [ "$out" = "$DEFAULT_SLUG" ]; then
            pass "$label: sin ningun config aplica el default"
        else
            fail "$label: sin config esperaba el default y obtuvo '$out'"
        fi
    fi

    local s5="$TMP_DIR/$label-canonico-sin-campo"
    mkdir -p "$s5/.mefisto" && (cd "$s5" && git init -q)
    printf '{"projectName":"demo"}\n' > "$s5/.mefisto/harness.config.json"
    out=$(run_block "$block" "$s5" "$subdir")
    if [ "$out" = "$DEFAULT_SLUG" ]; then
        pass "$label: canonico sin repoSlug aplica el default"
    else
        fail "$label: canonico sin repoSlug esperaba el default y obtuvo '$out'"
    fi

    if [ "$cwd_mode" = "root" ]; then
        pass "$label: se prueba siempre desde la raiz del repo (el preambulo compartido de config-path no es cwd-independiente, MEF-ADR-0053 seccion 4)"
        return
    fi

    local out_root out_nested
    out_root=$(cd "$s1" && bash -c "$block")
    out_nested=$(run_block "$block" "$s1" "otro/nivel/distinto")
    if [ "$out_root" = "org/fork" ] && [ "$out_nested" = "org/fork" ]; then
        pass "$label: el resultado es independiente del cwd dentro del repo"
    else
        fail "$label: el resultado cambio segun el cwd (root='$out_root', nested='$out_nested')"
    fi
}

echo "[2] Matriz de resolucion (CA-3) para planner.md (preambulo compartido + bloque propio)"
run_matrix "planner" "$BLOCK_PLANNER" "abort" "root"

echo "[3] Matriz de resolucion (CA-3) para tooling-investigator.md"
run_matrix "investigator" "$BLOCK_INVESTIGATOR" "default" "nested"

echo "[4] Matriz de resolucion (CA-3) para fix-review.md"
run_matrix "fix-review" "$BLOCK_FIX_REVIEW" "default" "nested"

echo "[5] Anti-regresion: no hay lecturas directas del legacy fuera del fallback sancionado"
SANCTIONED_LINE='cat .mefisto/harness.config.json 2>/dev/null || cat .claude/harness.config.json 2>/dev/null || echo "No existe"'
ANY_LEAK=0
for f in "$PLANNER" "$INVESTIGATOR" "$FIX_REVIEW" "$DRAFT"; do
    FILTERED=$(grep -vF "$SANCTIONED_LINE" "$f")
    if grep -Eq '(^|[;&|(`$[:space:]])jq[[:space:]].*\.claude/harness\.config\.json' <<< "$FILTERED"; then
        fail "$(basename "$f") tiene una lectura jq directa del config legacy"
        ANY_LEAK=1
    fi
    if grep -Eq '(^|[;&|(`$[:space:]])(cat|sed|awk|grep|python|python3)[[:space:]].*\.claude/harness\.config\.json|<[[:space:]]*[^[:space:]]*\.claude/harness\.config\.json' <<< "$FILTERED"; then
        fail "$(basename "$f") tiene una lectura directa (cat/sed/awk/grep/python/<) del config legacy fuera del fallback sancionado"
        ANY_LEAK=1
    fi
done
if [ "$ANY_LEAK" -eq 0 ]; then
    pass "ningun artefacto reintroduce una lectura directa del config legacy fuera del fallback sancionado"
fi

echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
