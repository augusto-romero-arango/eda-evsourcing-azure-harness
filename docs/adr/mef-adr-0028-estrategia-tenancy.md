# MEF-ADR-0028: Estrategia de tenancy — mono-tenant transitorio en greenfield y resolver real basado en TenantContext

- **Fecha**: 2026-07-19
- **Estado**: aceptado
- **Aplica a**: doctrina de tenancy del marco; gobierna al `domain-scaffolder` (registro del `ITenantResolver` en el `Program.cs` que genera, ramificado por etapa), a `/onboard` (diagnostico informativo y escritura opt-in del token de deteccion) y a la futura familia `/install-workos`/`/install-apim`/`/install-auth` (aun no implementados, issue #340: ejecutan la migracion automatizada (a)->(b) que fija la seccion 4, introducida por la enmienda del issue #337). Cross-referencia MEF-ADR-0003 (stack ES Marten+Wolverine), MEF-ADR-0021 (infraestructura base), MEF-ADR-0023 (Bounded Context/topologia de ASB) y MEF-ADR-0032 (identidad y autenticacion en el borde WorkOS+APIM, fuente del insight de normalizacion de claims que habilita la seccion 4).

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

### 3. Deteccion de la etapa vigente: token declarativo `tenancy.strategy` (issue #323)

La eleccion entre (a) y (b) no se sondea en codigo: un grep del harness (agentes/scripts/commands/ADRs)
confirmo cero referencias a `MultiTenancy`/`TenantResolver`/`TenantContext`, asi que no hay ninguna señal
fiable que un agente pueda inspeccionar para inferir si el proyecto ya instalo autenticacion fuerte. La
etapa vigente se **declara**, en un token opcional de nivel superior en `.claude/harness.config.json`:

```json
"tenancy": { "strategy": "mono-tenant-transitorio" }
```

- `strategy`: `"mono-tenant-transitorio"` (etapa a, el default de este ADR) | `"multi-tenant-header"`
  (etapa b).
- **Ausente equivale a `"mono-tenant-transitorio"`** (etapa a): retrocompatible con todo consumidor
  existente y con el greenfield que aun no declara el campo.

**`/onboard`** reporta el valor de este token de forma puramente informativa -- ausente o con cualquiera
de los dos valores validos nunca es `FALTA`, solo `OK`/`NO VERIFICADO` (un greenfield legitimo vive en
etapa (a) por defecto, no es un estado incompleto) -- y gana un paso **opt-in** (tercero, junto a labels
y CI) que pregunta al usuario la estrategia vigente y **escribe/actualiza** `tenancy.strategy` en el
config, solo tras confirmacion explicita: `/onboard` no sondea codigo ni infiere la etapa por su cuenta.

**`domain-scaffolder`** lee `tenancy.strategy` inline con `jq` en su Paso 0 (mismo patron ya usado para
`serviceBus.external`, MEF-ADR-0024) y rama la generacion del `ITenantResolver` que registra en
`Infraestructura/ComposicionServicios{Dominio}.cs`:

- **Etapa (a)** (ausente o `"mono-tenant-transitorio"`): genera `TenantResolverMonoTenantPorDefecto.cs`
  y su registro, exactamente como fija la seccion 2 de este ADR -- sin cambios.
- **Etapa (b)** (`"multi-tenant-header"`): en vez del default transitorio, auto-cablea
  `services.AgregarTenantResolverHibrido()` (`Cosmos.MultiTenancy.CritterStack`, registra
  `ProxyTenantResolver`) -- el resolver hibrido HTTP + daemon de Wolverine descrito en el "Contexto",
  apto porque todo dominio del marco corre handlers de Wolverine. Antes de cablearlo, el agente debe
  **re-confirmar** el tipo y la firma de registro contra la version vigente del paquete (verificados
  aqui por decompilacion, seccion "Contexto") -- si no puede confirmarlos, trata el resolver como **NO
  VERIFICADO** y **degrada a "proponer"** (deja el `PackageReference` y un snippet documentado, sin
  cablearlo) en vez de auto-cablear a ciegas. El archivo generado lleva un `// TODO(tenancy claims)`
  explicito: el mapping de los claims de la autenticacion instalada al header `X-Tenant-Id`/`X-User-Id`
  (o a `IMessageContext.TenantId`) es project-specific para toda autenticacion **fuera** del camino
  WorkOS+APIM que fija MEF-ADR-0032 -- ningun paquete del marco lo automatiza en ese caso general, asi
  que ningun auto-cableo puede completarlo por si solo. La excepcion es el camino WorkOS+APIM: la
  seccion 4 de este ADR documenta por que ese TODO queda resuelto por construccion cuando la
  autenticacion instalada es la que fija MEF-ADR-0032. En cualquiera de las dos ramas
  (auto-cableo o fallback a "proponer") el `ITenantResolver` debe quedar **registrado y construible**:
  el test de composicion del contenedor (MEF-ADR-0029) resuelve los tres routers, que dependen de
  `ITenantResolver` en su constructor, y es un gate duro del scaffold -- si el resolver real arrastra
  dependencias no registradas o si el fallback deja el contrato sin registrar, ese test revienta
  (reintroduciendo el incidente #318). El fallback registra el resolver transitorio de la etapa (a) como
  placeholder para no romperlo.

**Limite manual, salvo el camino automatizado de la seccion 4**: pasar un dominio ya scaffoldeado de
(a) a (b) sigue siendo manual para cualquier autenticacion fuera del camino WorkOS+APIM -- actualizar
el token y volver a correr `/scaffold` no re-scaffoldea dominios existentes. El
`// TODO(tenancy etapa b)` que deja `TenantResolverMonoTenantPorDefecto.cs` (seccion 2) sigue siendo el
recordatorio en el codigo generado para ese caso manual. Cuando la autenticacion instalada es WorkOS
AuthKit + Azure API Management (MEF-ADR-0032), la seccion 4 de este ADR fija esa instalacion como la
transicion (a)->(b) concreta, ejecutada por `/install-apim` -- deja de ser manual **en ese camino
especifico**.

### 4. Transicion automatizada (a)->(b) via WorkOS+APIM (issue #337)

MEF-ADR-0032 (identidad y autenticacion en el borde) fija WorkOS AuthKit + Azure API Management como
el patron de referencia del marco para instalar autenticacion real sobre un BC, y en su seccion 4/5
establece que la politica global de APIM normaliza los claims del JWT a los headers canonicos
`X-Tenant-Id`/`X-User-Id` **antes** de que el request llegue a cualquier Function App -- ese mapping
vive una sola vez, en la politica del gateway, no repetido por dominio. Ese insight vuelve
automatizable, especificamente para ese camino, la transicion (a)->(b) que el resto de esta seccion
deja manual.

- **La transicion concreta**: instalar WorkOS+APIM (MEF-ADR-0032) **es** la transicion (a)->(b)
  concreta del BC. La ejecuta el skill `/install-apim` (invocado por `/install-auth`, orquestador de
  la familia de instalacion de autenticacion junto a `/install-workos`) -- ninguno implementado aun
  (issue #340). En ese camino especifico, la transicion **deja de ser manual**.
- **Que automatiza `/install-apim`**: al instalar el modulo APIM, el skill ejecuta, sin intervencion
  humana adicional:
  1. **Flip del token**: `tenancy.strategy` en `.claude/harness.config.json` pasa de
     `"mono-tenant-transitorio"` a `"multi-tenant-header"` (o se agrega, si estaba ausente).
  2. **Migracion del resolver en todos los dominios ya scaffoldeados** del BC: cada
     `Infraestructura/ComposicionServicios{Dominio}.cs` que registraba
     `services.AddScoped<ITenantResolver, TenantResolverMonoTenantPorDefecto>()` (seccion 2)
     pasa a invocar `services.AgregarTenantResolverHibrido()` (`Cosmos.MultiTenancy.CritterStack`,
     registra `ProxyTenantResolver` -- seccion "Contexto"), y se elimina el archivo
     `TenantResolverMonoTenantPorDefecto.cs` junto con su `// TODO(tenancy etapa b)` de cada dominio
     migrado -- no uno a la vez via `/scaffold`, sino en un solo paso sobre todos los dominios
     existentes del BC.
- **Sin mapping por dominio**: a diferencia del auto-cableo generico que describe la seccion 3 (donde
  el `// TODO(tenancy claims)` queda project-specific porque ningun paquete del marco sabe de donde
  sale cada claim), la migracion via `/install-apim` **no requiere ese mapping por dominio**:
  MEF-ADR-0032 seccion 4 ya fija, en la politica global de APIM, el mapping `user_email -> X-User-Id`
  / `tenant_id -> X-Tenant-Id` con anti-spoofing (`exists-action="override"`) -- un unico lugar,
  compartido por todos los dominios del BC. El `// TODO(tenancy claims)` que dejaria un auto-cableo
  generico queda **resuelto por construccion**: `AgregarTenantResolverHibrido()`/
  `TrustedHeadersTenantResolver` ya leen exactamente esos dos headers canonicos, y `/install-apim` no
  necesita generar ni proponer ningun snippet de parsing de claims especifico del proyecto.
- **El gate no se relaja**: el test de composicion del contenedor DI (MEF-ADR-0029) sigue siendo un
  gate duro despues de la migracion -- resuelve los tres routers (`ICommandRouter`,
  `IPrivateEventSender`, `IPrivateEventRouter`), que dependen de `ITenantResolver` en su constructor,
  y debe seguir en verde en cada dominio migrado. `/install-apim` migra el resolver de forma que el
  contrato quede **registrado y construible** en el mismo commit, sin ninguna ventana donde el
  contenedor quede sin `ITenantResolver` resuelto. El levantamiento del limite "(a)->(b) manual" que
  fija esta seccion aplica **unicamente** al camino WorkOS+APIM: un BC que instale cualquier otra
  autenticacion (Entra External ID, un IdP propio, etc.) sigue sujeto al limite manual descrito arriba.

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
proyecto matura de (a) a (b), que es precisamente lo que el token declarativo `tenancy.strategy`
(seccion 3) permite detectar sin ambiguedad.

## Consecuencias

### Positivas

- **Un dominio recien scaffoldeado arranca sin `InvalidOperationException` de `ITenantResolver`**: CA-2
  del issue #318 queda satisfecho por construccion.
- **La eleccion de etapa queda explicita y visible**: una unica linea de registro en `Program.cs` y un
  tipo concreto en `Infraestructura/`, sin logica condicional oculta.
- **Reusa el mismo default de tenant que ya usa Marten** (`*DEFAULT*`) en vez de inventar un segundo
  valor, evitando confusion en el event store.
- **El camino WorkOS+APIM (MEF-ADR-0032) cierra el riesgo de bug silencioso de la seccion "Negativas"
  para ese caso**: `/install-apim` (seccion 4) automatiza el flip del token y la migracion del resolver
  de todos los dominios ya scaffoldeados en un solo paso, sin dejar una ventana donde un humano deba
  recordar declarar el cambio.

### Negativas

- **El default mono-tenant es un estado que hay que recordar reemplazar, fuera del camino
  WorkOS+APIM**: si un proyecto instala una autenticacion distinta de WorkOS+APIM (MEF-ADR-0032) y
  nadie actualiza `tenancy.strategy` (y vuelve a scaffoldear o migra a mano el dominio), el dominio
  sigue funcionando (no rompe) pero **todo** evento se atribuye a `*DEFAULT*`/`"usuario-no-autenticado"`
  aunque ya haya usuarios/tenants reales identificables -- un bug silencioso de negocio, no un crash. El
  `// TODO(tenancy etapa b)` y el diagnostico informativo de `/onboard` (seccion 3) mitigan esto, pero
  no lo hacen imposible en ese camino manual: pasar de (a) a (b) sigue exigiendo que un humano declare
  el cambio. Cuando el proyecto instala WorkOS+APIM, la seccion 4 elimina esta consecuencia:
  `/install-apim` ejecuta la migracion completa (token + resolver de todos los dominios) por
  construccion, sin depender de que un humano recuerde el paso manual.

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
- MEF-ADR-0032 (identidad y autenticacion en el borde, WorkOS AuthKit + Azure API Management): fija el
  patron que la seccion 4 de este ADR adopta como transicion (a)->(b) automatizada; su seccion 4/5 es
  la fuente del insight de normalizacion de claims en el borde.
- MEF-ADR-0029 (test de composicion del contenedor DI): gate duro que la seccion 4 de este ADR confirma
  que sigue vigente tras la migracion automatizada.
- Bitakora.ControlAsistencia issues #207 (upgrade `Cosmos.EventSourcing.CritterStack` 0.1.9 -> 2.1.0)
  y #219 (fix del incidente): origen real del vacio que este ADR cierra.
- issue #337 (esta enmienda) e issue #340 (`/install-apim`, aun no implementado): origen y consumidor
  concreto de la seccion 4.

## Control de cambios

- 2026-07-19: creacion como `aceptado` (issue #318). Fija el modelo de dos etapas de tenancy (mono-tenant
  transitorio en greenfield / resolver real basado en `TenantContext`) y la forma concreta del resolver
  de la etapa (a) que `domain-scaffolder` registra por defecto. Bloquea al issue #323 (deteccion de la
  etapa vigente en `onboard`/`scaffold`).
- 2026-07-19: enmienda (issue #323). Operacionaliza la deteccion de la etapa vigente: token declarativo
  `tenancy.strategy` (opcional, ausente = etapa a) en `harness.config.json`, reportado informativamente
  por `/onboard` (nunca `FALTA`) y escrito bajo confirmacion en un tercer paso opt-in. `domain-scaffolder`
  lee el token inline con `jq` en su Paso 0 y rama el `ITenantResolver` que registra: etapa (a) sin
  cambios, etapa (b) auto-cablea `AgregarTenantResolverHibrido()` (`Cosmos.MultiTenancy.CritterStack`),
  sujeto a re-verificar tipo/firma contra la version vigente del paquete y a degradar a "proponer" si el
  resolver no resulta generico para el proyecto, dejando un `// TODO(tenancy claims)` para el mapping
  claims -> `TenantContext` (siempre project-specific).
- 2026-07-22: enmienda (issue #337). Fija la seccion 4, "Transicion automatizada (a)->(b) via
  WorkOS+APIM": instalar WorkOS+APIM (MEF-ADR-0032) es la transicion (a)->(b) concreta, ejecutada por
  el futuro skill `/install-apim` (via `/install-auth`), que automatiza el flip de `tenancy.strategy`,
  la migracion del resolver de todos los dominios ya scaffoldeados
  (`TenantResolverMonoTenantPorDefecto` -> `AgregarTenantResolverHibrido()`, removiendo el archivo
  transitorio y su `// TODO(tenancy etapa b)`) y no requiere mapping de claims por dominio (resuelto
  por construccion via la normalizacion de claims en la politica global de APIM, MEF-ADR-0032 seccion
  4/5); el test de composicion (MEF-ADR-0029) sigue siendo gate duro. El limite "(a)->(b) manual" de
  la seccion 3 se acota explicitamente al camino WorkOS+APIM: para cualquier otra autenticacion, sigue
  siendo manual. Se ajustan en el cuerpo el parrafo "Limite deliberado" (seccion 3) y la consecuencia
  negativa del bug silencioso, sin marcarlos obsoletos.
