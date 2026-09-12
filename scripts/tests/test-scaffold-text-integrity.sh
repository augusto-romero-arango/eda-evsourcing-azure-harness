#!/usr/bin/env bash
# test-scaffold-text-integrity.sh -- Gates de commit, integridad y pines OpenTelemetry del scaffold (#1229, #1237, #1242, #1246).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PIPELINE="$REPO_ROOT/scripts/scaffold-pipeline.sh"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

create_consumer() {
    local name="$1" consumer remote
    consumer="$TMP_DIR/$name/consumer"
    remote="$TMP_DIR/$name/origin.git"
    mkdir -p "$consumer/.mefisto" "$TMP_DIR/$name"
    git init -q --bare "$remote"
    git init -q -b main "$consumer"
    git -C "$consumer" config user.name "Mefisto Test"
    git -C "$consumer" config user.email "mefisto-test@example.invalid"
    cat > "$consumer/.mefisto/harness.config.json" <<'EOF'
{
  "projectName": "Certificacion",
  "namespacePrefix": "Certificacion",
  "solutionFile": "Certificacion.slnx",
  "domainLabels": ["prueba"],
  "boundedContext": { "name": "Certificacion", "domains": ["prueba"] }
}
EOF
    printf 'base\n' > "$consumer/README.md"
    printf '.claude/pipeline/\n*.log\n' > "$consumer/.gitignore"
    git -C "$consumer" add .
    git -C "$consumer" commit -qm "base"
    git -C "$consumer" remote add origin "$remote"
    git -C "$consumer" push -qu origin main
    printf '%s\n' "$consumer"
}

assert_gate_order() {
    local defensive_commit text_gate otel_gate push
    defensive_commit=$(grep -nF 'commit -m "scaffold($DOMAIN_NAME): nuevo dominio $PASCAL_CASE"' "$PIPELINE" | cut -d: -f1)
    text_gate=$(grep -nF 'diff --check origin/main...HEAD' "$PIPELINE" | cut -d: -f1)
    otel_gate=$(grep -nF 'header "Verificando pines OpenTelemetry"' "$PIPELINE" | cut -d: -f1)
    push=$(grep -nF 'push -u origin "$BRANCH_NAME"' "$PIPELINE" | cut -d: -f1)

    if [ -n "$defensive_commit" ] && [ -n "$text_gate" ] && [ -n "$otel_gate" ] && [ -n "$push" ] \
        && [ "$defensive_commit" -lt "$text_gate" ] && [ "$text_gate" -lt "$otel_gate" ] \
        && [ "$otel_gate" -lt "$push" ]; then
        pass "los gates validan el resultado consolidado despues del commit defensivo y antes del push"
    else
        fail "orden invalido: commit=${defensive_commit:-ausente}, texto=${text_gate:-ausente}, otel=${otel_gate:-ausente}, push=${push:-ausente}"
    fi
}

create_stubs() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$GH_STUB_LOG"
case "${1:-} ${2:-}" in
    "label create") exit 0 ;;
    "pr list") exit 0 ;;
    "pr create") printf '%s\n' 'https://example.invalid/pr/1229'; exit 0 ;;
    *) exit 1 ;;
esac
EOF
    cat > "$bin/claude" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$PWD/src/Certificacion.Prueba"
mkdir -p "$PWD/tests/Certificacion.Prueba.Tests"
case "$SCAFFOLD_FIXTURE" in
    sano|marker-legitimo|otel-function-ausente|otel-tests-ausente)
        printf 'namespace Certificacion.Prueba;\n' > "$PWD/src/Certificacion.Prueba/Program.cs"
        ;;
    whitespace) printf 'namespace Certificacion.Prueba; \n' > "$PWD/src/Certificacion.Prueba/Program.cs" ;;
    crlf) printf 'namespace Certificacion.Prueba;\r\n' > "$PWD/src/Certificacion.Prueba/Program.cs" ;;
    otel-1153|otel-exporter-1153|otel-hosting-duplicado|otel-exporter-duplicado)
        printf 'namespace Certificacion.Prueba;\n' > "$PWD/src/Certificacion.Prueba/Program.cs"
        ;;
    runtime-solo)
        printf 'namespace Certificacion.Prueba;\n' > "$PWD/src/Certificacion.Prueba/Program.cs"
        ;;
