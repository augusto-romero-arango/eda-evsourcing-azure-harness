#!/usr/bin/env bash
# test-coverage-gate-classify-file.sh — Tests de coverage_classify_file()
# (scripts/_pipeline-common.sh), la funcion de clasificacion del coverage gate
# del Stage 4 de scripts/tdd-pipeline.sh.
#
# Issue #416: la funcion vivia inline dentro del Stage 4 y no era sourceable,
# asi que el precedente (issue #414, y antes #371 en
# scripts/tests/test-projection-branch.sh) la reimplementaba localmente mas
# escenarios de coherencia por grep -qF contra el script real -- funciona,
# pero reimplementacion y original pueden divergir sin que el grep lo note (el
# grep detecta que una linea sigue ahi, no que la logica alrededor cambio de
# forma que altera el resultado). Ahora que la funcion vive en
# scripts/_pipeline-common.sh, este archivo la sourcea y ejercita la funcion
# REAL con fixtures .cs en disco -- sin reimplementacion, sin riesgo de
# divergencia.
#
# Cubre todas las ramas vigentes de clasificacion:
#   A) Exclusion por nombre de archivo (boilerplate/wiring)
#   B) Exclusion por directorio de infraestructura (wiring puro)
#   C) Carve-out read-side de FunctionEndpoint.cs gateado por is_projection
#      (issue #371, MEF-ADR-0014 + MEF-ADR-0035 seccion 6)
#   D) Patrones de logica por basename (*CommandHandler.cs, *AggregateRoot.cs,
#      *Validator.cs, FunctionEndpoint.cs, *Projection.cs -- MEF-ADR-0034
#      seccion 9 --, *EventHandler.cs -- issue #590), sin gatear por
#      is_projection y sin falso positivo en el plural
#      ConfiguracionMartenProjections{Dominio}.cs (MEF-ADR-0006) ni en el
#      companion de mensajes {Handler}.Mensajes.cs (MEF-ADR-0009)
#   E) Eventos/Entities y ValueObjects con factory Crear() -> logic, antes de
#      llegar a la exclusion de DTOs
#   F) Exclusion de records DTO del estilo canonico (MEF-ADR-0035 seccion 2):
#      modificadores entre 'public' y 'record' (sealed/partial), forma
#      multilinea, sin depender del conteo de lineas, sin excluir un record
#      CON metodos ni un DTO que convive con una clase con metodos
#   G) not_evaluated por defecto cuando nada matchea
#   H) Layout de ensamblados de eventos por rol (MEF-ADR-0039, issue #553):
#      evento con Crear() en la raiz de un proyecto *.DomainEvents -> logic, y
#      lo mismo en una subcarpeta suya (las dos alternativas del patron de
#      ruta); sin Crear() ahi mismo -> not_evaluated; record plano de bus con
#      marker en PublicEvents/PrivateEvents -> excluded (no-regresion de la
#      regla DTO de F, sin cambio de codigo); IdentidadEventos*.cs -> excluded
#   I) Patrones del servidor MCP (issue #788, MEF-ADR-0047/MEF-ADR-0048):
#      *Tool.cs -> logic; *Api.cs bajo Infraestructura/ -> excluded tanto con
#      Infraestructura como segmento hoja (el layout de mcp-scaffolder) como
#      con subcarpeta, *Api.cs fuera de Infraestructura/ -> not_evaluated;
#      archivo con N records DTO puros (contrato upstream redeclarado,
#      MEF-ADR-0047 decision 3) -> excluded, relajando la cota "un solo tipo"
#      del Escenario F a "todos los tipos son records puros"
#
# Uso: scripts/tests/test-coverage-gate-classify-file.sh
# Exit code: 0 si todos los escenarios pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/_pipeline-common.sh"

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

write_fixture() {
    local relpath="$1" content="$2"
    local full="$TMP_DIR/$relpath"
    mkdir -p "$(dirname "$full")"
    printf '%s' "$content" > "$full"
}

# ─── Escenario A: exclusion por nombre de archivo (boilerplate/wiring) ──────
echo "Escenario A: exclusion por nombre de archivo"
write_fixture "src/Foo.Bar/HealthCheck.cs" 'namespace Foo.Bar;

