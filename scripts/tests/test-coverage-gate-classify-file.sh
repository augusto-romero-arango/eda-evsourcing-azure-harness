#!/usr/bin/env bash
# test-coverage-gate-classify-file.sh — Tests de classify_file() (Stage 4,
# coverage gate) para issue #414: alinea classify_file con la doctrina en dos
# puntos que hoy fallan en silencio (caen en not_evaluated, que solo se loguea
# y nunca hace fallar el gate).
#
# Valida:
#   C) *Projection.cs se clasifica logic (CA-1, MEF-ADR-0034 seccion 9),
#      sin gatear por IS_PROJECTION, y sin falso positivo en el plural
#      ConfiguracionMartenProjections{Dominio}.cs (MEF-ADR-0006)
#   D) La exclusion de records DTO reconoce el estilo canonico -- modificadores
#      entre 'public' y 'record' (sealed/partial) y forma multilinea -- sin
#      depender del conteo de lineas (CA-2), sin regresionar el caso de una
#      linea (CA-5) ni excluir un record CON metodos (CA-3)
#   E) El orden de evaluacion de classify_file no cambia: un evento con
#      factory Crear() en /Eventos/ resuelve a logic antes de llegar a la
#      exclusion de DTOs (CA-3)
#   F) Coherencia entre este test y scripts/tdd-pipeline.sh (deteccion de drift)
#
# Precedente: scripts/tests/test-projection-branch.sh (reimplementacion local
# de la logica + verificacion de coherencia por grep -qF contra el script real,
# porque classify_file esta definida inline dentro del Stage 4 y no es
# sourceable).
#
# Uso: scripts/tests/test-coverage-gate-classify-file.sh
# Exit code: 0 si todos los escenarios pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TDD_SCRIPT="$REPO_ROOT/scripts/tdd-pipeline.sh"

PASS=0
FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        echo "    esperado: $expected"
        echo "    obtenido: $actual"
        FAIL=$((FAIL + 1))
    fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Reimplementacion local de classify_file() (Stage 4 de scripts/tdd-pipeline.sh,
# issue #414). Cualquier cambio aqui debe acompanarse de un cambio en el script
# real (Escenario F). Recibe WORKTREE_PATH e IS_PROJECTION como parametros en
# vez de globals para poder variarlos por caso de test.
classify_file_local() {
    local worktree="$1" is_projection="$2" filepath="$3"
    local basename dirname
    basename=$(basename "$filepath")
    dirname=$(dirname "$filepath")

    case "$basename" in
        HealthCheck.cs|Program.cs|*Mensajes.cs|*AssemblyMarker.cs|ConfiguracionSerializacion*.cs|*.resx)
            echo "excluded"; return ;;
    esac

    if echo "$dirname" | grep -q '/Infraestructura/'; then
        case "$basename" in
            RequestValidator.cs|ServiceBusDeserializador.cs)
                echo "excluded"; return ;;
        esac
    fi

    local query_dir
    query_dir=$(basename "$dirname")
    if [ "$is_projection" = true ] && [ "$basename" = "FunctionEndpoint.cs" ] \
       && [ "${query_dir%Function}" = "$query_dir" ] \
       && echo "$query_dir" | grep -qE '^(Obtener|Listar)[A-Za-z0-9]*$'; then
        echo "excluded"; return
    fi

    case "$basename" in
        *CommandHandler.cs|*AggregateRoot.cs|*Validator.cs|FunctionEndpoint.cs|*Projection.cs)
            echo "logic"; return ;;
    esac

    if echo "$dirname" | grep -q '/Eventos/\|/Entities/'; then
        if [ -f "$worktree/$filepath" ] && grep -q 'static.*Crear(' "$worktree/$filepath" 2>/dev/null; then
            echo "logic"; return
        fi
    fi

    if echo "$dirname" | grep -q '/ValueObjects/'; then
        if [ -f "$worktree/$filepath" ] && grep -q 'static.*Crear(' "$worktree/$filepath" 2>/dev/null; then
            echo "logic"; return
        fi
    fi

    if [ -f "$worktree/$filepath" ]; then
        local content
        content=$(grep -v '^\s*//' "$worktree/$filepath" | grep -v '^\s*$' | grep -v '^using ' | grep -v '^namespace ' || true)
        local content_flat
        content_flat=$(echo "$content" | tr '\n' ' ')
        local record_decl
        record_decl=$(echo "$content_flat" | grep -oE 'public\s+(sealed\s+|partial\s+)*record\s+\w+\([^()]*\)[^;{]*[;{]' 2>/dev/null | head -1)
        if [ -n "$record_decl" ]; then
            case "$record_decl" in
                *\;) echo "excluded"; return ;;
            esac
        fi
    fi

    echo "not_evaluated"
}

