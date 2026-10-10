#!/usr/bin/env bash
# test-onboard-runtime-aware.sh -- puente CLAUDE.md requerido por runtime (issue #1676).
#   (a) opencode sin CLAUDE.md y AGENTS.md completo: sin FALTA del puente, mismo estado que el baseline
#   (b) claude sin CLAUDE.md: FALTA
#   (c) opencode con CLAUDE.md con secciones duplicadas: sigue reportando la limpieza
#   (d) migracion bajo opencode no crea CLAUDE.md salvo con --with-claude-bridge
#   (e) los scripts de dist/opencode/scripts/ resuelven _pipeline-common.sh desde dist/
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1" = "label" ]; then
    printf '%s\n' tipo:feature tipo:infra tipo:refactor tipo:tooling tipo:projection estado:borrador estado:listo bug bloqueado dom:dominio1
elif [ "$1" = "secret" ]; then
    printf '%s\t%s\n' AZURE_CLIENT_ID ahora AZURE_TENANT_ID ahora AZURE_SUBSCRIPTION_ID ahora TF_VAR_POSTGRESQL_ADMIN_PASSWORD ahora
fi
GH
cat > "$BIN/az" <<'AZ'
#!/usr/bin/env bash
[ "$1" = "account" ] && exit 0
[ "$*" = 'ad app list --display-name ci-diagnostico --query [0].appId -o tsv' ] && printf 'APP\n'
AZ
chmod +x "$BIN/gh" "$BIN/az"

make_repo() {
    local r="$1"
    mkdir -p "$r/.mefisto" "$r/src" "$r/tests" "$r/infra/environments"; (cd "$r" && git init -q)
    printf '.mefisto/pipeline/\n' > "$r/.gitignore"
    cat > "$r/.mefisto/harness.config.json" <<'JSON'
{"projectName":"Diagnostico","namespacePrefix":"Diagnostico.Dominio","solutionFile":"Diagnostico.slnx","githubServicePrincipalName":"ci-diagnostico","domainLabels":["dominio1"],"boundedContext":{"name":"Principal","domains":["dominio1"]},"secrets":[],"tenancy":{"strategy":"mono-tenant-transitorio"},"projections":{"enabled":false}}
JSON
    # Activacion por repositorio commiteada (MEF-ADR-0053 decision 2): sin ella, el
    # baseline bajo claude sumaria un FALTA que opencode no reporta.
    mkdir -p "$r/.claude"
    printf '{"enabledPlugins":{"mefisto@augusto-romero-arango-harness":true}}\n' > "$r/.claude/settings.json"
    (cd "$r" && git add .claude/settings.json && git -c user.email=t@t -c user.name=t commit -q -m settings)
    cat > "$r/AGENTS.md" <<'MD'
### Tokens del harness

- **RootNamespace**: A
- **SolutionFile**: A
- **ProjectDisplayName**: A
- **BoundedContext**: A
- **BoundedContextDomains**: A

### Verificación de fuentes

Cita fuentes.
MD
}
diag() { (cd "$1" && CLAUDE_CONFIG_DIR="$TMP/claude-config" MEFISTO_RUNTIME="$2" PATH="$BIN:$PATH" bash "${3:-$REPO_ROOT/scripts}/onboard-diagnose.sh" 2>&1); }
faltas() { printf '%s\n' "$1" | sed -n 's/.*| \([0-9]*\) FALTA.*/\1/p'; }

echo "[R-1] diagnostico por runtime"
R="$TMP/r1"; make_repo "$R"; printf '@AGENTS.md\n' > "$R/CLAUDE.md"
BASE=$(diag "$R" claude); BASE_F=$(faltas "$BASE")
rm "$R/CLAUDE.md"
OUT=$(diag "$R" opencode)
if ! printf '%s\n' "$OUT" | grep -Fq '[FALTA        ] puente' && ! printf '%s\n' "$OUT" | grep -Fq 'CLAUDE.md no existe' \
    && printf '%s\n' "$OUT" | grep -Fq 'solo lo requiere Claude Code' && [ "$(faltas "$OUT")" = "$BASE_F" ]; then
    pass "(a) opencode sin CLAUDE.md: fila informativa y sin FALTA adicional"
else fail "(a) opencode sin CLAUDE.md: $OUT"; fi
if [ "$BASE_F" = "0" ]; then
    printf '%s\n' "$OUT" | grep -Fq 'Estado: LISTO' && pass "(a) estado LISTO" || fail "(a) no quedo LISTO"