public sealed class HealthCheck { }
'
assert_eq "A1: HealthCheck.cs -> excluded" "excluded" \
    "$(coverage_classify_file "src/Foo.Bar/HealthCheck.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Bar/Program.cs" 'var host = new HostBuilder().Build();
host.Run();
'
assert_eq "A2: Program.cs -> excluded" "excluded" \
    "$(coverage_classify_file "src/Foo.Bar/Program.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Bar/TurnoMensajes.cs" 'namespace Foo.Bar;

internal static class TurnoMensajes { }
'
assert_eq "A3: *Mensajes.cs -> excluded" "excluded" \
    "$(coverage_classify_file "src/Foo.Bar/TurnoMensajes.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Bar/FooAssemblyMarker.cs" 'namespace Foo.Bar;

public sealed class FooAssemblyMarker { }
'
assert_eq "A4: *AssemblyMarker.cs -> excluded" "excluded" \
    "$(coverage_classify_file "src/Foo.Bar/FooAssemblyMarker.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Bar/ConfiguracionSerializacionEventos.cs" 'namespace Foo.Bar;

public static class ConfiguracionSerializacionEventos { }
'
assert_eq "A5: ConfiguracionSerializacion*.cs -> excluded" "excluded" \
    "$(coverage_classify_file "src/Foo.Bar/ConfiguracionSerializacionEventos.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Bar/Mensajes.resx" ''
assert_eq "A6: *.resx -> excluded" "excluded" \
    "$(coverage_classify_file "src/Foo.Bar/Mensajes.resx" "$TMP_DIR" false)"

# ─── Escenario B: exclusion por directorio de infraestructura ──────────────
echo "Escenario B: exclusion por directorio de infraestructura (wiring puro)"
# Hallazgo preexistente, fuera de alcance (mismo mecanismo que el de
# '/Eventos/\|/Entities/' documentado en el Escenario E): 'grep -q
# /Infraestructura/' exige un '/' DESPUES de 'Infraestructura' en $dirname, y
# dirname nunca trae slash de cierre -- asi que solo dispara cuando
# Infraestructura es un segmento NO-hoja de la ruta (un subdirectorio debajo).
# B1/B2 usan ese segmento extra para ejercitar la exclusion tal cual existe
# hoy; B3 documenta que RequestValidator.cs colocado directamente en
# Infraestructura/ (sin subcarpeta, la forma "obvia") NO dispara esta regla.
write_fixture "src/Foo.Bar/Infraestructura/Validacion/RequestValidator.cs" 'namespace Foo.Bar.Infraestructura.Validacion;

internal sealed class RequestValidator { }
'
assert_eq "B1: Infraestructura/{subcarpeta}/RequestValidator.cs -> excluded" "excluded" \
    "$(coverage_classify_file "src/Foo.Bar/Infraestructura/Validacion/RequestValidator.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Bar/Infraestructura/Validacion/ServiceBusDeserializador.cs" 'namespace Foo.Bar.Infraestructura.Validacion;

internal sealed class ServiceBusDeserializador { }
'
assert_eq "B2: Infraestructura/{subcarpeta}/ServiceBusDeserializador.cs -> excluded" "excluded" \
    "$(coverage_classify_file "src/Foo.Bar/Infraestructura/Validacion/ServiceBusDeserializador.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Bar/Infraestructura/RequestValidator.cs" 'namespace Foo.Bar.Infraestructura;

internal sealed class RequestValidator { }
'
assert_eq "B3: RequestValidator.cs directo en Infraestructura/ (hoja, sin subcarpeta) -> logic, no excluded" "logic" \
    "$(coverage_classify_file "src/Foo.Bar/Infraestructura/RequestValidator.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Bar/RequestValidator.cs" 'namespace Foo.Bar;

internal sealed class RequestValidator { }
'
# RequestValidator.cs FUERA de Infraestructura/ no entra a la exclusion de
# wiring, pero SI matchea el patron general *Validator.cs (Escenario D) -- el
# nombre de archivo por si solo no basta para excluir, solo su ubicacion.
assert_eq "B4: RequestValidator.cs FUERA de Infraestructura/ -> logic (matchea *Validator.cs)" "logic" \
    "$(coverage_classify_file "src/Foo.Bar/RequestValidator.cs" "$TMP_DIR" false)"

