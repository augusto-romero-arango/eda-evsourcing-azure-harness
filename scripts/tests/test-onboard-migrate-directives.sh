#!/usr/bin/env bash
# test-onboard-migrate-directives.sh -- Casos conservadores de la migración #1080.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/onboard-migrate-directives.sh"
COMMAND="$REPO_ROOT/commands/onboard.md"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq no instalado"; exit 0; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
make_repo() {
    local repo="$1"; mkdir -p "$repo/.mefisto"; (cd "$repo" && git init -q)
    cat > "$repo/.mefisto/harness.config.json" <<'JSON'
{"projectName":"Proyecto","namespacePrefix":"Empresa.Proyecto","solutionFile":"Proyecto.slnx","domainLabels":["ventas","cobros"],"boundedContext":{"name":"Principal","domains":["ventas","cobros"]}}
JSON
}
run() { (cd "$1" && bash "$SCRIPT" "$2") 2>&1; }

echo "[M-1] preview y aplicación explícita"
R="$TMP/greenfield"; make_repo "$R"; OUT=$(run "$R" --preview); RC=$?
if [ "$RC" -eq 0 ] && [ ! -e "$R/AGENTS.md" ] && [ ! -e "$R/CLAUDE.md" ] && printf '%s' "$OUT" | grep -Fq 'no se escribió'; then pass "preview no escribe"; else fail "preview escribió o falló: $OUT"; fi
OUT=$(run "$R" --apply); RC=$?
if [ "$RC" -eq 0 ] && grep -Fq '**RootNamespace**: Empresa.Proyecto' "$R/AGENTS.md" && grep -Fq '**BoundedContextDomains**: ventas, cobros' "$R/AGENTS.md" && grep -Fq 'Verificación de fuentes' "$R/AGENTS.md" && grep -Fxq '@AGENTS.md' "$R/CLAUDE.md"; then pass "apply greenfield crea contrato y puente"; else fail "apply greenfield falló: $OUT; AGENTS=$(cat "$R/AGENTS.md" 2>/dev/null); CLAUDE=$(cat "$R/CLAUDE.md" 2>/dev/null)"; fi
if grep -Fq 'Ofrece este paso **solo** cuando el diagnóstico reportó que falta `AGENTS.md` o el puente exacto' "$COMMAND" && grep -Fq 'Sin un `si` explícito, no ejecutes ninguna escritura' "$COMMAND"; then pass "el comando condiciona la aplicación a diagnóstico y confirmación explícita"; else fail "el comando no conserva el gate humano requerido"; fi
if grep -Fq 'decláralo como *no verificado* en' "$R/AGENTS.md" && grep -Fxq 'tu propuesta en vez de darlo por cierto.' "$R/AGENTS.md"; then pass "la sección de fuentes coincide con la plantilla canónica"; else fail "la plantilla de fuentes divergió del contrato"; fi

echo "[M-2] idempotencia y preservación"
BEFORE=$(cksum "$R/AGENTS.md" "$R/CLAUDE.md"); run "$R" --apply >/dev/null; AFTER=$(cksum "$R/AGENTS.md" "$R/CLAUDE.md")
if [ "$BEFORE" = "$AFTER" ]; then pass "contrato completo es idempotente"; else fail "contrato completo cambió"; fi
R="$TMP/claude-propio"; make_repo "$R"; cat > "$R/AGENTS.md" <<'EOF'
## Tokens del harness
**RootNamespace**: A
**SolutionFile**: A
**ProjectDisplayName**: A
**BoundedContext**: A
**BoundedContextDomains**: A
## Verificación de fuentes
EOF
printf '# Directiva propia\nNo perder.\n' > "$R/CLAUDE.md"; run "$R" --apply >/dev/null
if grep -Fq 'No perder.' "$R/CLAUDE.md" && grep -Fxq '@AGENTS.md' "$R/CLAUDE.md"; then pass "CLAUDE.md propio se preserva y recibe import"; else fail "contenido propio no preservado"; fi

echo "[M-3] rechazos sin escrituras parciales"
R="$TMP/incompleto"; make_repo "$R"; printf '## Tokens del harness\n' > "$R/AGENTS.md"; BEFORE=$(cksum "$R/AGENTS.md"); OUT=$(run "$R" --apply); RC=$?
if [ "$RC" -ne 0 ] && [ "$BEFORE" = "$(cksum "$R/AGENTS.md")" ] && [ ! -e "$R/CLAUDE.md" ]; then pass "AGENTS incompleto aborta sin tocar destinos"; else fail "AGENTS incompleto dejó escrituras: $OUT"; fi
R="$TMP/config-invalido"; make_repo "$R"; printf '{' > "$R/.mefisto/harness.config.json"; OUT=$(run "$R" --apply); RC=$?
if [ "$RC" -ne 0 ] && [ ! -e "$R/AGENTS.md" ] && [ ! -e "$R/CLAUDE.md" ]; then pass "config inválido aborta antes de escribir"; else fail "config inválido dejó escrituras: $OUT"; fi
R="$TMP/legacy"; make_repo "$R"; printf '## Tokens del harness\nlegacy\n## Verificación de fuentes\n' > "$R/CLAUDE.md"; OUT=$(run "$R" --apply)
if grep -Fxq '@AGENTS.md' "$R/CLAUDE.md" && grep -Fq 'legacy' "$R/CLAUDE.md" && printf '%s' "$OUT" | grep -Fq 'manual'; then pass "legacy se conserva y avisa limpieza manual"; else fail "legacy no fue conservado/avisado"; fi

R="$TMP/symlink"; make_repo "$R"; EXTERNAL="$TMP/external-agents"; printf 'fuera\n' > "$EXTERNAL"; ln -s "$EXTERNAL" "$R/AGENTS.md"; OUT=$(run "$R" --apply); RC=$?
if [ "$RC" -ne 0 ] && [ "$(cat "$EXTERNAL")" = "fuera" ] && [ ! -e "$R/CLAUDE.md" ]; then pass "enlace simbólico aborta sin escapar del consumidor"; else fail "se siguió o modificó un enlace simbólico: $OUT"; fi

R="$TMP/claude-no-escribible"; make_repo "$R"; printf 'contenido propio\n' > "$R/CLAUDE.md"; chmod 444 "$R/CLAUDE.md"; OUT=$(run "$R" --apply); RC=$?; chmod 644 "$R/CLAUDE.md"
if [ "$(id -u)" -eq 0 ]; then pass "CLAUDE.md no escribible omitido bajo root"; elif [ "$RC" -ne 0 ] && [ ! -e "$R/AGENTS.md" ] && [ "$(cat "$R/CLAUDE.md")" = "contenido propio" ]; then pass "CLAUDE.md no escribible aborta antes de crear AGENTS.md"; else fail "CLAUDE.md no escribible dejó una escritura parcial: $OUT"; fi

# El permiso se prueba con un directorio sin bit de escritura; se omite bajo root,
# que puede atravesarlo legítimamente en CI.
R="$TMP/no-escribible"; make_repo "$R"; chmod 555 "$R"; OUT=$(run "$R" --apply); RC=$?; chmod 755 "$R"
if [ "$(id -u)" -eq 0 ]; then pass "destino no escribible omitido bajo root"; elif [ "$RC" -ne 0 ] && [ ! -e "$R/AGENTS.md" ] && [ ! -e "$R/CLAUDE.md" ]; then pass "destino no escribible aborta sin parcial"; else fail "destino no escribible no abortó: $OUT"; fi

echo "Resumen: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
