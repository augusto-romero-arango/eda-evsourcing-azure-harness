# MEF-ADR-0028: Estrategia de tenancy — mono-tenant transitorio en greenfield y resolver real basado en TenantContext

- **Fecha**: 2026-07-19
- **Estado**: aceptado
- **Aplica a**: doctrina de tenancy del marco; gobierna al `domain-scaffolder` (registro del `ITenantResolver` en el `Program.cs` que genera) y, en trabajo diferido, a `onboard`/`scaffold` (deteccion de la etapa vigente). Cross-referencia MEF-ADR-0003 (stack ES Marten+Wolverine), MEF-ADR-0021 (infraestructura base) y MEF-ADR-0023 (Bounded Context/topologia de ASB).

## Contexto

Un dominio scaffoldeado con los building blocks `Cosmos.Event*` actuales nace roto si su `Program.cs`
no registra un `ITenantResolver`: en el consumidor Bitakora.ControlAsistencia, el upgrade de
`Cosmos.EventSourcing.CritterStack` `0.1.9 -> 2.1.0` dejo de auto-registrarlo y **toda** activacion de
funcion fallo con `InvalidOperationException: Unable to resolve service for type
'Cosmos.MultiTenancy.ITenantResolver'` -> HTTP 500, detectado solo post-deploy por smoke tests (refs
consumidor: #207 upgrade, #219 fix).

Verificado decompilando (`ilspycmd`) los ensamblados vigentes de los paquetes `Cosmos.MultiTenancy*`
2.1.0 (paquetes privados del marco, sin documentacion publica -- la unica fuente verificable es el
propio ensamblado):

- **`Cosmos.MultiTenancy`** (namespace `Cosmos.MultiTenancy`) define el contrato, sin implementacion:

  ```csharp
  public interface ITenantResolver
  {
      string TenantId { get; }
      string UserId { get; }
  }
  ```

- **`Cosmos.MultiTenancy.AspNetCore`** aporta `TrustedHeadersTenantResolver` (lee `X-Tenant-Id`/
  `X-User-Id` de `IHttpContextAccessor`, lanza `InvalidOperationException` si el header falta) y la
  extension `AgregarTenantResolverConHeadersConfiables()` que registra
  `services.AddScoped<ITenantResolver, TrustedHeadersTenantResolver>()`.
- **`Cosmos.MultiTenancy.CritterStack`** aporta `ProxyTenantResolver` (delega en
  `WolverineMessageContextTenantResolver` cuando corre dentro de un handler de Wolverine sin
  `HttpContext`, o en `TrustedHeadersTenantResolver` cuando si lo hay -- el hibrido HTTP + daemon de
  Wolverine) y la extension `AgregarTenantResolverHibrido()` que registra
  `services.AddScoped<ITenantResolver, ProxyTenantResolver>()`. **Ambos exigen que el header o el
  `IMessageContext.TenantId` esten presentes**: si faltan, lanzan `InvalidOperationException` en vez
  de degradar a un default.

`Cosmos.EventSourcing.CritterStack` 2.1.0 depende transitivamente de `Cosmos.MultiTenancy` 2.1.0 (su
`.nuspec` declara `<dependency id="Cosmos.MultiTenancy" version="2.1.0" .../>`), asi que el contrato
`ITenantResolver` ya esta disponible en el `.csproj` que genera `domain-scaffolder` sin agregar
ninguna referencia nueva -- lo que falta es **registrar una implementacion**.

Un proyecto recien scaffoldeado (greenfield) todavia no tiene autenticacion instalada: no existe
ningun `HttpContext` con headers confiables ni ningun `IMessageContext` con `TenantId` propagado. Si
el scaffold registrara `AgregarTenantResolverHibrido()` (o `AgregarTenantResolverConHeadersConfiables()`)
por defecto, la primera invocacion sin esos headers lanzaria la misma `InvalidOperationException` que
motivo este ADR -- solo que ahora por diseno, no por omision. El marco necesita una tercera opcion,
distinta de las dos que ya proveen los paquetes `Cosmos.MultiTenancy.*`: un resolver de **valores
fijos** que nunca lanza, para el escenario greenfield sin autenticacion.

## Decision

### 1. Modelo de dos etapas

El `ITenantResolver` de un dominio del marco vive en una de dos etapas, nunca en ambas a la vez:

- **(a) Mono-tenant transitorio (greenfield, sin autenticacion instalada)**: un resolver propio del
  dominio, de valores fijos, que implementa `Cosmos.MultiTenancy.ITenantResolver` sin depender de
  `HttpContext` ni de `IMessageContext`. Es el que fija este ADR y el que genera `domain-scaffolder`
  por defecto.
- **(b) Resolver real basado en `TenantContext` de autenticacion**: cuando el proyecto instala una
  autenticacion que produce un `TenantContext` (tipicamente header-based via
  `Cosmos.MultiTenancy.AspNetCore.AgregarTenantResolverConHeadersConfiables()`, o el hibrido
  HTTP+daemon de `Cosmos.MultiTenancy.CritterStack.AgregarTenantResolverHibrido()` cuando el dominio
  tambien resuelve tenant dentro de handlers de Wolverine sin `HttpContext`), se registra ese resolver
  real en su lugar.

**La etapa (a) es transitoria, no un estado permanente ni "el escenario de siempre".** Un dominio pasa
de (a) a (b) en el momento en que instala autenticacion fuerte que genera un `TenantContext`; a partir
de ahi, dejar el default mono-tenant seria incorrecto (todo tenant colapsaria a `*DEFAULT*` pese a que
la autenticacion ya sabe distinguir tenants reales).

### 2. Forma del resolver mono-tenant transitorio (etapa a)

```csharp
namespace <RootNamespace>.{PascalCase}.Infraestructura;

public class TenantResolverMonoTenantPorDefecto : ITenantResolver
{
    public string TenantId => JasperFx.StorageConstants.DefaultTenantId;
    public string UserId => "usuario-no-autenticado";
}
```

- **`TenantId`**: se fija a `JasperFx.StorageConstants.DefaultTenantId`, la constante que el propio
  Marten usa cuando ninguna tenencia explicita se especifica -- "If no explicit tenancy is specified,
  either via policies, mappings, scoped sessions or overloads, Marten will default to
  `StorageConstants.DefaultTenantId` with a constant value of `*DEFAULT*`" [1]. `JasperFx` (paquete
  publico, `DefaultTenantId = "*DEFAULT*"` verificado decompilando `JasperFx.dll` 2.18.1 [2]) ya es
  dependencia transitiva del scaffold via `Marten` 9.12.0 <- `Cosmos.EventSourcing.CritterStack`
  2.1.0: no agrega ninguna referencia nueva al `.csproj`. Usar el mismo default de Marten evita
  introducir un segundo tenant id inventado que solo confundiria en el event store.