# ─── Escenario C: carve-out de coverage del endpoint GET delgado ───────────
echo "Escenario C: FunctionEndpoint.cs de query GET se excluye solo bajo is_projection=true"
write_fixture "src/Foo.Bar/ObtenerTurno/FunctionEndpoint.cs" 'namespace Foo.Bar.ObtenerTurno;

public sealed class FunctionEndpoint { }
'
assert_eq "C1: Obtener{X} bajo is_projection=true -> excluded" "excluded" \
    "$(coverage_classify_file "src/Foo.Bar/ObtenerTurno/FunctionEndpoint.cs" "$TMP_DIR" true)"
assert_eq "C2: el mismo Obtener{X} con is_projection=false sigue siendo logic" "logic" \
    "$(coverage_classify_file "src/Foo.Bar/ObtenerTurno/FunctionEndpoint.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Bar/ListarTurnos/FunctionEndpoint.cs" 'namespace Foo.Bar.ListarTurnos;

public sealed class FunctionEndpoint { }
'
assert_eq "C3: Listar{X}s bajo is_projection=true -> excluded" "excluded" \
    "$(coverage_classify_file "src/Foo.Bar/ListarTurnos/FunctionEndpoint.cs" "$TMP_DIR" true)"

write_fixture "src/Foo.Bar/CrearTurnoFunction/FunctionEndpoint.cs" 'namespace Foo.Bar.CrearTurnoFunction;

public sealed class FunctionEndpoint { }
'
assert_eq "C4: carpeta con sufijo Function (comando) no entra al carve-out ni bajo is_projection=true" "logic" \
    "$(coverage_classify_file "src/Foo.Bar/CrearTurnoFunction/FunctionEndpoint.cs" "$TMP_DIR" true)"

# ─── Escenario D: patrones de logica por basename (CA-1, MEF-ADR-0034 seccion 9) ─
echo "Escenario D: patrones de logica por basename"
write_fixture "src/Foo.Bar/CrearTurnoCommandHandler.cs" 'namespace Foo.Bar;

public sealed class CrearTurnoCommandHandler { }
'
assert_eq "D1: *CommandHandler.cs -> logic" "logic" \
    "$(coverage_classify_file "src/Foo.Bar/CrearTurnoCommandHandler.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Bar/TurnoAggregateRoot.cs" 'namespace Foo.Bar;

public sealed class TurnoAggregateRoot { }
'
assert_eq "D2: *AggregateRoot.cs -> logic" "logic" \
    "$(coverage_classify_file "src/Foo.Bar/TurnoAggregateRoot.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Bar/CrearTurnoValidator.cs" 'namespace Foo.Bar;

public sealed class CrearTurnoValidator { }
'
assert_eq "D3: *Validator.cs -> logic" "logic" \
    "$(coverage_classify_file "src/Foo.Bar/CrearTurnoValidator.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Bar/TurnoProjection.cs" 'namespace Foo.Bar;

public sealed partial class TurnoProjection : SingleStreamProjection<TurnoView, Guid>
{
    public static TurnoView Create(TurnoCreado e) => new(e.Id, "Abierto");
}
'
assert_eq "D4: *Projection.cs -> logic con is_projection=true" "logic" \
    "$(coverage_classify_file "src/Foo.Bar/TurnoProjection.cs" "$TMP_DIR" true)"
assert_eq "D5: *Projection.cs -> logic con is_projection=false (no gateado)" "logic" \
    "$(coverage_classify_file "src/Foo.Bar/TurnoProjection.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Bar/ConfiguracionMartenProjections.cs" 'namespace Foo.Bar;

public static class ConfiguracionMartenProjections { }
'
assert_eq "D6: ConfiguracionMartenProjections.cs (plural) no entra al patron singular" "not_evaluated" \
    "$(coverage_classify_file "src/Foo.Bar/ConfiguracionMartenProjections.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Bar/ConfiguracionMartenProjectionsVentas.cs" 'namespace Foo.Bar;