write_fixture() {
    local relpath="$1" content="$2"
    local full="$TMP_DIR/$relpath"
    mkdir -p "$(dirname "$full")"
    printf '%s' "$content" > "$full"
}

# ─── Escenario C: *Projection.cs -> logic, sin gatear por IS_PROJECTION (CA-1) ─
echo "Escenario C: clase de proyeccion companion -> logic"
write_fixture "src/Foo.Bar/TurnoProjection.cs" 'namespace Foo.Bar;

public sealed partial class TurnoProjection : SingleStreamProjection<TurnoView, Guid>
{
    public static TurnoView Create(TurnoCreado e) => new(e.Id, "Abierto");
}
'
assert_eq "C1: *Projection.cs -> logic con IS_PROJECTION=true" "logic" \
    "$(classify_file_local "$TMP_DIR" true "src/Foo.Bar/TurnoProjection.cs")"
assert_eq "C2: *Projection.cs -> logic con IS_PROJECTION=false (no gateado)" "logic" \
    "$(classify_file_local "$TMP_DIR" false "src/Foo.Bar/TurnoProjection.cs")"

write_fixture "src/Foo.Bar/ConfiguracionMartenProjections.cs" 'namespace Foo.Bar;

public static class ConfiguracionMartenProjections { }
'
assert_eq "C3: ConfiguracionMartenProjections.cs (plural) no entra al patron singular" "not_evaluated" \
    "$(classify_file_local "$TMP_DIR" false "src/Foo.Bar/ConfiguracionMartenProjections.cs")"

write_fixture "src/Foo.Bar/ConfiguracionMartenProjectionsVentas.cs" 'namespace Foo.Bar;

public static class ConfiguracionMartenProjectionsVentas { }
'
assert_eq "C4: ConfiguracionMartenProjections{Dominio}.cs (plural+sufijo) tampoco" "not_evaluated" \
    "$(classify_file_local "$TMP_DIR" false "src/Foo.Bar/ConfiguracionMartenProjectionsVentas.cs")"

# ─── Escenario D: exclusion de records DTO del estilo canonico (CA-2/CA-3/CA-5) ─
echo "Escenario D: records DTO del estilo canonico -> excluded; con metodos -> no excluido; una linea no regresiona"
write_fixture "src/Foo.ReadModels/TurnoView.cs" 'namespace Foo.ReadModels;

public sealed record TurnoView(
    Guid Id, string Estado, DateOnly FechaInicio);
'
assert_eq "D1: public sealed record multilinea -> excluded" "excluded" \
    "$(classify_file_local "$TMP_DIR" false "src/Foo.ReadModels/TurnoView.cs")"

write_fixture "src/Foo.ReadModels/PlanoView.cs" 'namespace Foo.ReadModels;

public record PlanoView(Guid Id, string Nombre);
'
assert_eq "D2: public record de una linea -> excluded (no regresiona, CA-5)" "excluded" \
    "$(classify_file_local "$TMP_DIR" false "src/Foo.ReadModels/PlanoView.cs")"

write_fixture "src/Foo.ReadModels/ResumenView.cs" 'namespace Foo.ReadModels;

public sealed record ResumenView(Guid Id, string Estado)
{
    public bool EsActivo() => Estado == "Abierto";
}
'
assert_eq "D3: record CON metodos no se excluye por esta regla (CA-3)" "not_evaluated" \
    "$(classify_file_local "$TMP_DIR" false "src/Foo.ReadModels/ResumenView.cs")"

write_fixture "src/Foo.ReadModels/OtraView.cs" 'namespace Foo.ReadModels;

