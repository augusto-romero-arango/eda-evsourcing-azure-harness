#!/usr/bin/env bash
# Contrato del comando fix-review neutral y sus dos proyecciones publicadas.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/commands/fix-review.md"
CLAUDE="$REPO_ROOT/dist/claude/commands/fix-review.md"
OPENCODE="$REPO_ROOT/dist/opencode/commands/mefisto:fix-review.md"
MIRROR="$REPO_ROOT/commands/fix-review.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }
# Posicion de la primera aparicion de un literal; vacio si no esta.
pos() { local pre="${1%%"$2"*}"; [ "$pre" = "$1" ] && echo -1 || echo "${#pre}"; }

echo '[fuente] contrato neutral'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "command" and .id == "fix-review" and .profile == "deep" and .arguments == "<numero-de-PR> [--prepare | --apply-approved <plan-id-sha256>]" and (keys | sort) == ["arguments", "description", "id", "kind", "profile"]' >/dev/null; then pass 'metadata sin agent ni capabilities'; else fail 'metadata neutral invalida'; fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
for forbidden in 'EnterPlanMode' 'ExitPlanMode' 'Co-Authored-By' 'Claude Opus' 'Claude' 'OpenCode' '.claude/' '.opencode/' 'CLAUDE_' '.plugin-root' 'plugins/cache' 'model:' 'tools:' 'allowed-tools:' 'permission:' '`Read`' '`Edit`' '`Write`'; do absent "$body" "$forbidden" "fuente no publica token prohibido: $forbidden"; done
contains "$body" 'Uso: {{mefisto:command fix-review}} <numero-de-PR>' 'uso vacio via directiva command'
contains "$body" '{{mefisto:package-root}}/agents/<id>.md' 'agentes del harness desde package-root'
contains "$body" '{{mefisto:package-root}}/docs/adr/mef-adr-0019-*.md' 'ADR-0019 desde package-root'
contains "$body" '{{mefisto:config-path}}' 'repoSlug desde config-path'
contains "$body" 'augusto-romero-arango/eda-evsourcing-azure-harness' 'default de repoSlug como el planner'
contains "$body" '**No avances a la Fase 3 sin aprobacion del plan.**' 'regla de gate del plan literal'
contains "$body" 'aprobacion explicita' 'aprobacion explicita exigida'
contains "$body" 'in_reply_to' 'respuestas via in_reply_to'
contains "$body" 'NO uses el sub-endpoint `/replies`' 'nunca /replies'
contains "$body" 'Nunca auto-resuelvas comentarios' 'regla: nunca auto-resolver'
contains "$body" 'aborta la Fase 5.4' 'guard de no main en 5.4'
contains "$body" 'docs/convenciones-pr-<numero-de-PR>' 'guard cambia de main a rama docs'
contains "$body" 'La field note siempre se genera' 'regla: field note siempre'
contains "$body" 'mismo idioma del comentario original' 'regla: idioma del comentario'
absent "$body" 'Modelo local' 'sin rama modelo local'
for section in 'Comentarios a corregir' 'Comentarios a explicar' 'Comentarios ya resueltos' 'Comentarios a investigar' 'Orden de ejecucion' '## Verificacion' '## Contexto'; do contains "$body" "$section" "plan conserva seccion: $section"; done