public static class ConfiguracionMartenProjectionsVentas { }
'
assert_eq "D7: ConfiguracionMartenProjections{Dominio}.cs (plural+sufijo) tampoco" "not_evaluated" \
    "$(coverage_classify_file "src/Foo.Bar/ConfiguracionMartenProjectionsVentas.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Bar/TurnoCreadoEventHandler.cs" 'namespace Foo.Bar;

public partial class TurnoCreadoEventHandler(IEventStore eventStore)
    : IPrivateEventHandlerAsync<TurnoCreado>
{
}
'
assert_eq "D8: *EventHandler.cs -> logic (issue #590)" "logic" \
    "$(coverage_classify_file "src/Foo.Bar/TurnoCreadoEventHandler.cs" "$TMP_DIR" false)"

# El patron esta anclado al final del basename: el companion de mensajes que
# acompana al handler ({Clase}.Mensajes.cs, MEF-ADR-0009) sigue siendo la
# exclusion de boilerplate del Escenario A, no logica. Guarda contra ampliar el
# glob a *EventHandler*.cs, que arrastraria ese .resx-companion al 95%.
write_fixture "src/Foo.Bar/TurnoCreadoEventHandler.Mensajes.cs" 'namespace Foo.Bar;

public partial class TurnoCreadoEventHandler
{
    public static class Mensajes { }
}
'
assert_eq "D9: {EventHandler}.Mensajes.cs sigue excluido (patron anclado al final)" "excluded" \
    "$(coverage_classify_file "src/Foo.Bar/TurnoCreadoEventHandler.Mensajes.cs" "$TMP_DIR" false)"

# ─── Escenario E: eventos/ValueObjects con factory Crear() -> logic ────────
echo "Escenario E: evento/ValueObject con factory Crear() resuelve logic antes de la exclusion de DTOs"
# Nota (hallazgo fuera de alcance, no corregido aqui): el check
# '/Eventos/\|/Entities/' matchea sobre dirname con slash de cierre, asi que
# solo dispara cuando esos nombres son un segmento NO-hoja de la ruta -- nunca
# en la convencion documentada '{Dominio}/{Feature}/Eventos/{Evento}.cs'
# (agents/test-writer.md:770), donde Eventos es la carpeta hoja. Preexistente
# e intacto por este movimiento; el fixture usa un segmento extra para
# ejercitar el mecanismo tal cual existe hoy.
write_fixture "src/Foo.Bar/Feature/Eventos/V1/TurnoCreado.cs" 'namespace Foo.Bar.Feature.Eventos;

public sealed record TurnoCreado(Guid Id)
{
    public static TurnoCreado Crear(Guid id) => new(id);
}
'
assert_eq "E1: evento con Crear() -> logic (no cae en la exclusion de DTOs)" "logic" \
    "$(coverage_classify_file "src/Foo.Bar/Feature/Eventos/V1/TurnoCreado.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Bar/Feature/Entities/V1/Codigo.cs" 'namespace Foo.Bar.Feature.Entities;

public sealed record Codigo(string Valor)
{
    public static Codigo Crear(string valor) => new(valor);
}
'
assert_eq "E2: Entity con Crear() -> logic (no cae en la exclusion de DTOs)" "logic" \
    "$(coverage_classify_file "src/Foo.Bar/Feature/Entities/V1/Codigo.cs" "$TMP_DIR" false)"

# Mismo hallazgo fuera de alcance que arriba, tambien preexistente para
# '/ValueObjects/' (convencion real: 'Contracts/ValueObjects/{VO}.cs', hoja).
write_fixture "src/Foo.Bar/Contracts/ValueObjects/V1/Codigo.cs" 'namespace Foo.Bar.Contracts.ValueObjects;

public sealed record Codigo(string Valor)
{
    public static Codigo Crear(string valor) => new(valor);
}
'
assert_eq "E3: ValueObject con Crear() -> logic (no cae en la exclusion de DTOs)" "logic" \
    "$(coverage_classify_file "src/Foo.Bar/Contracts/ValueObjects/V1/Codigo.cs" "$TMP_DIR" false)"

