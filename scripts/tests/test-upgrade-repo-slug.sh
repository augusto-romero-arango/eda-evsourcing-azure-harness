#!/usr/bin/env bash
# Test de _repo_slug en scripts/upgrade.sh (issue #2352, MEF-ADR-0053 decision 4).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

command -v jq >/dev/null 2>&1 || { echo "jq requerido"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SCRIPTS="$TMP/scripts"; mkdir -p "$SCRIPTS"
cp "$REPO_ROOT/scripts/upgrade.sh" "$REPO_ROOT/scripts/_plugin-scopes.sh" "$REPO_ROOT/scripts/_pipeline-common.sh" "$SCRIPTS/"

# Carga solo la funcion _repo_slug, ejecutada desde el directorio $1.
slug_en() {
    local dir="$1"
    (
        cd "$dir" || exit 1
        SCRIPT_DIR="$SCRIPTS"
        source "$SCRIPTS/_plugin-scopes.sh"
        DEFAULT_REPO_SLUG="$MEFISTO_SLUG_PUBLICADO"
        eval "$(sed -n '/^_repo_slug() {/,/^}/p' "$SCRIPTS/upgrade.sh")"
        _repo_slug 2>"$TMP/stderr"
    )
}

mkrepo() { local d="$TMP/$1"; mkdir -p "$d"; git -C "$d" init -q; printf '%s\n' "$d"; }
cfg() { mkdir -p "$(dirname "$2")"; printf '{"repoSlug":"%s"}\n' "$1" > "$2"; }

DEFAULT=$(. "$SCRIPTS/_plugin-scopes.sh"; printf '%s' "$MEFISTO_SLUG_PUBLICADO")

echo "== canonico con repoSlug =="
R=$(mkrepo canon); cfg owner/fork "$R/.mefisto/harness.config.json"
[ "$(slug_en "$R")" = owner/fork ] && ok "canonico -> owner/fork" || ko "canonico"

echo "== solo legacy =="
R=$(mkrepo legacy); cfg legacy/fork "$R/.claude/harness.config.json"
[ "$(slug_en "$R")" = legacy/fork ] && ok "legacy -> legacy/fork" || ko "legacy"

echo "== ambos: gana canonico, stdout limpio =="
R=$(mkrepo ambos); cfg owner/fork "$R/.mefisto/harness.config.json"; cfg legacy/fork "$R/.claude/harness.config.json"
out=$(slug_en "$R")
[ "$out" = owner/fork ] && ok "gana canonico" || ko "canonico vs legacy: '$out'"
[ ! -s "$TMP/stderr" ] && ok "el AVISO del resolver no se filtra" || ko "salida del resolver: $(cat "$TMP/stderr")"

echo "== sin config / fuera de repo / sin repoSlug =="
R=$(mkrepo vacio)
[ "$(slug_en "$R")" = "$DEFAULT" ] && ok "sin config -> default" || ko "sin config"
N="$TMP/sinrepo"; mkdir -p "$N"
[ "$(GIT_CEILING_DIRECTORIES="$TMP" slug_en "$N")" = "$DEFAULT" ] && ok "fuera de repo -> default" || ko "fuera de repo"
R=$(mkrepo sinslug); mkdir -p "$R/.mefisto"; echo '{}' > "$R/.mefisto/harness.config.json"
[ "$(slug_en "$R")" = "$DEFAULT" ] && ok "config sin repoSlug -> default" || ko "sin repoSlug"

echo "== HARNESS_CONFIG_PATH explicito =="
R=$(mkrepo explicito); cfg owner/fork "$R/.mefisto/harness.config.json"; cfg env/fork "$TMP/env.json"
[ "$(HARNESS_CONFIG_PATH="$TMP/env.json" slug_en "$R")" = env/fork ] && ok "env tiene prioridad" || ko "env"

echo "== sin _pipeline-common.sh: comportamiento previo =="
SIN="$TMP/scripts-sin-common"; mkdir -p "$SIN"; cp "$SCRIPTS/upgrade.sh" "$SCRIPTS/_plugin-scopes.sh" "$SIN/"
R=$(mkrepo sincommon); cfg owner/fork "$R/.mefisto/harness.config.json"; cfg legacy/fork "$R/.claude/harness.config.json"
[ "$(SCRIPTS="$SIN" slug_en "$R")" = legacy/fork ] && ok "sin helper -> legacy relativo" || ko "sin helper"

echo "Resultado: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