public sealed partial record OtraView(Guid Id);
'
assert_eq "D4: modificadores sealed+partial combinados -> excluded" "excluded" \
    "$(classify_file_local "$TMP_DIR" false "src/Foo.ReadModels/OtraView.cs")"

# ─── Escenario E: orden de evaluacion intacto (CA-3) ────────────────────────
echo "Escenario E: evento con factory Crear() en /Eventos/ resuelve logic antes de la exclusion de DTOs"
# Nota (hallazgo fuera de alcance de #414, no corregido aqui): el check
# '/Eventos/\|/Entities/' matchea sobre $dirname con slash de cierre, asi que
# solo dispara cuando esos nombres son un segmento NO-hoja de la ruta -- nunca
# en la convencion documentada '{Dominio}/{Feature}/Eventos/{Evento}.cs'
# (agents/test-writer.md:770), donde Eventos es la carpeta hoja y $dirname
# nunca lleva '/' de cierre. Preexistente e intacto por este issue (no lo toca
# el diff de classify_file); el fixture usa un segmento extra para ejercitar el
# mecanismo tal cual existe hoy y probar lo que CA-3 exige: que cuando ese check
# dispara, sigue resolviendo a logic ANTES de llegar a la exclusion de DTOs.
write_fixture "src/Foo.Bar/Feature/Eventos/V1/TurnoCreado.cs" 'namespace Foo.Bar.Feature.Eventos;

public sealed record TurnoCreado(Guid Id)
{
    public static TurnoCreado Crear(Guid id) => new(id);
}
'
assert_eq "E1: evento con Crear() -> logic (no cae en la exclusion de DTOs)" "logic" \
    "$(classify_file_local "$TMP_DIR" false "src/Foo.Bar/Feature/Eventos/V1/TurnoCreado.cs")"

write_fixture "src/Foo.Bar/Feature/Entities/V1/Codigo.cs" 'namespace Foo.Bar.Feature.Entities;

public sealed record Codigo(string Valor)
{
    public static Codigo Crear(string valor) => new(valor);
}
'
assert_eq "E2: Entity con Crear() -> logic (no cae en la exclusion de DTOs)" "logic" \
    "$(classify_file_local "$TMP_DIR" false "src/Foo.Bar/Feature/Entities/V1/Codigo.cs")"

# Mismo hallazgo fuera de alcance que arriba, tambien preexistente para
# '/ValueObjects/' (convencion real: 'Contracts/ValueObjects/{VO}.cs', hoja).
write_fixture "src/Foo.Bar/Contracts/ValueObjects/V1/Codigo.cs" 'namespace Foo.Bar.Contracts.ValueObjects;

public sealed record Codigo(string Valor)
{
    public static Codigo Crear(string valor) => new(valor);
}
'
assert_eq "E3: ValueObject con Crear() -> logic (no cae en la exclusion de DTOs)" "logic" \
    "$(classify_file_local "$TMP_DIR" false "src/Foo.Bar/Contracts/ValueObjects/V1/Codigo.cs")"

# ─── Escenario F: coherencia con el script real ─────────────────────────────
echo "Escenario F: coherencia entre este test y scripts/tdd-pipeline.sh"

assert_script_contains() {
    local name="$1" needle="$2"
    if grep -qF -- "$needle" "$TDD_SCRIPT"; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        echo "    cadena ausente en $TDD_SCRIPT: $needle"
        FAIL=$((FAIL + 1))
    fi
}

assert_script_contains "F1: *Projection.cs se suma al case de logica, sin gateo" \
    '*CommandHandler.cs|*AggregateRoot.cs|*Validator.cs|FunctionEndpoint.cs|*Projection.cs)'
assert_script_contains "F2: la exclusion de DTOs aplana el contenido (sin depender de line_count)" \
    "content_flat=\$(echo \"\$content\" | tr '\n' ' ')"
assert_script_contains "F3: regex admite modificadores sealed/partial entre public y record" \
    "grep -oE 'public\s+(sealed\s+|partial\s+)*record\s+\w+\([^()]*\)[^;{]*[;{]'"
assert_script_contains "F4: DTO sin cuerpo se detecta por terminar en ';' tras la exclusion" \
    '*\;) echo "excluded"; return ;;'

echo
echo "─── Resumen ───"
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