esac
case "$SCAFFOLD_FIXTURE" in
    otel-1153)
        hosting_version="1.15.3"
        exporter_version="1.15.3"
        ;;
    otel-exporter-1153)
        hosting_version="1.13.1"
        exporter_version="1.15.3"
        ;;
    *)
        hosting_version="1.13.1"
        exporter_version="1.13.1"
        ;;
esac
if [ "$SCAFFOLD_FIXTURE" != "otel-function-ausente" ]; then
    cat > "$PWD/src/Certificacion.Prueba/Certificacion.Prueba.csproj" <<EOF_CSPROJ
<Project><ItemGroup><PackageReference Include="OpenTelemetry.Extensions.Hosting" Version="$hosting_version" /></ItemGroup></Project>
EOF_CSPROJ
fi
if [ "$SCAFFOLD_FIXTURE" = "otel-hosting-duplicado" ]; then
    printf '<Project><ItemGroup><PackageReference Include="OpenTelemetry.Extensions.Hosting" Version="1.13.1" /><PackageReference Include="OpenTelemetry.Extensions.Hosting" Version="1.13.1" /></ItemGroup></Project>\n' > "$PWD/src/Certificacion.Prueba/Certificacion.Prueba.csproj"
fi
if [ "$SCAFFOLD_FIXTURE" != "otel-tests-ausente" ]; then
    cat > "$PWD/tests/Certificacion.Prueba.Tests/Certificacion.Prueba.Tests.csproj" <<EOF_CSPROJ
<Project><ItemGroup><PackageReference Include="OpenTelemetry.Exporter.InMemory" Version="$exporter_version" /></ItemGroup></Project>
EOF_CSPROJ
fi
if [ "$SCAFFOLD_FIXTURE" = "otel-exporter-duplicado" ]; then
    printf '<Project><ItemGroup><PackageReference Include="OpenTelemetry.Exporter.InMemory" Version="1.13.1" /><PackageReference Include="OpenTelemetry.Exporter.InMemory" Version="1.13.1" /></ItemGroup></Project>\n' > "$PWD/tests/Certificacion.Prueba.Tests/Certificacion.Prueba.Tests.csproj"
fi
if [ "$SCAFFOLD_FIXTURE" = "runtime-solo" ]; then
    git add src/Certificacion.Prueba/Program.cs \
        src/Certificacion.Prueba/Certificacion.Prueba.csproj \
        tests/Certificacion.Prueba.Tests/Certificacion.Prueba.Tests.csproj
    git commit -qm 'scaffold(prueba): nuevo dominio Prueba'
fi
if [ "$SCAFFOLD_FIXTURE" = "marker-legitimo" ] || [ "$SCAFFOLD_FIXTURE" = "runtime-solo" ]; then
    mkdir -p "$PWD/.claude/pipeline"
    printf 'plugin-root' > "$PWD/.claude/pipeline/.plugin-root"
    git check-ignore -q .claude/pipeline/.plugin-root || exit 98
fi
EOF
    chmod +x "$bin/gh" "$bin/claude"
}