# ─── Escenario F: exclusion de records DTO del estilo canonico ─────────────
echo "Escenario F: records DTO del estilo canonico -> excluded; con metodos -> no excluido; una linea no regresiona"
write_fixture "src/Foo.ReadModels/TurnoView.cs" 'namespace Foo.ReadModels;

public sealed record TurnoView(
    Guid Id, string Estado, DateOnly FechaInicio);
'
assert_eq "F1: public sealed record multilinea -> excluded" "excluded" \
    "$(coverage_classify_file "src/Foo.ReadModels/TurnoView.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.ReadModels/PlanoView.cs" 'namespace Foo.ReadModels;

public record PlanoView(Guid Id, string Nombre);
'
assert_eq "F2: public record de una linea -> excluded (no regresiona)" "excluded" \
    "$(coverage_classify_file "src/Foo.ReadModels/PlanoView.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.ReadModels/ResumenView.cs" 'namespace Foo.ReadModels;

public sealed record ResumenView(Guid Id, string Estado)
{
    public bool EsActivo() => Estado == "Abierto";
}
'
assert_eq "F3: record CON metodos no se excluye por esta regla" "not_evaluated" \
    "$(coverage_classify_file "src/Foo.ReadModels/ResumenView.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.ReadModels/OtraView.cs" 'namespace Foo.ReadModels;

public sealed partial record OtraView(Guid Id);
'
assert_eq "F4: modificadores sealed+partial combinados -> excluded" "excluded" \
    "$(coverage_classify_file "src/Foo.ReadModels/OtraView.cs" "$TMP_DIR" false)"

# La cota de "un unico tipo declarado" evita que el primer match de la busqueda
# excluya un archivo que declara un DTO junto a -- o dentro de -- una clase con
# metodos: se etiquetaria "excluido" (deliberado) cuando en realidad nadie lo
# midio ("sin clasificar"), escondiendolo de la revision humana.
write_fixture "src/Foo.Bar/AyudanteConDto.cs" 'namespace Foo.Bar;

public sealed record DatosAuxiliares(Guid Id);

public static class AyudanteConDto
{
    public static bool EsValido(DatosAuxiliares d) => d.Id != Guid.Empty;
}
'
assert_eq "F5: DTO junto a una clase con metodos no se excluye" "not_evaluated" \
    "$(coverage_classify_file "src/Foo.Bar/AyudanteConDto.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Bar/ClaseConRecordAnidado.cs" 'namespace Foo.Bar;

public sealed class ClaseConRecordAnidado
{
    public sealed record Anidado(Guid Id);

    public bool EsValido(Anidado a) => a.Id != Guid.Empty;
}
'
assert_eq "F6: record anidado dentro de una clase con metodos no se excluye" "not_evaluated" \
    "$(coverage_classify_file "src/Foo.Bar/ClaseConRecordAnidado.cs" "$TMP_DIR" false)"

# Varios DTOs sin cuerpo en el mismo archivo (dos records de contrato): desde
# el issue #788 la cota ya no es "un solo tipo declarado" sino "todos los
# tipos declarados son records puros" -- ver Escenario I para el caso real
# (contrato upstream redeclarado con MEF-ADR-0047 decision 3).
write_fixture "src/Foo.ReadModels/DosViews.cs" 'namespace Foo.ReadModels;

public sealed record UnaView(Guid Id);
public sealed record OtraMasView(Guid Id);
'
assert_eq "F7: dos records puros en el mismo archivo -> excluded (cota relajada, issue #788)" "excluded" \
    "$(coverage_classify_file "src/Foo.ReadModels/DosViews.cs" "$TMP_DIR" false)"

# Forma realista del read model canonico (skills/projections/modelos-marten.md):
# doc comment, coleccion generica, tipo enum y parametro nullable. Ninguna de
# esas formas debe enganar a la cota de "un unico tipo declarado".
write_fixture "src/Foo.ReadModels/DetalleView.cs" 'using System;
using System.Collections.Generic;

namespace Foo.ReadModels;