else pass "(a) baseline con FALTA ajenos ($BASE_F); LISTO no aplicable en este entorno"; fi
OUT=$(diag "$R" claude)
if printf '%s\n' "$OUT" | grep -Fq '[FALTA        ] CLAUDE.md no existe' && [ "$(faltas "$OUT")" = "$((BASE_F + 1))" ]; then
    pass "(b) claude sin CLAUDE.md reporta FALTA"
else fail "(b) claude sin CLAUDE.md: $OUT"; fi
printf '@AGENTS.md\n## Tokens del harness\nx\n' > "$R/CLAUDE.md"
OUT=$(diag "$R" opencode)
if printf '%s\n' "$OUT" | grep -Fq 'secciones contractuales legacy' && [ "$(faltas "$OUT")" = "$BASE_F" ]; then
    pass "(c) opencode con duplicados sigue reportando la limpieza sin sumar FALTA"
else fail "(c) limpieza no reportada: $OUT"; fi

echo "[R-2] migracion por runtime"
mig() { (cd "$1" && MEFISTO_RUNTIME="$2" bash "${4:-$REPO_ROOT/scripts}/onboard-migrate-directives.sh" $3 2>&1); }
R="$TMP/r2"; make_repo "$R"; rm "$R/AGENTS.md"
OUT=$(mig "$R" opencode --preview)
if printf '%s\n' "$OUT" | grep -Fq 'Omitido (opcional)' && [ ! -e "$R/CLAUDE.md" ]; then pass "(d) preview opencode lista el puente como omitido"; else fail "(d) preview: $OUT"; fi
mig "$R" opencode --apply >/dev/null
if [ -f "$R/AGENTS.md" ] && [ ! -e "$R/CLAUDE.md" ]; then pass "(d) apply opencode crea AGENTS.md y no toca CLAUDE.md"; else fail "(d) apply opencode"; fi
R="$TMP/r2b"; make_repo "$R"; rm "$R/AGENTS.md"
(cd "$R" && MEFISTO_RUNTIME=opencode bash "$REPO_ROOT/scripts/onboard-migrate-directives.sh" --apply --with-claude-bridge >/dev/null 2>&1)
grep -Fxq '@AGENTS.md' "$R/CLAUDE.md" 2>/dev/null && pass "(d) --with-claude-bridge crea el puente" || fail "(d) --with-claude-bridge"
R="$TMP/r2c"; make_repo "$R"; rm "$R/AGENTS.md"; mig "$R" claude --apply >/dev/null
grep -Fxq '@AGENTS.md' "$R/CLAUDE.md" 2>/dev/null && pass "claude crea el puente sin flag" || fail "claude no creo el puente"

R="$TMP/r2d"; make_repo "$R"; rm "$R/AGENTS.md"; ln -s AGENTS.md "$R/CLAUDE.md"
mig "$R" opencode --apply >/dev/null; RC=$?
if [ "$RC" -eq 0 ] && [ -f "$R/AGENTS.md" ] && [ -L "$R/CLAUDE.md" ]; then pass "(d) opencode ignora un CLAUDE.md enlace sin el flag"; else fail "(d) opencode con CLAUDE.md enlace (rc=$RC)"; fi
R="$TMP/r2e"; make_repo "$R"; rm "$R/AGENTS.md"
mig "$R" opencode "--with-claude-bridge --apply" >/dev/null
grep -Fxq '@AGENTS.md' "$R/CLAUDE.md" 2>/dev/null && pass "(d) el flag se acepta antes del modo" || fail "(d) orden de flags"

echo "[R-3] scripts publicados en dist/opencode/scripts"
D="$REPO_ROOT/dist/opencode/scripts"
R="$TMP/r3"; make_repo "$R"; rm "$R/AGENTS.md"
OUT=$(mig "$R" opencode --apply "$D"); RC=$?
if [ "$RC" -eq 0 ] && [ -f "$R/AGENTS.md" ] && [ ! -e "$R/CLAUDE.md" ]; then pass "(e) migracion desde dist resuelve _pipeline-common.sh"; else fail "(e) migracion: $OUT"; fi
OUT=$(diag "$R" opencode "$D")
if printf '%s\n' "$OUT" | grep -Fq '[OK           ] config efectivo'; then pass "(e) diagnostico desde dist carga la config"; else fail "(e) diagnostico: $OUT"; fi

echo ""; echo "Resultado: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