assert_otlp_gate_legacy_contract() {
    local resultado
    resultado=$(python3 - "$PIPELINE" 2>&1 <<'PY'
import re
import sys
from pathlib import Path

pipeline = Path(sys.argv[1]).read_text()
packages = (
    "OpenTelemetry.Extensions.Hosting",
    "OpenTelemetry.Exporter.InMemory",
)
# Issue #1246 actualiza la receta publicada pero excluye expresamente este pipeline: el gate
# conserva 1.13.1 hasta el issue mecanico posterior. Este test sigue cubriendo su comportamiento
# actual sin exigir que dos componentes que se entregan por separado cambien en el mismo PR.
pin = "1.13.1"
if re.search(rf'OTEL_PIN_CANONICO="{re.escape(pin)}"', pipeline) is None:
    raise SystemExit(f"el gate diferido no conserva su pin previo: {pin}")

for package in packages:
    if f'verificar_pin_otlp "{package}" "$OTEL_PIN_CANONICO"' not in pipeline:
        raise SystemExit(f"el gate diferido no verifica {package}")
PY
)
    if [ $? -eq 0 ]; then
        pass "el gate mecanico diferido conserva su contrato previo sin seguir la receta nueva"
    else
        fail "contrato del gate mecanico diferido invalido: $resultado"
    fi
}

run_case() {
    local scenario="$1" consumer bin
    consumer="$(create_consumer "$scenario")"
    bin="$TMP_DIR/$scenario/bin"
    create_stubs "$bin"
    GH_STUB_LOG="$TMP_DIR/$scenario/gh.log"
    : > "$GH_STUB_LOG"
    (
        cd "$consumer" || exit 99
        SCAFFOLD_FIXTURE="$scenario" GH_STUB_LOG="$GH_STUB_LOG" PATH="$bin:$PATH" \
            "$PIPELINE" --domain prueba
    ) > "$TMP_DIR/$scenario.out" 2>&1
    LAST_RC=$?
    LAST_CONSUMER="$consumer"
    LAST_GH_LOG="$GH_STUB_LOG"
}

echo "[1] Output sano: verifica el rango y conserva push/PR (CA-1/CA-4)"
assert_gate_order
assert_otlp_gate_legacy_contract
run_case sano
if [ "$LAST_RC" -eq 0 ]; then pass "el scaffold sano completa"; else fail "el scaffold sano fallo (rc $LAST_RC)"; fi
if git -C "$LAST_CONSUMER" ls-remote --exit-code origin refs/heads/scaffold-prueba >/dev/null 2>&1; then pass "el camino sano hace push"; else fail "el camino sano no publico la rama"; fi
if grep -qF 'gh pr create' "$LAST_GH_LOG"; then pass "el camino sano crea el PR"; else fail "el camino sano no crea el PR"; fi
if grep -qF 'Integridad textual verificada' "$TMP_DIR/sano.out"; then pass "el camino sano informa el gate"; else fail "no informo la integridad textual"; fi
if grep -qF 'Pines OpenTelemetry verificados' "$TMP_DIR/sano.out"; then pass "el camino sano informa el gate de pines"; else fail "no informo los pines OpenTelemetry"; fi

echo "[2] Marker runtime y archivo legitimo: el commit defensivo excluye .claude/ (CA-1/CA-2)"
run_case marker-legitimo
if [ "$LAST_RC" -eq 0 ]; then pass "el marker con suciedad legitima completa"; else fail "el marker con suciedad legitima fallo (rc $LAST_RC)"; fi
if git -C "$LAST_CONSUMER" show "origin/scaffold-prueba:src/Certificacion.Prueba/Program.cs" >/dev/null 2>&1; then pass "el commit defensivo incluye el archivo legitimo"; else fail "el commit defensivo no incluye el archivo legitimo"; fi
if ! git -C "$LAST_CONSUMER" show "origin/scaffold-prueba:.claude/pipeline/.plugin-root" >/dev/null 2>&1; then pass "el marker runtime queda fuera del indice"; else fail "el marker runtime fue incluido en el indice"; fi

