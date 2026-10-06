#!/usr/bin/env bash
# Contrato publicado de plantillas shell por comando de entrada (#1944): el
# adaptador lo genera desde la matriz neutral (shellExtra + {{mefisto:run}}).
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/../../../.." && pwd -P)"
ADAPTER="$ROOT/src/published/scripts/adapters/adapter-opencode.sh"
LIBDIR="$ROOT/src/published/scripts/adapters/lib"
MATRIX="$ROOT/src/published/contract/command-entry.json"
PERMS="$ROOT/src/published/contract/opencode-permissions.json"
CORPUS="$HERE/fixtures/bash-candidates/opencode-1.18.29.json"
PACKAGED="$ROOT/dist/opencode/src/published/contract/command-shell-templates.json"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }

printf '%s\n' '[generacion]'
GEN="$(bash "$ADAPTER" render-asset command-shell-templates "$MATRIX")" || GEN=''
[ -n "$GEN" ] && pass 'el adaptador genera el contrato' || { fail 'el adaptador no genera el contrato'; exit 1; }
jq -e --slurpfile m "$MATRIX" '.schemaVersion == 1 and ((.commands | keys) == ($m[0].commands | map(.id) | sort)) and (.commands | length) == 28 and all(.commands[]; type == "array")' <<< "$GEN" >/dev/null && pass 'schemaVersion 1 y las 28 filas' || fail 'forma del contrato'
jq -e 'all(.commands[]; . == (unique | sort))' <<< "$GEN" >/dev/null && pass 'patrones ordenados y sin duplicados' || fail 'patrones no deterministas'
[ "$GEN" = "$(bash "$ADAPTER" render-asset command-shell-templates "$MATRIX")" ] && pass 'salida determinista' || fail 'salida no determinista'
[ -f "$PACKAGED" ] && [ "$(jq -cS . "$PACKAGED")" = "$(jq -cS . <<< "$GEN")" ] && pass 'el contrato empaquetado coincide con el generado' || fail 'contrato empaquetado ausente o divergente'
jq -e 'all(.commands | to_entries[]; (.key as $id | .value | map(select(startswith("MEFISTO_RUNTIME=opencode \"${MEFISTO_PACKAGE_ROOT}/scripts/"))) | all(test("\"\\*$"))))' <<< "$GEN" >/dev/null && pass 'cada mefisto:run produce el prefijo canonico exacto' || fail 'prefijo canonico'
for id in batch-stop draft runtimes; do
  jq -e --arg id "$id" '.commands[$id] | length > 0' <<< "$GEN" >/dev/null && pass "$id declara plantillas" || fail "$id sin plantillas"
done
jq -e '.commands["batch-stop"] | index("pgrep -f*") != null and index("touch*") != null' <<< "$GEN" >/dev/null && pass 'batch-stop declara su bash crudo via shellExtra' || fail 'batch-stop shellExtra'

printf '%s\n' '[patrones estrechos]'
jq -e '[.commands[][]] | all(. != "*" and . != "* *")' <<< "$GEN" >/dev/null && pass 'ningun patron es *' || fail 'hay un patron comodin total'
jq -e --slurpfile p "$PERMS" '($p[0].capability_map.shell.rules | map(.pattern | select(startswith("MEFISTO_RUNTIME=opencode ") | not))) as $global | [.commands[][]] | all(. as $x | ($global | index($x)) == null)' <<< "$GEN" >/dev/null && pass 'ningun patron copia las reglas genericas de la politica bash global' || fail 'patron copiado de capability_map'
jq -e '[.commands[][] | select(test("/scripts/\\*"))] | length == 0' <<< "$GEN" >/dev/null && pass 'sin glob generico sobre scripts/' || fail 'glob generico sobre scripts'

printf '%s\n' '[cobertura]'
extract() { # <doc> -> un candidato por linea ejecutable (raiz del comando)
  awk '
    /^```(bash|sh|shell)/ { b=1; next }
    /^```/ { b=0; next }
    !b { next }
    {
      line=$0; sub(/^[ \t]+/, "", line)
      if (heredoc != "") { if (line == heredoc) heredoc=""; next }
      cont=prevcont; prevcont=(line ~ /\\$/)
      if (match(line, /<<-?[\047"]?[A-Za-z_]+[\047"]?/)) {
        tag=substr(line, RSTART, RLENGTH); gsub(/<<-?|[\047"]/, "", tag); heredoc=tag
      }
      if (cont) next
      if (line == "" || line ~ /^#/ || line ~ /^[)}|]/ || line ~ /^;;/ || line ~ /^[^ ]*\)/) next
      if (index(line, "{{mefisto:run") > 0) next
      for (i = 0; i < 6; i++) {
        if (sub(/^(if|elif|while|!) +/, "", line)) continue
        if (sub(/^\(cd [^&]*&& */, "", line)) continue
        if (match(line, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
          line=substr(line, RLENGTH + 1)
          if (sub(/^\$\( */, "", line)) continue
          line=""; break
        }
        break
      }
      split(line, w, /[ \t;]/)
      if (line == "" || w[1] ~ /^(for|do|done|then|else|fi|case|esac|in|return|exit|break|sleep|echo|printf|test|true|false|\[|\[\[|:|\{|\()$/) next
      print line
    }' "$1"
}
evaluate() { # <patrones-json> <candidato>
  jq -L "$LIBDIR" -cnr --argjson pats "$1" --arg candidate "$2" \
    'include "opencode-entry-permissions"; {action:"evaluate",policy:{rules:($pats | map({permission:"bash",pattern:.,value:"allow"}))},candidates:[{permission:"bash",candidate:$candidate}]} | entry_permissions | .decisions[0].decision'
}
human="$(jq -r '.inventory.humanInstruction[] | .artifact + "\t" + .snippet' "$CORPUS")"
gate_fail=0; checked=0
for doc in "$ROOT"/src/published/commands/*.md; do
  id="$(basename "$doc" .md)"
  pats="$(jq -c --arg id "$id" '.commands[$id]' <<< "$GEN")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if grep -Fxq "commands/$id.md	$line" <<< "$human"; then continue; fi
    checked=$((checked+1))
    [ "$(evaluate "$pats" "$line")" = allow ] || { gate_fail=1; fail "$id: comando raiz no declarado: $line"; }
  done < <(extract "$doc")
done
[ "$gate_fail" -eq 0 ] && [ "$checked" -gt 20 ] && pass "gate de cobertura: $checked lineas ejecutables cubiertas" || fail 'gate de cobertura'
probe="$(mktemp)"; printf '```bash\nrsync -a x y\n```\n' > "$probe"
[ "$(extract "$probe")" = 'rsync -a x y' ] && [ "$(evaluate '["git status*"]' 'rsync -a x y')" != allow ] && pass 'un comando raiz no declarado falla el gate' || fail 'el gate no detecta comandos no declarados'
rm -f "$probe"

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