echo '[modos] prepare y apply-approved'
contains "$body" '`<PR> --prepare`' 'forma prepare documentada'
contains "$body" '`<PR> --apply-approved <plan-id-sha256>`' 'forma apply-approved documentada'
contains "$body" 'SHA malformado se rechaza con el mensaje de uso, sin tocar `gh` ni archivos' 'argumentos invalidos rechazados antes de gh'
contains "$body" 'Que exista un perfil `autonomy` no activa el modo aprobado' 'autonomy no activa approved'
contains "$body" '{{mefisto:run fix-review-prepare.sh --project-root' 'prepare via directiva run'
contains "$body" '{{mefisto:run fix-review-admission.sh check --project-root' 'admission via directiva run'
contains "$body" '{{mefisto:run fix-review-receipts.sh record-push --project-root' 'receipts via directiva run'
contains "$body" '.mefisto/pipeline/summaries/' 'plan bajo summaries como exige prepare'
contains "$body" '**No invoques `approve`**' 'prepare no aprueba'
absent "$body" '{{mefisto:run autonomy-profile.sh' 'sin run de autonomy-profile'
run_scripts="$(printf '%s' "$body" | grep -o '{{mefisto:run [a-z0-9-]*\.sh' | sed 's/{{mefisto:run //' | sort -u | tr '\n' ' ')"
if [ "$run_scripts" = 'fix-review-admission.sh fix-review-prepare.sh fix-review-receipts.sh ' ]; then pass 'solo los tres helpers como referencias run'; else fail "referencias run inesperadas: $run_scripts"; fi
contains "$body" 'Sin preguntas dentro del stage' 'approved sin prompt'
contains "$body" 'nunca el POST' 'recibo incierto no repite POST'
contains "$body" 'una sola respuesta por `commentId` aprobado' 'una respuesta por commentId'
p_mode="$(pos "$body" '## Modo aprobado')"
p_preedit="$(pos "$body" '1. **pre-edit**')"; p_code="$(pos "$body" '2. **Cambios de codigo**')"; p_build="$(pos "$body" '3. **Verificar**')"; p_push="$(pos "$body" '4. **pre-push**')"; p_reply="$(pos "$body" '5. **Respuestas**')"; p_impr="$(pos "$body" '6. **Mejoras**')"; p_fn="$(pos "$body" '7. **Field note**')"; p_fin="$(pos "$body" '8. **finish**')"
if [ "$p_mode" -ge 0 ] && [ "$p_mode" -lt "$p_preedit" ] && [ "$p_preedit" -lt "$p_code" ] && [ "$p_code" -lt "$p_build" ] && [ "$p_build" -lt "$p_push" ] && [ "$p_push" -lt "$p_reply" ] && [ "$p_reply" -lt "$p_impr" ] && [ "$p_impr" -lt "$p_fn" ] && [ "$p_fn" -lt "$p_fin" ]; then pass 'approved: pre-edit -> codigo -> build/test -> push -> respuestas -> mejoras -> field note -> finish'; else fail 'orden del modo aprobado roto'; fi
for script in fix-review-prepare.sh fix-review-admission.sh fix-review-receipts.sh; do
    if jq -e --arg s "$script" '[.. | objects | select(has("pattern")) | .pattern | select(contains("/scripts/" + $s + "\""))] | length == 1' "$REPO_ROOT/src/published/contract/opencode-permissions.json" >/dev/null; then pass "mapping OpenCode puntual para $script"; else fail "mapping OpenCode ausente o duplicado para $script"; fi
done
if jq -e '[.. | objects | select(has("pattern")) | .pattern | select(contains("autonomy-profile.sh"))] | length == 0' "$REPO_ROOT/src/published/contract/opencode-permissions.json" >/dev/null; then pass 'mapping sin autonomy-profile.sh'; else fail 'mapping permite autonomy-profile.sh'; fi

echo '[orden]'
prev=-1; ok=1
for marker in '{{mefisto:assert-consumer-repo}}' '## Fase 1: Triaje' '## Fase 2: Plan' 'No avances a la Fase 3 sin aprobacion del plan' 'dotnet build' 'Haz push a la rama del PR' 'Espera aprobacion del usuario antes de publicar' '## Fase 5: Mejora continua' '### 5.5 Field note'; do
    p="$(pos "$body" "$marker")"
    if [ "$p" -le "$prev" ]; then ok=0; fail "orden roto en: $marker"; fi
    prev="$p"
done
[ "$ok" = 1 ] && pass 'guard -> triaje -> plan -> build/test -> push -> respuestas -> mejora -> field note'

echo '[salidas] adaptadores y mirror'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
claude_body="$(< "$CLAUDE")"
opencode_body="$(< "$OPENCODE")"
contains "$opencode_body" 'MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/fix-review-admission.sh" check' 'OpenCode materializa admission'
contains "$claude_body" '/scripts/fix-review-admission.sh" check' 'Claude materializa admission'
contains "$claude_body" 'model: "opus"' 'Claude materializa el perfil deep'
absent "$opencode_body" 'model:' 'OpenCode no emite model'
contains "$claude_body" '${MEFISTO_PACKAGE_ROOT}/agents/' 'Claude lee agentes desde MEFISTO_PACKAGE_ROOT'
contains "$opencode_body" '${MEFISTO_PACKAGE_ROOT}/agents/' 'OpenCode lee agentes desde MEFISTO_PACKAGE_ROOT'
contains "$claude_body" 'repoSlug' 'Claude lee repoSlug'
contains "$opencode_body" 'repoSlug' 'OpenCode lee repoSlug'
absent "$claude_body" 'plugins/cache' 'salida Claude sin cache de plugins'
absent "$opencode_body" 'plugins/cache' 'salida OpenCode sin cache de plugins'
contains "$claude_body" 'Nunca auto-resuelvas comentarios' 'Claude conserva las reglas'
contains "$opencode_body" 'Nunca auto-resuelvas comentarios' 'OpenCode conserva las reglas'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror Claude coincide byte a byte'; else fail 'mirror Claude diverge'; fi
contains "$(< "$MIRROR")" '<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/fix-review.md. No editar a mano. -->' 'mirror conserva marcador generado'
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