echo "[3] Solo estado runtime: el guard no crea un commit vacio (CA-3)"
run_case runtime-solo
if [ "$LAST_RC" -eq 0 ]; then pass "solo estado runtime completa"; else fail "solo estado runtime fallo (rc $LAST_RC)"; fi
if ! grep -qF 'commiteando defensivamente' "$TMP_DIR/runtime-solo.out"; then pass "solo estado runtime no activa el commit defensivo"; else fail "solo estado runtime intento un commit defensivo vacio"; fi
if ! git -C "$LAST_CONSUMER" show "origin/scaffold-prueba:.claude/pipeline/.plugin-root" >/dev/null 2>&1; then pass "solo estado runtime conserva el marker fuera del indice"; else fail "solo estado runtime incluyo el marker en el indice"; fi

echo "[4] Trailing whitespace: aborta antes de publicar y conserva diagnostico (CA-2/CA-3)"
run_case whitespace
if [ "$LAST_RC" -ne 0 ]; then pass "trailing whitespace aborta"; else fail "trailing whitespace no debe completar"; fi
if ! git -C "$LAST_CONSUMER" ls-remote --exit-code origin refs/heads/scaffold-prueba >/dev/null 2>&1; then pass "trailing whitespace no hace push"; else fail "trailing whitespace publico una rama"; fi
if ! grep -qF 'gh pr create' "$LAST_GH_LOG"; then pass "trailing whitespace no crea PR"; else fail "trailing whitespace intento crear PR"; fi
if grep -qF "errores de whitespace detectados por 'git diff --check'" "$TMP_DIR/whitespace.out"; then pass "trailing whitespace muestra una ruta de diagnostico"; else fail "trailing whitespace no muestra diagnostico accionable"; fi
if grep -qF 'Program.cs:1:' "$LAST_CONSUMER/.claude/pipeline/logs/"scaffold-*.log 2>/dev/null; then pass "trailing whitespace queda en el diagnostico"; else fail "trailing whitespace no quedo en el diagnostico"; fi

echo "[5] Finales CRLF: abortan antes de publicar (CA-3)"
run_case crlf
if [ "$LAST_RC" -ne 0 ]; then pass "CRLF aborta"; else fail "CRLF no debe completar"; fi
if ! git -C "$LAST_CONSUMER" ls-remote --exit-code origin refs/heads/scaffold-prueba >/dev/null 2>&1; then pass "CRLF no hace push"; else fail "CRLF publico una rama"; fi
if ! grep -qF 'gh pr create' "$LAST_GH_LOG"; then pass "CRLF no crea PR"; else fail "CRLF intento crear PR"; fi
if grep -qF 'Program.cs:1:' "$LAST_CONSUMER/.claude/pipeline/logs/"scaffold-*.log 2>/dev/null; then pass "CRLF queda en el diagnostico"; else fail "CRLF no quedo en el diagnostico"; fi

echo "[6] Pines OpenTelemetry: el runner rechaza la deriva observada antes del push (CA-1/CA-2/CA-3)"
run_case otel-1153
if [ "$LAST_RC" -ne 0 ]; then pass "los pines 1.15.3 abortan"; else fail "los pines 1.15.3 no deben completar"; fi
if ! git -C "$LAST_CONSUMER" ls-remote --exit-code origin refs/heads/scaffold-prueba >/dev/null 2>&1; then pass "los pines 1.15.3 no hacen push"; else fail "los pines 1.15.3 publicaron una rama"; fi
if ! grep -qF 'gh pr create' "$LAST_GH_LOG"; then pass "los pines 1.15.3 no crean PR"; else fail "los pines 1.15.3 intentaron crear PR"; fi
if grep -qF 'OpenTelemetry.Extensions.Hosting' "$TMP_DIR/otel-1153.out" \
    && grep -qF '1.13.1' "$TMP_DIR/otel-1153.out" \
    && grep -qF 'Certificacion.Prueba.csproj' "$TMP_DIR/otel-1153.out"; then
    pass "el mismatch identifica paquete, pin esperado y csproj"
else
    fail "el mismatch no deja diagnostico accionable"
fi

