# MEF-ADR-0009: Patron de mensajes con .resx per-aggregate y clase Mensajes anidada

**Estado**: Aceptado  
**Fecha**: 2026-04-04

---

## Contexto

El proyecto requiere:
1. **Internacionalizacion (i18n)** desde el inicio — solo espanol por ahora, traducciones futuras.
2. **Tests desacoplados de strings literales** — los tests deben referenciar una constante, no el texto, para que un cambio de redaccion no rompa tests.
3. **Sin conflictos de merge** — los agentes autonomos (es-test-writer, es-implementer) trabajan en paralelo en verticales distintas. Un archivo de mensajes compartido por dominio o proyecto se convierte en cuello de botella de merge, especialmente porque los .resx son XML y git no entiende su semantica.

El patron previo usaba strings literales inline en los metodos del aggregate y en los tests:
```csharp
// Aggregate
var fallo = new AsignacionFallida(Id, empleadoId, "El empleado ya esta asignado a este turno");

// Test
Then(new AsignacionFallida(..., "El empleado ya esta asignado a este turno"));
```

Esto viola los tres requerimientos anteriores.

---

## Decision

Usamos **un archivo .resx por clase** (por aggregate root o por command handler), co-localizado en la misma carpeta que la clase, con una **clase `Mensajes` anidada** que accede a los recursos via `ResourceManager` directo.

### Estructura de archivos

```
src/Bitakora.ControlAsistencia.{Dominio}/
  Entities/
    TurnoAggregateRoot.cs                  # partial class - logica de dominio
    TurnoAggregateRoot.Mensajes.cs         # partial class - clase Mensajes anidada
    TurnoAggregateRootMensajes.resx        # strings en espanol (default)
  CrearTurno/
    CrearTurnoCommandHandler.cs            # partial class - logica del handler
    CrearTurnoCommandHandler.Mensajes.cs   # partial class - clase Mensajes anidada
    CrearTurnoCommandHandlerMensajes.resx  # strings en espanol
```

### Implementacion de la clase Mensajes

```csharp
// TurnoAggregateRoot.Mensajes.cs
using System.Resources;

namespace Bitakora.ControlAsistencia.Programacion.Entities;

public partial class TurnoAggregateRoot
{
    private static readonly ResourceManager ResourceManager = new(
        "Bitakora.ControlAsistencia.Programacion.Entities.TurnoAggregateRootMensajes",
        typeof(TurnoAggregateRoot).Assembly);

    public static class Mensajes
    {
        public static string EmpleadoYaAsignado => ResourceManager.GetString(nameof(EmpleadoYaAsignado))!;
        public static string TurnoNoActivo => ResourceManager.GetString(nameof(TurnoNoActivo))!;
    }
}
```

El nombre logico del recurso sigue la convencion del SDK de .NET:
`{RootNamespace}.{RelativePath.ConPuntosEnVezDeSlashes}.{NombreResx}`

### Uso en el aggregate

```csharp
public void AsignarEmpleado(Guid empleadoId)
{
    if (EmpleadosAsignados.Contains(empleadoId))
    {
        _uncommittedEvents.Add(new AsignacionEmpleadoFallida(
            Guid.Parse(Id), empleadoId, Mensajes.EmpleadoYaAsignado));
        Apply(...);
        return;
    }
    // ...
}
```

### Uso en tests

```csharp
// Evento de fallo - comparacion exacta con la constante
Then(new AsignacionEmpleadoFallida(GuidAggregateId, EmpleadoId,
    TurnoAggregateRoot.Mensajes.EmpleadoYaAsignado));

// Excepcion del handler - wildcards para absorber variaciones de formato
await act.Should().ThrowExactlyAsync<InvalidOperationException>()
    .WithMessage($"*{CrearTurnoCommandHandler.Mensajes.TurnoYaExiste}*");
```

### Convenciones

- **Aggregate root y command handlers son `partial class`** — requerido para que la clase Mensajes exista en un archivo separado sin romper el tipo.
- **Mensajes de logica de negocio** (eventos de fallo del aggregate) → en la clase Mensajes del aggregate.
- **Mensajes de precondicion** (aggregate no encontrado, ya existe) → en la clase Mensajes del handler.
- **Mensajes de validacion de FluentValidation** → inline en el validator con `.WithMessage(...)` (no aplica el patron .resx porque FluentValidation tiene su propio mecanismo de localizacion).
- **Nomenclatura del .resx**: `{NombreClase}Mensajes.resx`, co-localizado con la clase.

---

## Alternativas consideradas

### Designer.cs generado por IDE (PublicResXFileCodeGenerator)

El patron clasico de .NET para .resx genera una clase `Designer.cs` con propiedades estaticas tipadas. Fue descartado porque el `PublicResXFileCodeGenerator` es un custom tool de Visual Studio/Rider que no se ejecuta con `dotnet build` en CLI. Los agentes autonomos trabajan en CLI, no en IDE. Mantener el Designer.cs a mano neutraliza la ventaja del code generation.

### Archivo de constantes por dominio (sin .resx)

Un archivo `Mensajes.cs` con `public static class Mensajes` y `const string` sin respaldo en .resx. Descartado porque no provee i18n: cambiar el idioma requeriria recompilar. El .resx permite agregar traducciones como satellite assemblies sin tocar el codigo.

### Un .resx por dominio

Un solo archivo `ProgramacionMensajes.resx` para todo el dominio. Descartado: es un punto unico de conflicto de merge cuando multiples agentes trabajan en paralelo en distintas features del mismo dominio. Los .resx son XML y generan conflictos sin semantica git.

---

## Consecuencias

### Positivas

- **Cero conflictos de merge entre agentes paralelos**: cada aggregate/handler tiene su propio .resx. Dos agentes trabajando en features distintas nunca tocan el mismo archivo de mensajes.
- **i18n listo desde el inicio**: agregar una traduccion al ingles solo requiere crear `TurnoAggregateRootMensajes.en.resx`. El `ResourceManager` la selecciona automaticamente por `CultureInfo.CurrentUICulture`. El codigo de produccion no cambia.
- **Tests completamente desacoplados del texto**: cambiar la redaccion de un mensaje solo requiere editar el .resx. Los tests siguen pasando porque referencian la constante, no el literal.
- **Discoverabilidad**: `TurnoAggregateRoot.Mensajes.X` es navegable desde el IDE — el IDE lleva directamente al aggregate y su clase Mensajes.
- **Sin tooling adicional**: el SDK de .NET incluye automaticamente los .resx como EmbeddedResource. No se requiere configuracion adicional en el .csproj.

### Negativas

- **Mas archivos por aggregate**: cada aggregate o handler con mensajes requiere 2 archivos adicionales (.resx + .Mensajes.cs). Es boilerplate predecible, pero boilerplate al fin.
- **La clase Mensajes es boilerplate manual**: cada propiedad en la clase Mensajes duplica el nombre de la clave del .resx. No hay code generation automatico. Un error de typo en el `nameof()` no se detecta en tiempo de compilacion (solo en runtime si el string no existe en el .resx). Los agentes deben ser cuidadosos con la consistencia.
- **`partial class` obligatorio**: todos los aggregates y handlers deben ser `partial class`. Esto es una restriccion menor pero no es el default en los ejemplos del lenguaje.