/// Read model canonico con coleccion, enum y nullable.
public sealed record DetalleView(
    Guid Id,
    EstadoTurno Estado,
    IReadOnlyList<string> Etiquetas,
    DateOnly? FechaCierre);
'
assert_eq "F8: read model canonico con coleccion/enum/nullable -> excluded" "excluded" \
    "$(coverage_classify_file "src/Foo.ReadModels/DetalleView.cs" "$TMP_DIR" false)"

# ─── Escenario G: not_evaluated por defecto ─────────────────────────────────
echo "Escenario G: nada matchea -> not_evaluated"
write_fixture "src/Foo.Bar/Ayudante.cs" 'namespace Foo.Bar;

public static class Ayudante
{
    public static bool EsValido(Guid id) => id != Guid.Empty;
}
'
assert_eq "G1: clase auxiliar sin ningun patron -> not_evaluated" "not_evaluated" \
    "$(coverage_classify_file "src/Foo.Bar/Ayudante.cs" "$TMP_DIR" false)"

assert_eq "G2: archivo inexistente en el worktree -> not_evaluated (no aborta)" "not_evaluated" \
    "$(coverage_classify_file "src/Foo.Bar/NoExiste.cs" "$TMP_DIR" false)"

# ─── Escenario H: layout de ensamblados de eventos por rol (MEF-ADR-0039) ──
echo "Escenario H: layout de ensamblados de eventos por rol (issue #553)"
write_fixture "src/Foo.Bar.Ventas.DomainEvents/VentaCreada.cs" 'namespace Foo.Bar.Ventas.DomainEvents;

public sealed record VentaCreada(Guid Id)
{
    public static VentaCreada Crear(Guid id) => new(id);
}
'
assert_eq "H1: evento con Crear() en raiz de *.DomainEvents/ -> logic" "logic" \
    "$(coverage_classify_file "src/Foo.Bar.Ventas.DomainEvents/VentaCreada.cs" "$TMP_DIR" false)"

# La otra alternativa del patron de ruta: el proyecto no exige subcarpeta
# (MEF-ADR-0039 decision 1), pero tampoco la prohibe -- un evento en una
# subcarpeta de *.DomainEvents/ debe clasificar igual que en la raiz. H1 cubre
# '\.DomainEvents$' (raiz) y H2 cubre '\.DomainEvents/' (segmento no-hoja).
write_fixture "src/Foo.Bar.Ventas.DomainEvents/V2/VentaCreada.cs" 'namespace Foo.Bar.Ventas.DomainEvents.V2;

public sealed record VentaCreada(Guid Id, string Motivo)
{
    public static VentaCreada Crear(Guid id, string motivo) => new(id, motivo);
}
'
assert_eq "H2: evento con Crear() en subcarpeta de *.DomainEvents/ -> logic" "logic" \
    "$(coverage_classify_file "src/Foo.Bar.Ventas.DomainEvents/V2/VentaCreada.cs" "$TMP_DIR" false)"

# El fixture lleva un metodo de instancia a proposito: lo que se verifica es que
# la rama de *.DomainEvents exige la factory (no clasifica logic por ubicacion
# sola). Un record plano sin cuerpo caeria antes en la exclusion de DTOs de F
# (-> excluded, como H4), y entonces el fixture no probaria nada de esta rama.
write_fixture "src/Foo.Bar.Ventas.DomainEvents/VentaCancelada.cs" 'namespace Foo.Bar.Ventas.DomainEvents;

public sealed record VentaCancelada(Guid Id)
{
    public bool EsValida() => Id != Guid.Empty;
}
'
assert_eq "H3: evento sin Crear() en raiz de *.DomainEvents/ -> not_evaluated" "not_evaluated" \
    "$(coverage_classify_file "src/Foo.Bar.Ventas.DomainEvents/VentaCancelada.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Bar.PublicEvents/Ventas/VentaPublicada.cs" 'namespace Foo.Bar.PublicEvents.Ventas;