echo "[7] Pin de tests: el runner tambien rechaza su deriva antes del push (CA-2/CA-3)"
run_case otel-exporter-1153
if [ "$LAST_RC" -ne 0 ] && ! git -C "$LAST_CONSUMER" ls-remote --exit-code origin refs/heads/scaffold-prueba >/dev/null 2>&1 \
    && grep -qF 'OpenTelemetry.Exporter.InMemory' "$TMP_DIR/otel-exporter-1153.out" \
    && grep -qF '1.13.1' "$TMP_DIR/otel-exporter-1153.out" \
    && grep -qF 'Certificacion.Prueba.Tests.csproj' "$TMP_DIR/otel-exporter-1153.out"; then
    pass "el mismatch de tests aborta antes del push con diagnostico completo"
else
    fail "el mismatch de tests no fue rechazado correctamente"
fi

echo "[8] Duplicados: ambos paquetes abortan antes del push (CA-3)"
run_case otel-hosting-duplicado
if [ "$LAST_RC" -ne 0 ] && ! git -C "$LAST_CONSUMER" ls-remote --exit-code origin refs/heads/scaffold-prueba >/dev/null 2>&1 \
    && grep -qF 'OpenTelemetry.Extensions.Hosting' "$TMP_DIR/otel-hosting-duplicado.out" \
    && grep -qF '1.13.1' "$TMP_DIR/otel-hosting-duplicado.out" \
    && grep -qF 'Certificacion.Prueba.csproj' "$TMP_DIR/otel-hosting-duplicado.out"; then
    pass "el duplicado de produccion aborta antes del push con diagnostico completo"
else
    fail "el duplicado de produccion no fue rechazado correctamente"
fi
run_case otel-exporter-duplicado
if [ "$LAST_RC" -ne 0 ] && ! git -C "$LAST_CONSUMER" ls-remote --exit-code origin refs/heads/scaffold-prueba >/dev/null 2>&1 \
    && grep -qF 'OpenTelemetry.Exporter.InMemory' "$TMP_DIR/otel-exporter-duplicado.out" \
    && grep -qF '1.13.1' "$TMP_DIR/otel-exporter-duplicado.out" \
    && grep -qF 'Certificacion.Prueba.Tests.csproj' "$TMP_DIR/otel-exporter-duplicado.out"; then
    pass "el duplicado de tests aborta antes del push con diagnostico completo"
else
    fail "el duplicado de tests no fue rechazado correctamente"
fi

echo "[9] Proyectos ausentes: ambos csproj abortan antes del push (CA-3)"
run_case otel-function-ausente
if [ "$LAST_RC" -ne 0 ] && ! git -C "$LAST_CONSUMER" ls-remote --exit-code origin refs/heads/scaffold-prueba >/dev/null 2>&1 \
    && grep -qF 'OpenTelemetry.Extensions.Hosting' "$TMP_DIR/otel-function-ausente.out" \
    && grep -qF '1.13.1' "$TMP_DIR/otel-function-ausente.out" \
    && grep -qF 'Certificacion.Prueba.csproj' "$TMP_DIR/otel-function-ausente.out"; then
    pass "el proyecto de produccion ausente aborta antes del push con diagnostico completo"
else
    fail "el proyecto de produccion ausente no fue rechazado correctamente"
fi
run_case otel-tests-ausente
if [ "$LAST_RC" -ne 0 ] && ! git -C "$LAST_CONSUMER" ls-remote --exit-code origin refs/heads/scaffold-prueba >/dev/null 2>&1 \
    && grep -qF 'OpenTelemetry.Exporter.InMemory' "$TMP_DIR/otel-tests-ausente.out" \
    && grep -qF '1.13.1' "$TMP_DIR/otel-tests-ausente.out" \
    && grep -qF 'Certificacion.Prueba.Tests.csproj' "$TMP_DIR/otel-tests-ausente.out"; then
    pass "el proyecto de tests ausente aborta antes del push con diagnostico completo"
else
    fail "el proyecto de tests ausente no fue rechazado correctamente"
fi

echo
echo "Resumen: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