- **`UserId`**: se fija al valor descriptivo `"usuario-no-autenticado"` -- no una persona real, sino
  una marca explicita en la metadata de eventos de que el evento se origino sin autenticacion. Encaja
  con que en greenfield, por definicion, aun no hay usuario autenticado que resolver.
- **Registro** (`Program.cs`, MEF-ADR-0021): `builder.Services.AddScoped<ITenantResolver,
  TenantResolverMonoTenantPorDefecto>();`, mismo lifetime (`Scoped`) que usan
  `AgregarTenantResolverConHeadersConfiables()`/`AgregarTenantResolverHibrido()` para su propia
  implementacion -- consistente con el resto del contrato `ITenantResolver`, sin fijar un lifetime
  distinto para el caso transitorio.
- El resolver **no** usa `AgregarTenantResolverHibrido()` ni `ProxyTenantResolver`/
  `TrustedHeadersTenantResolver`: esos mecanismos exigen headers/`IMessageContext.TenantId` y lanzan
  `InvalidOperationException` si faltan -- exactamente lo que rompe el escenario greenfield sin
  autenticacion que este ADR resuelve.
- El archivo lleva un `// TODO(tenancy etapa b)` explicito: cuando el proyecto instale autenticacion
  que produzca un `TenantContext`, reemplazar este resolver por el real de la etapa (b); no dejar el
  default mono-tenant una vez que exista esa autenticacion.

### 3. Alcance de este ADR: solo el registro en el scaffold

Este ADR fija el modelo de dos etapas y la forma concreta del resolver de la etapa (a) que
`domain-scaffolder` genera. La **deteccion** de cuando un proyecto ya tiene autenticacion que produce
un `TenantContext` -- y el consiguiente cambio automatico/propuesto a la etapa (b) desde
`onboard`/`scaffold` -- queda fuera de este ADR (ver "Trabajo diferido").

## Alternativas consideradas

### Alt 1: no registrar ningun `ITenantResolver` por defecto, documentar que el consumidor debe hacerlo

**Descartada**: es el estado actual que origino el incidente en Bitakora.ControlAsistencia -- un
dominio scaffoldeado nace roto (`InvalidOperationException` en la primera invocacion, HTTP 500) y el
problema solo se detecta post-deploy via smoke tests. El scaffold debe producir un proyecto que
arranca, no uno que exige un paso manual documentado en otro lado para no romperse.

### Alt 2: registrar `AgregarTenantResolverHibrido()` (`ProxyTenantResolver`) por defecto en el scaffold

**Descartada**: `ProxyTenantResolver` exige un `HttpContext` con headers confiables o un
`IMessageContext.TenantId` propagado; ninguno de los dos existe en un dominio recien scaffoldeado sin
autenticacion. El resultado seria la misma clase de fallo que origino este ADR, solo que reintroducido
por el propio scaffold en vez de por una regresion de upgrade.

