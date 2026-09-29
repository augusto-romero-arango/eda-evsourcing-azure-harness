#!/usr/bin/env bash
# test-register-harness-secret.sh -- issue #1648. Corre en repos temporales.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$(cd "$SCRIPT_DIR/../.." && pwd)/scripts/register-harness-secret.sh"
USO="Uso: register-harness-secret.sh <nombre> <output|github-secret|composite> <referencia>"
FAIL=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

mkrepo() { local d="$TMP/$1"; mkdir -p "$d"; git -C "$d" init -q; echo "$d"; }

# (a)(b)(c)
R=$(mkrepo a); mkdir -p "$R/.mefisto"; echo '{"secrets":[]}' > "$R/.mefisto/harness.config.json"
C="$R/.mefisto/harness.config.json"
for t in output github-secret composite; do
    (cd "$R" && "$SUT" "s-$t" "$t" "ref-$t") >/dev/null 2>&1 \
      && [ "$(jq -r --arg n "s-$t" '.secrets[]|select(.name==$n)|.source.type' "$C")" = "$t" ] \
      && ok "(a) alta $t" || bad "(a) alta $t"
done
(cd "$R" && "$SUT" s-output output otra) >/dev/null 2>&1
[ "$(jq '[.secrets[]|select(.name=="s-output")]|length' "$C")" = 1 ] \
  && [ "$(jq -r '.secrets[]|select(.name=="s-output")|.source.value' "$C")" = otra ] \
  && [ "$(jq '.secrets|length' "$C")" = 3 ] && ok "(b) idempotente" || bad "(b) idempotente"
before=$(shasum "$C")
out=$(cd "$R" && "$SUT" x bogus ref 2>&1); rc=$?
[ $rc -ne 0 ] && [ "$out" = "$USO" ] && [ "$before" = "$(shasum "$C")" ] && ok "(c) tipo invalido" || bad "(c) tipo invalido"
out=$(cd "$R" && "$SUT" x output 2>&1); rc=$?
[ $rc -ne 0 ] && [ "$out" = "$USO" ] && ok "(c) aridad" || bad "(c) aridad"

# (d)
L=$(mkrepo d); mkdir -p "$L/.claude"; echo '{"secrets":[]}' > "$L/.claude/harness.config.json"
before=$(shasum "$L/.claude/harness.config.json")
(cd "$L" && "$SUT" s output r) >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$before" = "$(shasum "$L/.claude/harness.config.json")" ] && [ ! -e "$L/.mefisto/harness.config.json" ] \
  && ok "(d) legacy intacto" || bad "(d) legacy intacto"

# (e)
M=$(mkrepo e); mkdir -p "$M/.claude-plugin" "$M/.mefisto"; echo '{}' > "$M/.claude-plugin/plugin.json"
echo '{"secrets":[]}' > "$M/.mefisto/harness.config.json"
(cd "$M" && "$SUT" s output r) >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(jq '.secrets|length' "$M/.mefisto/harness.config.json")" = 0 ] && ok "(e) guard Mefisto" || bad "(e) guard Mefisto"

exit $FAIL
