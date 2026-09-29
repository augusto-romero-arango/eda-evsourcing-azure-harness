#!/usr/bin/env bash
# Contrato del comando scaffold neutral y sus proyecciones publicadas.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/commands/scaffold.md"
CLAUDE="$REPO_ROOT/dist/claude/commands/scaffold.md"
OPENCODE="$REPO_ROOT/dist/opencode/commands/mefisto:scaffold.md"
MIRROR="$REPO_ROOT/commands/scaffold.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[fuente] contrato neutral'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "command" and .id == "scaffold" and .profile == "fast" and .arguments == "<issue> [dominio] | <dominio>" and (keys | sort) == ["arguments", "description", "id", "kind", "profile"]' >/dev/null; then pass 'metadata sin agent ni capabilities'; else fail 'metadata neutral invalida'; fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
contains "$body" '{{mefisto:run tmux-pipeline.sh --scaffold <issue> --domain <dominio-kebab-confirmado>}}' 'despacho con issue'
contains "$body" '{{mefisto:run tmux-pipeline.sh --scaffold --domain <dominio-kebab-confirmado>}}' 'despacho sin issue'
contains "$body" 'namespacePrefix' 'RootNamespace desde namespacePrefix'
contains "$body" '{{mefisto:config-path}}' 'lee la config via directiva'
contains "$body" '{{mefisto:state-path logs}}' 'remite al log via directiva'
absent "$body" '/work-status' 'no remite a work-status'
absent "$body" 'work-status' 'no menciona work-status'
contains "$body" 'esta cerrado (`CLOSED`), informa y detente' 'rechaza issue inexistente o cerrado'
contains "$body" 'Dominio: nombre-kebab' 'extrae Dominio del body'
absent "$body" 'grep -ioP' 'sin grep -P en la extraccion'
contains "$body" 'No se pudo determinar el nombre del dominio' 'mensaje sin dominio'
contains "$body" 'Normalizar a kebab-case' 'normalizacion kebab/Pascal'
contains "$body" 'Si ya existe, informa y detente' 'aborta si el dominio existe'
contains "$body" '¿Continuar? (s/n)' 'confirmacion explicita'
contains "$body" 'Si dice no, detente' 'se detiene sin confirmacion'
contains "$body" 'MEF-ADR-0020' 'resumen refleja MEF-ADR-0020'
contains "$body" 'HERDR_ENV=1' 'distingue herdr'
contains "$body" 'tmux -CC attach -t scaffold-<dominio>' 'attach tmux fuera de herdr'
contains "$body" 'No esperes a que termine' 'regla: no esperar'
contains "$body" 'No crees el dominio tu mismo' 'regla: no crear el dominio'
contains "$body" 'Nunca crees un dominio sin confirmacion explicita' 'regla: confirmacion obligatoria'
contains "$body" 'Si tmux no esta instalado' 'deteccion de tmux ausente'
for forbidden in 'Claude' 'OpenCode' '.claude/' '.opencode/' 'cache' 'model:' 'tools:' 'allowed-tools:' 'permission:' '.plugin-root' 'CLAUDE_' 'plugins/cache'; do absent "$body" "$forbidden" "fuente no publica token prohibido: $forbidden"; done
guard_line="$(grep -nF '{{mefisto:assert-consumer-repo}}' "$SOURCE" | cut -d: -f1)"
operation_line="$(awk '/gh issue view|jq -r/ { print NR; exit }' "$SOURCE")"
[ -n "$guard_line" ] && [ -n "$operation_line" ] && [ "$guard_line" -lt "$operation_line" ] && pass 'guard precede cualquier operacion' || fail 'guard no precede las operaciones'
confirm_line="$(grep -nF '¿Continuar? (s/n)' "$SOURCE" | head -1 | cut -d: -f1)"
launch_line="$(grep -nF '{{mefisto:run tmux-pipeline.sh' "$SOURCE" | head -1 | cut -d: -f1)"
[ -n "$confirm_line" ] && [ -n "$launch_line" ] && [ "$confirm_line" -lt "$launch_line" ] && pass 'confirmacion precede al lanzamiento' || fail 'confirmacion no precede al lanzamiento'

echo '[salidas] adaptadores y mirror'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
claude_body="$(< "$CLAUDE")"
opencode_body="$(< "$OPENCODE")"
for form in '--scaffold <issue> --domain' '--scaffold --domain'; do
    contains "$claude_body" "\"\${MEFISTO_PACKAGE_ROOT}/scripts/tmux-pipeline.sh\" $form" "Claude invoca tmux-pipeline.sh $form"
    contains "$opencode_body" "\"\${MEFISTO_PACKAGE_ROOT}/scripts/tmux-pipeline.sh\" $form" "OpenCode invoca tmux-pipeline.sh $form"
done
for out in "$claude_body" "$opencode_body"; do
    absent "$out" 'plugins/cache' 'salida sin plugins/cache'
    absent "$out" 'grep -ioP' 'salida sin grep -ioP'
done
absent "$opencode_body" '.plugin-root' 'salida OpenCode sin .plugin-root'
absent "$(printf '%s\n' "$claude_body" | grep -F 'scripts/tmux-pipeline.sh" --scaffold')" '.plugin-root' 'invocacion Claude sin .plugin-root'
contains "$claude_body" 'model: "haiku"' 'Claude materializa el perfil fast'
absent "$opencode_body" 'model:' 'OpenCode no emite model'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror Claude coincide byte a byte'; else fail 'mirror Claude diverge'; fi
contains "$(< "$MIRROR")" '<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/scaffold.md. No editar a mano. -->' 'mirror conserva marcador generado'

echo '[assets] scaffold-pipeline.sh empaquetado'
for runtime in claude opencode; do
    dest="$REPO_ROOT/dist/$runtime/scripts/scaffold-pipeline.sh"
    if [ -x "$dest" ]; then pass "scaffold-pipeline.sh ejecutable en dist/$runtime"; else fail "falta o no es ejecutable dist/$runtime/scripts/scaffold-pipeline.sh"; fi
    if cmp -s "$REPO_ROOT/scripts/scaffold-pipeline.sh" "$dest"; then pass "dist/$runtime/scripts/scaffold-pipeline.sh identico a la fuente"; else fail "dist/$runtime/scripts/scaffold-pipeline.sh diverge"; fi
    if jq -e '.assets[] | select(.destination == "scripts/scaffold-pipeline.sh")' "$REPO_ROOT/dist/$runtime/.mefisto-generated-assets.json" >/dev/null 2>&1; then pass "inventario de dist/$runtime lista scaffold-pipeline.sh"; else fail "inventario de dist/$runtime no lista scaffold-pipeline.sh"; fi
done
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