### Alt 3: un solo resolver "inteligente" que intente headers/`TenantContext` y caiga a mono-tenant si no los encuentra

**Descartada**: mezclaria las dos etapas en una sola implementacion con logica condicional oculta,
contra el principio de este ADR de que la eleccion entre (a) y (b) sea explicita y visible en el
`Program.cs` (una linea de registro, un tipo concreto). Ademas oscureceria el momento exacto en que un
proyecto matura de (a) a (b), que es precisamente lo que "Trabajo diferido" quiere poder detectar.

## Consecuencias

### Positivas

- **Un dominio recien scaffoldeado arranca sin `InvalidOperationException` de `ITenantResolver`**: CA-2
  del issue #318 queda satisfecho por construccion.
- **La eleccion de etapa queda explicita y visible**: una unica linea de registro en `Program.cs` y un
  tipo concreto en `Infraestructura/`, sin logica condicional oculta.
- **Reusa el mismo default de tenant que ya usa Marten** (`*DEFAULT*`) en vez de inventar un segundo
  valor, evitando confusion en el event store.

### Negativas

- **El default mono-tenant es un estado que hay que recordar reemplazar**: si un proyecto instala
  autenticacion fuerte y nadie actualiza el registro de `Program.cs`, el dominio sigue funcionando
  (no rompe) pero **todo** evento se atribuye a `*DEFAULT*`/`"usuario-no-autenticado"` aunque ya haya
  usuarios/tenants reales identificables -- un bug silencioso de negocio, no un crash. El
  `// TODO(tenancy etapa b)` mitiga esto pero no lo hace imposible; la deteccion automatica
  (ver "Trabajo diferido") es lo que cerraria el vacio.

### Trabajo diferido

- **Deteccion de la etapa vigente en `onboard`/`scaffold`** (issue #323, depende de este ADR/issue
  #318): detectar si el proyecto ya tiene una autenticacion que produce un `TenantContext` y, en ese
  caso, registrar o proponer el resolver real de la etapa (b) en vez de dejar (o reinstalar) el
  default transitorio.

## Referencias

- **[1]** "Multi-Tenancy" -- Marten docs (martendb.io). "If no explicit tenancy is specified, either
  via policies, mappings, scoped sessions or overloads, Marten will default to
  `StorageConstants.DefaultTenantId` with a constant value of `*DEFAULT*`."
  https://martendb.io/documents/multi-tenancy.html
- **[2]** `JasperFx.StorageConstants` -- codigo fuente publico de JasperFx (github.com/JasperFx/jasperfx,
  `src/JasperFx/StorageConstants.cs`): `public const string DefaultTenantId = "*DEFAULT*";`. Verificado
  ademas decompilando con `ilspycmd` el ensamblado `JasperFx.dll` 2.18.1 (version resuelta
  transitivamente por `Marten` 9.12.0, dependencia de `Cosmos.EventSourcing.CritterStack` 2.1.0).
- `Cosmos.MultiTenancy` / `Cosmos.MultiTenancy.AspNetCore` / `Cosmos.MultiTenancy.CritterStack` 2.1.0:
  paquetes privados del marco sin documentacion publica; el contrato `ITenantResolver` y las
  implementaciones `TrustedHeadersTenantResolver`/`ProxyTenantResolver`/
  `WolverineMessageContextTenantResolver` citados en este ADR se verificaron decompilando con
  `ilspycmd` los ensamblados de la version 2.1.0 (misma version que fija MEF-ADR-0003/issue #312 para
  el resto del stack `Cosmos.Event*`).
- MEF-ADR-0003 (stack ES Marten+Wolverine): fija Marten como event store del marco; este ADR reusa su
  constante de tenant por defecto.
- MEF-ADR-0021 (infraestructura base): el registro del resolver vive en el `Program.cs` que genera
  `domain-scaffolder` como parte del scaffold de cada dominio.
- MEF-ADR-0023 (Bounded Context, topologia de ASB): contexto organizativo del scaffolding de dominios
  al que este ADR aplica.
- Bitakora.ControlAsistencia issues #207 (upgrade `Cosmos.EventSourcing.CritterStack` 0.1.9 -> 2.1.0)
  y #219 (fix del incidente): origen real del vacio que este ADR cierra.

## Control de cambios

- 2026-07-19: creacion como `aceptado` (issue #318). Fija el modelo de dos etapas de tenancy (mono-tenant
  transitorio en greenfield / resolver real basado en `TenantContext`) y la forma concreta del resolver
  de la etapa (a) que `domain-scaffolder` registra por defecto. Bloquea al issue #323 (deteccion de la
  etapa vigente en `onboard`/`scaffold`).