public sealed record VentaPublicada(Guid Id) : IPublicEvent;
'
assert_eq "H4: record plano de bus con marker en PublicEvents/ -> excluded (regla DTO de F, sin cambio de codigo)" "excluded" \
    "$(coverage_classify_file "src/Foo.Bar.PublicEvents/Ventas/VentaPublicada.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Bar.Ventas.DomainEvents/IdentidadEventosVentas.cs" 'namespace Foo.Bar.Ventas.DomainEvents;

public static class IdentidadEventosVentas { }
'
assert_eq "H5: IdentidadEventosVentas.cs -> excluded" "excluded" \
    "$(coverage_classify_file "src/Foo.Bar.Ventas.DomainEvents/IdentidadEventosVentas.cs" "$TMP_DIR" false)"

# ─── Escenario I: patrones del servidor MCP (issue #788) ───────────────────
echo "Escenario I: patrones del servidor MCP (MEF-ADR-0047/MEF-ADR-0048)"
write_fixture "src/Foo.Mcp.Colaboradores/ListarColaboradoresTool.cs" 'namespace Foo.Mcp.Colaboradores;

public sealed class ListarColaboradoresTool { }
'
assert_eq "I1: *Tool.cs -> logic" "logic" \
    "$(coverage_classify_file "src/Foo.Mcp.Colaboradores/ListarColaboradoresTool.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Mcp.Colaboradores/Infraestructura/ColaboradoresApi.cs" 'namespace Foo.Mcp.Colaboradores.Infraestructura;

internal sealed class ColaboradoresApi { }
'
assert_eq "I2: Infraestructura/{X}Api.cs (leaf, sin subcarpeta) -> excluded" "excluded" \
    "$(coverage_classify_file "src/Foo.Mcp.Colaboradores/Infraestructura/ColaboradoresApi.cs" "$TMP_DIR" false)"

# El mismo cliente bajo una subcarpeta de Infraestructura/: el check nuevo
# ancla "Infraestructura" como segmento completo de ruta, hoja o no, a
# diferencia del de RequestValidator.cs/ServiceBusDeserializador.cs (B1-B3).
write_fixture "src/Foo.Mcp.Colaboradores/Infraestructura/Clientes/NominaApi.cs" 'namespace Foo.Mcp.Colaboradores.Infraestructura.Clientes;

internal sealed class NominaApi { }
'
assert_eq "I2b: Infraestructura/{subcarpeta}/{X}Api.cs -> excluded" "excluded" \
    "$(coverage_classify_file "src/Foo.Mcp.Colaboradores/Infraestructura/Clientes/NominaApi.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Mcp.Colaboradores/ColaboradoresApi.cs" 'namespace Foo.Mcp.Colaboradores;

internal sealed class ColaboradoresApi { }
'
assert_eq "I3: *Api.cs fuera de Infraestructura/ -> not_evaluated" "not_evaluated" \
    "$(coverage_classify_file "src/Foo.Mcp.Colaboradores/ColaboradoresApi.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Mcp.Colaboradores/Infraestructura/FichaColaborador.cs" 'namespace Foo.Mcp.Colaboradores.Infraestructura;

public sealed record FichaColaborador(
    Guid Id,
    string Nombre,
    EtiquetaFicha Etiqueta);

public sealed record EtiquetaFicha(
    string Codigo,
    string Descripcion);
'
assert_eq "I4: contrato upstream con N records puros -> excluded (cota relajada)" "excluded" \
    "$(coverage_classify_file "src/Foo.Mcp.Colaboradores/Infraestructura/FichaColaborador.cs" "$TMP_DIR" false)"

write_fixture "src/Foo.Mcp.Colaboradores/Infraestructura/FichaConFiltro.cs" 'namespace Foo.Mcp.Colaboradores.Infraestructura;

public sealed record FichaConFiltro(Guid Id, string Nombre);

public static class FiltroDeFicha
{
    public static bool EsValida(FichaConFiltro f) => f.Id != Guid.Empty;
}
'
assert_eq "I5: record puro junto a una clase con metodos -> not_evaluated (proteccion preservada)" "not_evaluated" \
    "$(coverage_classify_file "src/Foo.Mcp.Colaboradores/Infraestructura/FichaConFiltro.cs" "$TMP_DIR" false)"

echo
echo "─── Resumen ───"
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
