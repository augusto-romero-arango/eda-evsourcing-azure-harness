# Ejemplos de limpieza de comentarios

Antes/despues en C# del marco para cada categoria de la tabla de clasificacion de
[SKILL.md](SKILL.md). Los ejemplos que "se conservan" pasan el umbral doble de MEF-ADR-0044
seccion 2 (Context Delta + Decision Delta); los que "se podan" no.

## 1. Narracion del codigo (se poda)

Repite en prosa lo que la linea siguiente ya dice -- sin Context Delta.

```csharp
// Antes
// Incrementa el contador de intentos en uno.
intentos++;

// Marca el turno como cerrado.
estado = EstadoTurno.Cerrado;
```

```csharp
// Despues
intentos++;
estado = EstadoTurno.Cerrado;
```

## 2. Rationale obvio (se poda)

La razon ya es evidente por el nombre del metodo o el tipo -- Decision Delta sin Context Delta.

```csharp
// Antes
// Validamos que el turno exista antes de cerrarlo, porque no tiene sentido
// cerrar algo que no existe.
if (turno is null)
{
    throw new TurnoInexistenteException(turnoId);
}
```

```csharp
// Despues
if (turno is null)
{
    throw new TurnoInexistenteException(turnoId);
}
```

## 3. Heading estructural (se poda)

Divide el archivo en secciones sin aportar informacion que el propio nombre del metodo/clase
que sigue no aporte ya.

```csharp
// Antes
// ==================== Comandos ====================

public async Task<IActionResult> CerrarTurno(...)
{
    ...
}

// ==================== Queries ====================

public async Task<IActionResult> ObtenerTurno(...)
{
    ...
}
```

```csharp
// Despues
public async Task<IActionResult> CerrarTurno(...)
{
    ...
}

public async Task<IActionResult> ObtenerTurno(...)
{
    ...
}
```

## 4. Provenance: `// HU-XX` (se poda)

Proscrito explicitamente por MEF-ADR-0044 seccion 3: ningun script, gate ni agente lo consume
para correlacionar el test con su historia de usuario. Esa informacion pertenece al commit/PR,
no al archivo.

```csharp
// Antes
// HU-42
[Fact]
public async Task CerrarTurno_DebeEmitirTurnoCerrado_CuandoElTurnoEstaAbierto()
{
    ...
}
```

```csharp
// Despues
[Fact]
public async Task CerrarTurno_DebeEmitirTurnoCerrado_CuandoElTurnoEstaAbierto()
{
    ...
}
```

## 5. Cita de ADR sola, sin restriccion (se poda)

MEF-ADR-0044 seccion 4: una cita a ADR sin la restriccion que documenta es provenance
disfrazada -- indica de donde vino la decision, no que decision rige el codigo presente.

```csharp
// Antes
// MEF-ADR-0028
public class TenantResolverHibrido : ITenantResolver
{
    ...
}
```

```csharp
// Despues
public class TenantResolverHibrido : ITenantResolver
{
    ...
}
```

Contraste con el caso que **si** se conserva: la misma cita, junto a la restriccion que
documenta (ver seccion 9 mas abajo).

## 6. Doc redundante de API o de lenguaje (se poda)

Explica sintaxis del lenguaje o un metodo bien documentado de una libreria de terceros --
esa informacion vive en la documentacion oficial, no en el codigo del consumidor
(MEF-ADR-0044 seccion 3).

```csharp
// Antes
// Iteramos sobre cada evento del stream.
foreach (var evento in eventos)
{
    Apply(evento);
}
```

```csharp
// Despues
foreach (var evento in eventos)
{
    Apply(evento);
}
```

## 7. Restriccion no obvia (se conserva)

Pasa el umbral doble: la informacion no es inferible del codigo, y perderla podria hacer que
una edicion futura sea plausible pero incorrecta. Ejemplo real de MEF-ADR-0029 (limite de
`ValidateOnBuild`), texto identico al que emite `domain-scaffolder`:

```csharp
// Limite conocido (MEF-ADR-0029): ValidateOnBuild NO valida open generics ni el interior de
// registros por factory-lambda (AddScoped(sp => ...)), de los que Wolverine/Marten registran
// muchos -- cubre los registros por tipo mapeado (los routers de abajo). Por eso los tres
// routers se resuelven explicitamente: es el complemento que ejercita tambien lo que
// ValidateOnBuild no puede validar de forma estatica.
public class ComposicionContenedorTests
{
    ...
}
```

No se toca: sin este comentario, un agente futuro podria asumir que `ValidateOnBuild` ya cubre
todo el grafo de DI y eliminar la resolucion explicita de los tres routers como "redundante" --
exactamente el cambio plausible pero incorrecto que el test operativo de la seccion 2 detecta.

## 8. Workaround externo (se conserva)

Documenta un rodeo forzado por el comportamiento de una libreria externa, no evidente sin leer
su codigo fuente. Ejemplo real de `agents/domain-scaffolder.md` (patron de wildcard de
`OpenTelemetry`, issue #460) -- es ademas el **"comentario gemelo"** que MEF-ADR-0034 seccion 10
mandata junto al `AddSource` de la fuente propia, tanto en `domain-scaffolder` como en
`projections-scaffolder`: segundo de los tres casos que la excepcion de MEF-ADR-0044 seccion 4
blinda.

```csharp
// El "*" va SIN punto delante: OpenTelemetry ancla el patron escapado, asi que "X.*" queda como
// ^X\..*$ y EXCLUYE la fuente nombrada exactamente "X" -- el nombre idiomatico al instrumentar.
// El modo de falla es silencioso: sin error ni warning, los spans de esa fuente nunca llegan a
// Application Insights. Verificado contra OpenTelemetry 1.13.1 por inspeccion de
// src/OpenTelemetry/Internal/WildcardHelper.cs. NO agregar el punto por simetria con los
// AddSource de arriba.
tracing.AddSource("MiDominio*")
```

No se toca: la restriccion (no agregar el punto) contradice la simetria visual que un agente
podria "corregir" sin este comentario, y el costo del error es silencioso -- nunca aparece como
excepcion ni advertencia.

## 9. Guardrail con restriccion activa, estilo `projections-scaffolder` (se conserva)

Caso blindado explicitamente por la excepcion de MEF-ADR-0044 seccion 4: un guardrail
deliberado de un scaffolder que documenta una restriccion de compilacion no inferible sin
decompilar el SDK. Texto identico al que emite `agents/projections-scaffolder.md`:

```csharp
using Microsoft.Extensions.DependencyInjection;
// 'using OpenTelemetry;' NO es opcional ni redundante con los dos de abajo: ConfigureResource y
// WithTracing son extension methods de OpenTelemetryBuilderSdkExtensions, que vive en el namespace
// raiz OpenTelemetry (no en OpenTelemetry.Trace). Sin esta linea, ambas llamadas fallan con CS1061.
using OpenTelemetry;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
```

No se toca, aunque a primera vista `using OpenTelemetry;` parezca redundante frente a
`OpenTelemetry.Resources`/`OpenTelemetry.Trace` que le siguen: el comentario documenta
exactamente por que no lo es, y borrarlo (o borrar el `using`) rompe la compilacion con
`CS1061` -- el `comment-cleanup` que lo podara por "narracion de using" estaria destruyendo
doctrina mandatada, no ruido (MEF-ADR-0044 seccion 4, excepcion).
