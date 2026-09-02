---
model: sonnet
---

Instala/actualiza el gateway APIM (Azure API Management) delante de las Function Apps del BC, fiel a MEF-ADR-0032: invoca el agente `apim-gateway-scaffolder` (issue #335) para generar/actualizar los modulos Terraform `api-management`/`apim-function-api` de forma aditiva por dominio, cablea `TF_VAR_workos_client_id` desde la GitHub variable `WORKOS_CLIENT_ID` (la que registro `/install-workos`), y ejecuta la **transicion a->b de tenancy** (MEF-ADR-0028 seccion 4, issue #337, enmendada por el issue #802): flip de `tenancy.strategy` a `"multi-tenant-header"`, scaffold de la biblioteca `src/{RootNamespace}.TenantResolver/` (patron AsyncLocal + middleware, issue #803) y migracion del `ITenantResolver` de **todos** los dominios ya scaffoldeados del BC -- incluidos los que quedaron en el hibrido `AgregarTenantResolverHibrido()` probado roto en Azure Functions isolated worker (issue #802) -- a esa biblioteca. Ademas **detecta automaticamente los servidores MCP del BC** (`src/{RootNamespace}.Mcp.*`, issue #820) y los expone en el mismo flip a->b con el modulo `apim-mcp-api` (gate OAuth de la variante MCP/Connect, MEF-ADR-0032 seccion 9), cableando `Mcp__ResourceUri`/`Mcp__AuthorizationServer` del servidor a la URL real de APIM. Es la capa de **borde** de la auth (segunda tras `/install-workos`): APIM se monta delante de Function Apps existentes, asi que exige infra base + al menos un dominio ya scaffoldeado. Comunicate en **espanol**.

## Pre-condicion: cwd != Mefisto

Este skill es del plugin publicado y solo aplica al repo consumidor. Mefisto no tiene `infra/` ni dominios de negocio. Verifica antes de continuar:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /install-apim no aplica al repo de Mefisto."
    exit 1
fi
```

Si el bloque imprime `ERROR`, detente y muestra el mensaje al usuario.

## Entrada

`$ARGUMENTS`:

```
--domain <Dominio> [--domain <Dominio2> ...] [--env <env>] [--cors-origin <origin> ...] [--authorization-server-url <url>]
```

- **`--domain <Dominio>`** (obligatorio, repetible): uno o mas dominios **ya scaffoldeados** (`/scaffold`) a exponer detras del gateway. Acepta kebab o PascalCase. Podes correr este skill varias veces agregando dominios nuevos cada vez (CA-2, aditivo) sin re-crear la instancia.
- **`--env <env>`** (opcional, default `dev`): ambiente Terraform.
- **`--cors-origin <origin>`** (repetible): origen del SPA para el preflight CORS (B3, MEF-ADR-0032). **Obligatorio solo la primera vez** que se instala el gateway en este entorno (cuando `apim.tf` todavia no existe); en corridas posteriores se ignora -- agregar un origen a un gateway ya instalado es cambiar el valor de la GitHub variable `CORS_ALLOWED_ORIGINS` (fuera del alcance de este skill, se hace con `gh variable set CORS_ALLOWED_ORIGINS`).
- **`--authorization-server-url <url>`** (issue #820): dominio AuthKit del entorno (MEF-ADR-0032 B12), **nunca** el issuer client-specific de login. No hace falta pasarlo a mano si `WORKOS_AUTHORIZATION_SERVER_URL` ya esta registrada como GitHub variable (de una corrida previa que expuso un servidor MCP); **obligatorio solo la primera vez que este skill detecta al menos un servidor MCP** (Paso 2b) y esa variable todavia no existe. Un BC sin ningun servidor MCP puede ignorar esta flag por completo (CA-5).

**Los servidores MCP del BC (`src/{RootNamespace}.Mcp.*`) se detectan automaticamente** -- no hay una flag `--mcp-server`: a diferencia de los dominios (que este skill nunca crea), el operador no elige "cuales" servidores MCP exponer, expone **todos** los que `/scaffold-mcp` ya genero, igual que la migracion de tenancy del paso 9 aplica a todos los dominios ya scaffoldeados (no solo a los pasados por `--domain`).

Si falta `--domain`, responde con el uso exacto y detente sin ejecutar nada.

## Nombres fijos de este skill (no configurables)

| Artefacto | Nombre | Por que |
|---|---|---|
| GitHub **variable** (client_id de login) | `WORKOS_CLIENT_ID` | Ya la registro `/install-workos` (MEF-ADR-0032 seccion 6/7); este skill solo la **lee/verifica**, nunca la crea desde cero. |
| GitHub **variable** (origenes CORS) | `CORS_ALLOWED_ORIGINS` | JSON list; requerida sin default por `apim.tf` (`var.cors_allowed_origins`), solo la primera vez que se crea el archivo (`agents/apim-gateway-scaffolder.md` Paso 3b). |
| GitHub **variable** (dominio AuthKit del entorno, issue #820) | `WORKOS_AUTHORIZATION_SERVER_URL` | No secreta (MEF-ADR-0032 seccion 6, mismo estatus que `WORKOS_CLIENT_ID`); requerida sin default por `apim-mcp-prm.tf` (`var.mcp_authorization_server_url`), solo la primera vez que este skill detecta al menos un servidor MCP (`agents/apim-gateway-scaffolder.md` Paso 3c). |
| Token en `harness.config.json` | `tenancy.strategy = "multi-tenant-header"` | Flip que ejecuta CA-4 (MEF-ADR-0028 seccion 4). |
| Biblioteca de tenancy scaffoldeada | `src/<RootNamespace>.TenantResolver/` | `TenantExecutionContext` + `TenantContextMiddleware`, patron AsyncLocal + middleware (MEF-ADR-0028 seccion 4, enmendada por el issue #802). Una sola por BC, referenciada por todos los dominios migrados. |
| Registro de `ITenantResolver` que reemplaza el transitorio (o el hibrido roto) | `services.AgregarTenantResolverAsyncLocal()` | Extension de la biblioteca scaffoldeada de arriba -- ya no de `Cosmos.MultiTenancy.CritterStack` (issue #802). |
| Middleware del worker que puebla la identidad | `builder.UsarTenantContextMiddleware()` | Invocado en `Program.cs` de cada dominio migrado, antes de `builder.Build()` (MEF-ADR-0028 seccion 4). |

## Proceso

### 1. Parsear `$ARGUMENTS`

Extrae la lista de `DOMINIOS` (uno o mas `--domain`), `ENV` (default `dev`), la lista de `CORS_ORIGINS` (`--cors-origin`, puede venir vacia) y `AUTHORIZATION_SERVER_URL` (`--authorization-server-url`, puede venir vacio -- issue #820). Si no hay ningun `--domain`, responde con el uso exacto y detente.

### 2. Verificar prerequisitos (CA-1)

```bash
test -f "infra/environments/${ENV}/main.tf" && test -d infra/modules/resource-group || {
  echo "FALTA la infraestructura base: corre /infra-base antes de /install-apim."
  exit 1
}

ls infra/environments/"${ENV}"/dominio-*.tf >/dev/null 2>&1 || {
  echo "FALTA: ningun dominio esta scaffoldeado todavia en el entorno ${ENV}. Corre /scaffold <dominio> primero -- APIM se monta delante de Function Apps existentes, no tiene sentido sin al menos una."
  exit 1
}
```

Si cualquiera de los dos falta, detente con el mensaje -- no continues con el resto del proceso.

### 2b. Detectar los servidores MCP del BC (CA-3 del issue #820)

Resuelve primero `<RootNamespace>` leyendo el `CLAUDE.md` raiz del consumidor (seccion "Tokens del harness"), igual que el paso 9.1 -- este paso lo necesita antes que aquel. Si no esta declarado, **no te detengas aca**: reporta `SERVIDORES_MCP` como no determinable y segui (el paso 9.1 vuelve a intentarlo y ahi si es bloqueante).

```bash
ls -d src/<RootNamespace>.Mcp.*/ 2>/dev/null | sed -E 's#.*<RootNamespace>\.Mcp\.([^/]+)/#\1#'
```

Cada nombre listado es un `{Proposito}` (PascalCase) ya scaffoldeado por `/scaffold-mcp`. Llama a esta lista `SERVIDORES_MCP` -- puede venir vacia, y **eso es un resultado normal, no un error** (CA-5): un BC sin servidores MCP sigue el resto del proceso exactamente igual que antes del issue #820, sin ningun paso adicional de MCP en ningun punto de este skill. No hay flag para elegir "cuales" servidores MCP exponer -- se exponen todos los detectados, igual que la migracion de tenancy del paso 9 aplica a todos los dominios.

### 3. Confirmar con el usuario

Muestra exactamente lo que va a pasar y pide confirmacion explicita -- este skill escribe Terraform, GitHub variables, y **reescribe codigo C# existente** en todos los dominios del BC (la migracion de tenancy, no solo en los dominios pasados por `--domain`):

```
Se va a instalar/actualizar el gateway APIM en el entorno "<env>" para: <lista de dominios>
<si SERVIDORES_MCP no esta vacia, agregar aca: "y para los servidores MCP: <lista de SERVIDORES_MCP>">

  1. Modulos Terraform api-management/apim-function-api (agente apim-gateway-scaffolder, issue #335),
     aditivo por dominio -- nunca re-crea la instancia si ya existe.
  2. Cableado de TF_VAR_workos_client_id (y TF_VAR_cors_allowed_origins la primera vez) en infra-cd.yml.
  3. TRANSICION DE TENANCY (a)->(b) (MEF-ADR-0028 seccion 4, enmendada por el issue #802): flip de
     tenancy.strategy a "multi-tenant-header" + scaffold (si falta) de la biblioteca
     src/<RootNamespace>.TenantResolver/ (TenantExecutionContext + TenantContextMiddleware, patron
     AsyncLocal + middleware) + migracion del ITenantResolver de TODOS los dominios ya scaffoldeados
     del BC (no solo los de arriba) -- incluidos los que hoy quedaron en el hibrido roto
     AgregarTenantResolverHibrido() de una corrida previa de este skill (issue #802) -- a
     services.AgregarTenantResolverAsyncLocal() + builder.UsarTenantContextMiddleware(), eliminando
     TenantResolverMonoTenantPorDefecto.cs de cada uno. Cada dominio migrado se valida con su propio
     test de composicion del contenedor (MEF-ADR-0029) antes de commitear.
<si SERVIDORES_MCP no esta vacia, agregar:>
  4. MCP (issue #820, MEF-ADR-0032 seccion 9): modulo apim-mcp-api + enrutador compartido del PRM
     (agente apim-gateway-scaffolder), uno por servidor MCP detectado -- gate OAuth de la variante
     MCP/Connect en el borde, nunca en el worker del servidor (MEF-ADR-0047 decision 7). Cablea
     Mcp__ResourceUri/Mcp__AuthorizationServer del servidor a la URL real de APIM (CA-4).

El apply real (el que provisiona APIM en Azure) corre en CI al mergear el PR (MEF-ADR-0022); este
skill nunca ejecuta terraform plan/apply. El checklist post-deploy (CORS, 401, 202, headers de
identidad, verbo QUERY<si aplica MCP: ", Resource Indicator byte a byte">) queda pendiente para
despues de ese apply.

¿Continuar? (s/n)
```

Si dice no, detente sin escribir nada.

### 4. Rama de trabajo unica

El agente del paso 8 y la migracion del paso 9 commitean cada uno por su cuenta si te invocan desde `main`, pero en ramas **distintas** si no coordinas una compartida. Crea la rama **antes** de invocar nada:

```bash
git rev-parse --abbrev-ref HEAD
# si es main/master:
git switch -c "install-apim/${ENV}"
```

(Si te invoco desde un pipeline que ya creo un worktree y rama, commitea ahi sin crear otra.)

### 5. Resolver si es la primera instalacion del gateway en este entorno

```bash
test -f "infra/environments/${ENV}/apim.tf" && echo "GATEWAY_EXISTE=true" || echo "GATEWAY_EXISTE=false"
```

- Si `GATEWAY_EXISTE=false` (primera instalacion): `--cors-origin` es **obligatorio**. Si `$ARGUMENTS` no trajo ninguno, responde con el uso exacto y detente -- sin al menos un origen, `apim.tf` quedaria con `cors_allowed_origins` (variable requerida, sin default) sin forma de resolverla en el paso 7.
- Si `GATEWAY_EXISTE=true`: ignora cualquier `--cors-origin` recibido y avisa al usuario que un origen nuevo se agrega actualizando la GitHub variable `CORS_ALLOWED_ORIGINS` directamente (`gh variable set CORS_ALLOWED_ORIGINS --body '[...]'`), fuera del alcance de este skill.

### 6. Resolver `WORKOS_CLIENT_ID` (GitHub variable, ya registrada por `/install-workos`)

```bash
WORKOS_CLIENT_ID=$(gh variable list --json name,value -q '.[] | select(.name=="WORKOS_CLIENT_ID") | .value' 2>/dev/null)
```

- Si no hay valor **y** es la primera instalacion (`GATEWAY_EXISTE=false`): detente. Indica al usuario correr `/install-workos` primero (produce este valor guiando el dashboard de WorkOS) o, si ya tiene la cuenta configurada, `gh variable set WORKOS_CLIENT_ID --body "<client_id>"`.
- Si no hay valor pero el gateway ya existe (`GATEWAY_EXISTE=true`): continua -- el `apply` de CI ya tiene el valor cableado de una corrida anterior. Marca en el reporte final que la re-verificacion del discovery doc (Paso 0.3 del agente) no pudo correr por falta del client_id en este chat.
- Si `gh` no esta autenticado o falla, repórtalo `NO VERIFICADO` y continua -- no bloquees el resto del skill por esto.

### 7. Registrar/verificar `CORS_ALLOWED_ORIGINS` (solo primera instalacion)

Si `GATEWAY_EXISTE=false`:

```bash
CURRENT=$(gh variable list --json name,value -q '.[] | select(.name=="CORS_ALLOWED_ORIGINS") | .value' 2>/dev/null)
```

- Si ya tiene un valor, repórtalo y pregunta si coincide con los `--cors-origin` recibidos. Si el usuario confirma que difiere, sobreescribe; si coincide, no hagas nada.
- Si no existe, registralo como JSON list de los origenes recibidos:

```bash
CORS_JSON=$(printf '%s\n' "${CORS_ORIGINS[@]}" | jq -R . | jq -s -c .)
gh variable set CORS_ALLOWED_ORIGINS --body "$CORS_JSON"
```

Si `GATEWAY_EXISTE=true`, omite este paso -- `CORS_ALLOWED_ORIGINS` ya deberia existir de la instalacion original. Si no existe (estado inconsistente: `apim.tf` ya aplicado pero la variable ausente), repórtalo `NO VERIFICADO` sin bloquear -- el `apply` de CI fallaria por su cuenta si de verdad falta, señal mas fuerte que la de este skill.

### 7b. Resolver `WORKOS_AUTHORIZATION_SERVER_URL` (solo si `SERVIDORES_MCP` no esta vacia, issue #820)

Omite este paso entero si el paso 2b no detecto ningun servidor MCP (CA-5).

```bash
MCP_AUTH_SERVER_URL=$(gh variable list --json name,value -q '.[] | select(.name=="WORKOS_AUTHORIZATION_SERVER_URL") | .value' 2>/dev/null)
```

- Si ya tiene un valor: repórtalo y, si `--authorization-server-url` trajo uno distinto, pregunta si el usuario quiere sobreescribirlo (mismo criterio que el paso 7 para `CORS_ALLOWED_ORIGINS`); si coinciden o no vino la flag, no toques nada.
- Si no existe y `--authorization-server-url` vino en `$ARGUMENTS`: registralo (`gh variable set WORKOS_AUTHORIZATION_SERVER_URL --body "<url>"`).
- Si no existe y la flag tampoco vino: **detente**. A diferencia de `WORKOS_CLIENT_ID` (paso 6, que puede degradar a `NO VERIFICADO` si el gateway ya existe), esta variable es **obligatoria** para generar el modulo `apim-mcp-api` de cualquier servidor MCP detectado -- sin ella, la politica de validate-jwt de la variante MCP/Connect no tiene issuer que validar. Indica al usuario el uso exacto (`--authorization-server-url <url>`) y el origen del valor: el dominio -- propio o de WorkOS -- que sirve AuthKit para el proyecto del entorno (MEF-ADR-0032 B12), visible en el dashboard de WorkOS, seccion AuthKit del proyecto.
- Si `gh` no esta autenticado o falla: cuando `--authorization-server-url` vino en `$ARGUMENTS`, usa ese valor y reporta la variable como `NO VERIFICADO -- no se pudo registrar en GitHub, hacerlo a mano antes del apply`; cuando tampoco vino, **detente** igual que en el caso anterior. No hay modo parcial "sigo con los dominios y omito los MCP": el skill deja el arbol sin tocar y el usuario lo reintenta con la flag.

### 8. Invocar el agente `apim-gateway-scaffolder` (CA-2, CA-3)

```bash
claude --agent apim-gateway-scaffolder "Instala/actualiza el gateway APIM en el entorno <env> para los dominios: <lista de --domain, separados por coma>. WorkOS client_id: <WORKOS_CLIENT_ID resuelto, o 'NO VERIFICADO' si vacio>. CORS allowed origins: <lista de --cors-origin, o 'gateway ya instalado, no recrear cors_allowed_origins' si GATEWAY_EXISTE=true>. Servidores MCP a exponer: <lista de SERVIDORES_MCP separados por coma, o 'ninguno' si vacia>. Dominio AuthKit del entorno (authorization_server_url): <MCP_AUTH_SERVER_URL resuelto, o 'N/A -- sin servidores MCP' si SERVIDORES_MCP vino vacia>."
```

El agente es aditivo/idempotente por su cuenta (sus Pasos 0.2/0.4/1/2/2b/3/3b/3c/4/4b): si algun `--domain` o servidor MCP no esta scaffoldeado, lo omite y lo reporta sin abortar el resto del batch -- reflejalo en el reporte final (paso 13). Tambien cablea `TF_VAR_workos_client_id`/`TF_VAR_cors_allowed_origins`/`TF_VAR_mcp_authorization_server_url` en `infra-cd.yml` (sus Pasos 3b/3c -- esto **es** el CA-3 de este issue y del issue #820, ya resuelto por el agente), genera `apim-mcp-api`/`apim-mcp-prm.tf`/`apim-mcp-{proposito-kebab}.tf` por cada servidor MCP detectado y patchea `Mcp__ResourceUri`/`Mcp__AuthorizationServer` en el `mcp-{proposito-kebab}.tf` de cada uno (su Paso 4b -- esto **es** el CA-4 de este issue), y corre `fmt`/`init -backend=false`/`validate` (su Paso 5) antes de commitear (su Paso 6, en la rama que ya creaste en el paso 4).

### 9. Ejecutar la transicion a->b de tenancy (CA-4, MEF-ADR-0028 seccion 4)

#### 9.1 Resolver `<RootNamespace>`

Lee el `CLAUDE.md` raiz del proyecto consumidor (contrato, seccion "Tokens del harness") para resolver `<RootNamespace>` (si el paso 2b ya lo resolvio, reusa ese valor -- no lo releas). Si no esta declarado, detente y pide al usuario que lo declare -- mismo criterio que `domain-scaffolder`.

#### 9.2 Flip del token

```bash
jq -r '.tenancy.strategy // "mono-tenant-transitorio"' .claude/harness.config.json
```

- Si ya es `"multi-tenant-header"`: no toques el archivo. Repórtalo "ya en etapa (b)" y segui directo al 9.3 -- puede haber dominios scaffoldeados entre corridas que todavia no se migraron.
- Si es `"mono-tenant-transitorio"` o el campo esta ausente: agrega/actualiza en `.claude/harness.config.json`:

  ```json
  "tenancy": { "strategy": "multi-tenant-header" }
  ```

  (si el objeto `tenancy` ya existe con otros campos, preservalos; el archivo en si ya deberia existir -- si no existe, algo esta mal, `/onboard` deberia haberlo creado -- detente y avisa.)

#### 9.3 Scaffold de la biblioteca `src/<RootNamespace>.TenantResolver/` (CA-1, MEF-ADR-0028 seccion 4)

Esta biblioteca es la que consumen todos los dominios migrados en el paso 9.4 -- se scaffoldea una sola vez por BC, no por dominio. Verifica primero si ya existe:

```bash
test -d "src/<RootNamespace>.TenantResolver" && echo "TENANTRESOLVER_LIB=EXISTE" || echo "TENANTRESOLVER_LIB=FALTA"
```

Si `TENANTRESOLVER_LIB=EXISTE` (instalada por una corrida previa de este skill, o portada a mano en un hotfix del consumidor -- precedente: Bitakora.ControlAsistencia PR #546, que porto la biblioteca de Cosmos.ControlPlane con sus tests), omite el resto de este paso y repórtalo -- no la reescribas: una biblioteca ya portada puede tener ajustes propios del BC que este skill no conoce.

Si falta, créala:

**a. Proyecto:**

```bash
dotnet new classlib -n "<RootNamespace>.TenantResolver" -o "src/<RootNamespace>.TenantResolver" -f net10.0
rm -f "src/<RootNamespace>.TenantResolver/Class1.cs"
```

**b. `.csproj`** (`src/<RootNamespace>.TenantResolver/<RootNamespace>.TenantResolver.csproj`): reemplaza el generado por:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>

  <ItemGroup>
    <!-- Contrato ITenantResolver (MEF-ADR-0028). Aqui SI hace falta explicito -- a diferencia del
         Function App de un dominio, esta biblioteca no referencia Cosmos.EventSourcing.CritterStack
         (que lo trae transitivo), asi que ITenantResolver no llegaria de otra forma. -->
    <PackageReference Include="Cosmos.MultiTenancy" Version="2.1.0" />
    <!-- FunctionContext, IFunctionsWorkerMiddleware, BindInputAsync, UseMiddleware<T>
         (Microsoft.Azure.Functions.Worker.Core, transitivo de este metapaquete). Mismo pin que el
         Function App de cada dominio (issue #263). -->
    <PackageReference Include="Microsoft.Azure.Functions.Worker" Version="2.52.0" />
    <!-- FunctionContext.GetHttpContext() -- unica forma de llegar al HttpContext real de ASP.NET Core
         desde un middleware del worker cuando Program.cs usa ConfigureFunctionsWebApplication()
         (MEF-ADR-0021), como todo Function App que emite domain-scaffolder. Version vigente en
         NuGet.org al momento de este cambio (2.1.1); revalidarla contra la fuente. -->
    <PackageReference Include="Microsoft.Azure.Functions.Worker.Extensions.Http.AspNetCore" Version="2.1.1" />
    <!-- Tipo ServiceBusReceivedMessage para el BindInputAsync<T> del trigger de Service Bus. Mismo pin
         que fija el bloque de SmokeTests de domain-scaffolder (issue #605). -->
    <PackageReference Include="Azure.Messaging.ServiceBus" Version="7.20.2" />
  </ItemGroup>

</Project>
```

**c. `TenantExecutionContext.cs`:**

```csharp
using Cosmos.MultiTenancy;

namespace <RootNamespace>.TenantResolver;

// Implementacion de referencia: patron AsyncLocal + middleware de Cosmos.ControlPlane
// (src/Cosmos.ControlPlane.TenantResolver/), adoptado por MEF-ADR-0028 seccion 4 (enmienda del
// issue #802) tras confirmar que ProxyTenantResolver (Cosmos.MultiTenancy.CritterStack) decide la
// rama HTTP/Wolverine en su constructor y queda inservible para HTTP en Azure Functions isolated
// worker. Singleton SIN estado de instancia: la identidad vive en AsyncLocal<string?> ESTATICO, que
// fluye con la cadena logica async y por eso sigue visible dentro del IServiceScope hijo que
// construye Wolverine (JasperFx LazyServiceLocationFrame) -- a diferencia del estado por-instancia,
// que se perderia al cruzar ese scope.
public sealed class TenantExecutionContext : ITenantResolver
{
    private static readonly AsyncLocal<string?> TenantIdActual = new();
    private static readonly AsyncLocal<string?> UserIdActual = new();

    // Getter ruidoso (MEF-ADR-0028 seccion 4): lanza si se lee antes de que TenantContextMiddleware
    // puebla la identidad para esta invocacion, o si el trigger no trae identidad del gateway y
    // nadie llamo SetDerivedIdentity() antes de esta lectura -- nunca degrada a un default en
    // silencio (mismo principio de fail-fast que ProxyTenantResolver/TrustedHeadersTenantResolver).
    public string TenantId => TenantIdActual.Value ?? throw new InvalidOperationException(
        "TenantExecutionContext.TenantId sin identidad poblada para esta invocacion: " +
        "TenantContextMiddleware no corrio todavia, o el trigger no trae identidad del gateway y " +
        "nadie llamo SetDerivedIdentity() antes de esta lectura.");

    public string UserId => UserIdActual.Value ?? throw new InvalidOperationException(
        "TenantExecutionContext.UserId sin identidad poblada para esta invocacion: " +
        "TenantContextMiddleware no corrio todavia, o el trigger no trae identidad del gateway y " +
        "nadie llamo SetDerivedIdentity() antes de esta lectura.");

    // Puebla la identidad de la invocacion en curso. La usa TenantContextMiddleware (headers HTTP o
    // ApplicationProperties de Service Bus); tambien queda publica para que un handler sin gateway
    // por delante (p. ej. un timer trigger, o un Service Bus trigger de un evento interno sin claim
    // de usuario) derive y fije su propia identidad antes de que el codigo de negocio la lea.
    public static void SetDerivedIdentity(string? tenantId, string? userId)
    {
        TenantIdActual.Value = tenantId;
        UserIdActual.Value = userId;
    }
}
```

**d. `TenantContextMiddleware.cs`:**

```csharp
using Azure.Messaging.ServiceBus;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Middleware;

namespace <RootNamespace>.TenantResolver;

// Puebla TenantExecutionContext al inicio de CADA invocacion, antes de que el activador de la
// funcion construya ninguna dependencia (corre en el ultimo middleware del pipeline del worker,
// FunctionExecutionMiddleware -- Microsoft Learn, UseMiddleware<T>/IFunctionsWorkerMiddleware):
// exactamente lo que resuelve el catch-22 de ProxyTenantResolver que documenta MEF-ADR-0028 seccion
// 4 ("Contexto") -- para cuando ICommandRouter/IPrivateEventSender/IPrivateEventRouter resuelven
// ITenantResolver, el AsyncLocal ya tiene el valor correcto.
public sealed class TenantContextMiddleware : IFunctionsWorkerMiddleware
{
    private const string HeaderTenantId = "X-Tenant-Id";
    private const string HeaderUserId = "X-User-Id";
    private const string PropiedadTenantId = "tenant-id";
    private const string PropiedadUserId = "user_id";

    public async Task Invoke(FunctionContext context, FunctionExecutionDelegate next)
    {
        var trigger = context.FunctionDefinition.InputBindings.Values
            .FirstOrDefault(binding => binding.Type.EndsWith("Trigger", StringComparison.Ordinal));

        // El if (en vez de un switch sobre trigger?.Type) es lo que le da al compilador el estado
        // no-nulo de trigger dentro del bloque: BindInputAsync exige un BindingMetadata no anulable
        // y un switch sobre el ?. no propaga ese narrowing.
        if (trigger is not null)
        {
            switch (trigger.Type)
            {
                case "httpTrigger":
                    // ConfigureFunctionsWebApplication() (MEF-ADR-0021) habilita el HttpContext real
                    // de ASP.NET Core; el mapping claim -> header ya lo hizo la politica global de
                    // APIM (MEF-ADR-0032 seccion 4), asi que aca solo se lee, nunca se parsea un JWT.
                    var httpContext = context.GetHttpContext();
                    TenantExecutionContext.SetDerivedIdentity(
                        httpContext?.Request.Headers[HeaderTenantId].FirstOrDefault(),
                        httpContext?.Request.Headers[HeaderUserId].FirstOrDefault());
                    break;

                case "serviceBusTrigger":
                    var mensaje = await context.BindInputAsync<ServiceBusReceivedMessage>(trigger);
                    var propiedades = mensaje.Value?.ApplicationProperties;
                    TenantExecutionContext.SetDerivedIdentity(
                        LeerPropiedad(propiedades, PropiedadTenantId),
                        LeerPropiedad(propiedades, PropiedadUserId));
                    break;

                // Cualquier otro trigger (timer, etc.) no trae identidad del gateway: queda sin poblar
                // a proposito -- el handler que la necesite llama TenantExecutionContext.SetDerivedIdentity()
                // el mismo antes de leerla (MEF-ADR-0028 seccion 4).
            }
        }

        await next(context);
    }

    private static string? LeerPropiedad(IReadOnlyDictionary<string, object>? propiedades, string clave)
        => propiedades is not null && propiedades.TryGetValue(clave, out var valor)
            ? valor?.ToString()
            : null;
}
```

**e. `TenantResolverExtensions.cs`** (las dos extensiones de composicion, MEF-ADR-0028 seccion 4):

```csharp
using Cosmos.MultiTenancy;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace <RootNamespace>.TenantResolver;

public static class TenantResolverServiceCollectionExtensions
{
    // Singleton, no scoped: el estado real vive en el AsyncLocal, no en el ciclo de vida de DI
    // (MEF-ADR-0028 seccion 4). RemoveAll<ITenantResolver>() hace este metodo seguro de invocar
    // sobre CUALQUIER registro previo -- mono-tenant transitorio (etapa a) o el hibrido roto
    // AgregarTenantResolverHibrido() (issue #802) -- sin dejar dos implementaciones registradas.
    public static IServiceCollection AgregarTenantResolverAsyncLocal(this IServiceCollection services)
    {
        services.RemoveAll<ITenantResolver>();
        services.AddSingleton<ITenantResolver, TenantExecutionContext>();
        return services;
    }
}

public static class TenantResolverWorkerApplicationBuilderExtensions
{
    // Azucar sobre UseMiddleware<T> (Microsoft Learn, referencia [3] de MEF-ADR-0028). Se invoca
    // sobre el FunctionsApplicationBuilder que devuelve FunctionsApplication.CreateBuilder(args),
    // antes de builder.Build() -- nunca sobre un "app" de ASP.NET Core: en el modelo isolated worker
    // el middleware se registra en el IFunctionsWorkerApplicationBuilder, no en el request pipeline.
    public static IFunctionsWorkerApplicationBuilder UsarTenantContextMiddleware(
        this IFunctionsWorkerApplicationBuilder builder)
        => builder.UseMiddleware<TenantContextMiddleware>();
}
```

Si el build del paso h falla por un `using`/namespace incorrecto de `IFunctionsWorkerApplicationBuilder` o `UseMiddleware<T>` (el compilador es la fuente de verdad final para estas firmas -- mismo principio que ya aplica `workos-identity-scaffolder` Paso 4 para SDKs de terceros), ajustalo con el error exacto que reporte antes de continuar.

**f. Proyecto de tests** `tests/<RootNamespace>.TenantResolver.Tests/`:

```bash
mkdir -p "tests/<RootNamespace>.TenantResolver.Tests"
```

`tests/<RootNamespace>.TenantResolver.Tests/<RootNamespace>.TenantResolver.Tests.csproj` (xUnit v3 llano, mismo patron que el `SmokeTests` de `domain-scaffolder` -- esta biblioteca no toca el event store, no aplica el DSL Given/When/Then de `Cosmos.EventSourcing.Testing.Utilities`, MEF-ADR-0002):

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <OutputType>Exe</OutputType>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <IsPackable>false</IsPackable>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.Extensions.DependencyInjection" Version="10.0.11" />
    <PackageReference Include="xunit.v3.mtp-v2" Version="3.2.2" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="..\..\src\<RootNamespace>.TenantResolver\<RootNamespace>.TenantResolver.csproj" />
  </ItemGroup>

  <ItemGroup>
    <Using Include="Xunit" />
  </ItemGroup>

</Project>
```

`tests/<RootNamespace>.TenantResolver.Tests/TenantExecutionContextTests.cs` -- los dos tests que exige CA-1 (fallo ruidoso sin identidad + cruce de scope async):

```csharp
using Cosmos.MultiTenancy;
using Microsoft.Extensions.DependencyInjection;

namespace <RootNamespace>.TenantResolver.Tests;

public class TenantExecutionContextTests
{
    [Fact]
    public void TenantIdYUserId_SinIdentidadPoblada_LanzanInvalidOperationException()
    {
        // Limpia explicitamente antes de leer: el getter debe fallar tanto si el middleware nunca
        // corrio como si corrio con un header ausente (mismo tratamiento, MEF-ADR-0028 seccion 4).
        TenantExecutionContext.SetDerivedIdentity(null, null);
        var resolver = new TenantExecutionContext();

        Assert.Throws<InvalidOperationException>(() => resolver.TenantId);
        Assert.Throws<InvalidOperationException>(() => resolver.UserId);
    }

    [Fact]
    public async Task SetDerivedIdentity_CruzaAwaitYScopeHijoDeWolverine_SigueVisible()
    {
        var proveedor = new ServiceCollection()
            .AddSingleton<ITenantResolver, TenantExecutionContext>()
            .BuildServiceProvider();

        TenantExecutionContext.SetDerivedIdentity("tenant-cruce", "user-cruce");
        await Task.Yield();

        // Simula el IServiceScope hijo que Wolverine crea para construir sus handlers (JasperFx
        // LazyServiceLocationFrame, MEF-ADR-0028 seccion 4): el AsyncLocal no depende del scope de
        // DI, asi que el valor sigue visible aunque el resolver se resuelva desde un scope distinto
        // al que lo poblo -- justo lo que rompia a ProxyTenantResolver (issue #802).
        using var scopeHijo = proveedor.CreateScope();
        var resolver = scopeHijo.ServiceProvider.GetRequiredService<ITenantResolver>();

        Assert.Equal("tenant-cruce", resolver.TenantId);
        Assert.Equal("user-cruce", resolver.UserId);
    }
}
```

**g. Agregar los dos proyectos a la solucion y verificar `global.json`.**

Todo proyecto del consumidor se registra en el archivo de solucion (`domain-scaffolder` Paso 3, `projections-scaffolder` Paso 3): sin esto el `build-and-test` del CI -- que restaura/compila la solucion -- nunca corre los tests de la biblioteca, aunque el `.csproj` del dominio la arrastre por `ProjectReference`. Resuelve `<SolutionFile>` con `ls *.slnx *.sln 2>/dev/null` en la raiz del repo:

```bash
dotnet sln <SolutionFile> add "src/<RootNamespace>.TenantResolver/"
dotnet sln <SolutionFile> add "tests/<RootNamespace>.TenantResolver.Tests/"
```

(`dotnet sln add` sobre un proyecto ya listado es no-op: imprime "La solucion ... ya contiene el proyecto X", sale con codigo 0 y no duplica la entrada -- misma idempotencia que ya explotan `domain-scaffolder` y `projections-scaffolder`. Si el repo no tiene archivo de solucion, omitilo y repórtalo.)

**Verificar `global.json`** (mismo requisito que el resto del repo para xUnit v3 mtp-v2, ver `agents/domain-scaffolder.md`): si `global.json` en la raiz no tiene la seccion `test`, este proyecto nuevo no corre con `dotnet test`. No lo toques si ya existe (otro scaffold ya lo dejo listo) -- solo repórtalo si falta.

**h. Compilar y correr los tests (gate antes de dar la biblioteca por lista):**

```bash
dotnet build "src/<RootNamespace>.TenantResolver/<RootNamespace>.TenantResolver.csproj" 2>&1 | tail -40
dotnet test "tests/<RootNamespace>.TenantResolver.Tests" 2>&1 | tail -40
```

- Si ambos pasan, la biblioteca queda lista para que el paso 9.4 la referencie en cada dominio.
- Si `dotnet` no esta disponible, o el build/los tests fallan, **detente**: no continues al paso 9.4 con una biblioteca sin verificar -- un dominio que la referencie tampoco compilaria. Reportalo como bloqueante en el paso 13 (nunca degrades a "proponer" callado; sin esta biblioteca no hay migracion de tenancy posible en esta corrida).

#### 9.4 Migrar el resolver de cada dominio ya scaffoldeado (CA-2, CA-3)

Descubre **todos** los dominios del BC, no solo los pasados por `--domain` -- MEF-ADR-0028 seccion 4 exige migrar todos los ya scaffoldeados:

```bash
ls src/<RootNamespace>.*/Infraestructura/ComposicionServicios*.cs 2>/dev/null
```

Por cada archivo encontrado (dominio `{PascalCase}`, proyecto `src/<RootNamespace>.{PascalCase}/`):

- **Si ya contiene `services.AgregarTenantResolverAsyncLocal()`**: ya migrado al patron nuevo (en una corrida previa de este skill, o -- a futuro -- scaffoldeado directo en etapa b por `domain-scaffolder`, issue #804). Omite y reporta.
- **Si contiene exactamente `services.AddScoped<ITenantResolver, TenantResolverMonoTenantPorDefecto>();`** (el registro que emite `domain-scaffolder` en etapa a, MEF-ADR-0028 seccion 2): migralo (pasos siguientes).
- **Si contiene `services.AgregarTenantResolverHibrido();`** (el hibrido de `Cosmos.MultiTenancy.CritterStack` que emitia la version anterior de este skill, probado roto en Azure Functions isolated worker -- issue #802): **tambien migralo** (pasos siguientes). Este es el cambio de esta reescritura (issue #803) frente a la version anterior del skill, que lo daba por "ya migrado" y lo omitia -- un dominio en este estado esta roto para HTTP (toda request cae en la rama Wolverine de `ProxyTenantResolver`, ver MEF-ADR-0028 "Contexto"), no migrado con exito.
- **Si no contiene ninguno de los tres** (un resolver custom, o una forma no estandar de un dominio anterior a MEF-ADR-0028): **no lo toques**. Repórtalo como pendiente de revision manual -- el limite manual de MEF-ADR-0028 seccion 3 sigue vigente para cualquier forma que no sea una de las tres exactas de arriba.

Para cada dominio a migrar:

**a. `.csproj`** (`src/<RootNamespace>.{PascalCase}/<RootNamespace>.{PascalCase}.csproj`): si no tiene ya una referencia a la biblioteca del paso 9.3, agrega en el `<ItemGroup>` de `ProjectReference`:

```xml
<ProjectReference Include="..\<RootNamespace>.TenantResolver\<RootNamespace>.TenantResolver.csproj" />
```

**b. `Infraestructura/ComposicionServicios{PascalCase}.cs`**:

- Reemplaza el `using` existente (`Cosmos.MultiTenancy` en un dominio de etapa a, o `Cosmos.MultiTenancy.CritterStack` en un dominio del hibrido roto) por el namespace de la biblioteca scaffoldeada:

  ```csharp
  using <RootNamespace>.TenantResolver;
  ```

- Reemplaza la linea de registro (`services.AddScoped<ITenantResolver, TenantResolverMonoTenantPorDefecto>();` o `services.AgregarTenantResolverHibrido();`, segun cual tenia el dominio) -- y el comentario de tenancy que la precede, sea cual sea -- por:

  ```csharp
        // Tenancy (MEF-ADR-0028 etapa b, migrado por /install-apim -- issue #337/#802/#803): resolver real
        // basado en TenantExecutionContext (AsyncLocal + middleware, biblioteca propia del BC en
        // src/<RootNamespace>.TenantResolver/). El mapping claim -> header (user_email -> X-User-Id,
        // tenant_id -> X-Tenant-Id) ya lo normaliza la politica global del gateway APIM (MEF-ADR-0032
        // seccion 4/5) -- esta migracion no deja ningun TODO de mapping de claims por dominio: queda
        // resuelto por construccion (MEF-ADR-0028 seccion 4).
        services.AgregarTenantResolverAsyncLocal();
  ```

  El invariante que debe quedar, sea cual sea el estado de origen del dominio: el `using` en `<RootNamespace>.TenantResolver` y la linea de registro en `services.AgregarTenantResolverAsyncLocal();` -- no que el comentario previo matchee textualmente (mismo criterio que ya aplicaba la version anterior de este skill al fallback CA-7 de `domain-scaffolder`).

- **Solo si el dominio venia del hibrido roto** (tenia `services.AgregarTenantResolverHibrido();`): su `.csproj` tiene ademas un `PackageReference Include="Cosmos.MultiTenancy.CritterStack"` que le agrego la migracion anterior. Ahora que el `using` ya se reemplazo, confirma que el paquete quedo huerfano -- que ningun otro simbolo de `Cosmos.MultiTenancy.CritterStack` sigue en uso en el proyecto:

  ```bash
  grep -rq "Cosmos\.MultiTenancy\.CritterStack" "src/<RootNamespace>.{PascalCase}" --include="*.cs" \
    && echo "SIGUE EN USO (no quites el PackageReference)" \
    || echo "HUERFANO (quitalo)"
  ```

  Si sale `HUERFANO`, quita esa linea `PackageReference` del `.csproj` del dominio (CA-3: "limpiar... el `PackageReference` si queda huerfano"). Si un dominio custom llegara a referenciar ese namespace en otro archivo, deja el paquete -- no es huerfano.

**c. `Program.cs`**: agrega `builder.UsarTenantContextMiddleware();` inmediatamente antes de `await builder.Build().RunAsync();` (sobre el `FunctionsApplicationBuilder`, nunca sobre ningun `app` -- MEF-ADR-0028 seccion 4, referencia [3]). En ambos estados de origen (etapa a o hibrido roto) esta linea falta por completo -- ninguna version anterior de este skill la agregaba -- asi que es siempre una insercion nueva, no un reemplazo. Agrega tambien `using <RootNamespace>.TenantResolver;` en `Program.cs` si no lo tiene ya (verifica con el build del paso f si hace falta).

**d. `.github/workflows/deploy-{kebab}.yml`**: agrega `src/<RootNamespace>.TenantResolver/**` al filtro `on.push.paths`, junto a las rutas de `src/<RootNamespace>.{PascalCase}.DomainEvents/**` y `src/<RootNamespace>.PublicEvents/**` que ya estan ahi (si ya figura, no la dupliques). El paso a acaba de meter esa biblioteca **dentro** del artefacto que este workflow publica: sin la ruta, un cambio posterior a `TenantContextMiddleware`/`TenantExecutionContext` no dispara nada en el push a main y la Function App sigue sirviendo el binario anterior -- exactamente la staleness silenciosa (no una rotura que CI atrape) que documenta `agents/domain-scaffolder.md` para las mismas rutas compartidas del BC (issues #454/#544). El filtro de alcance del job `determinar-alcance` (rama `workflow_run`) del mismo archivo acepta la misma lista: los dos filtros se mueven juntos.

**e. Elimina** `Infraestructura/TenantResolverMonoTenantPorDefecto.cs` de ese dominio, **si existe** (un dominio que venia del hibrido roto ya no lo tiene -- la migracion anterior ya lo habia borrado; esto es normal, no un error).

**f. Gate MEF-ADR-0029 (obligatorio -- "el gate no se relaja"):** corre el test de composicion de ese dominio:

```bash
dotnet test "tests/<RootNamespace>.{PascalCase}.Tests" --filter "FullyQualifiedName~ComposicionContenedorTests"
```

- Si pasa, el dominio queda migrado y construible -- segui con el siguiente.
- Si falla, o `dotnet`/el SDK no estan disponibles para correr el test: **revierte las ediciones a-e de este dominio**. `TenantExecutionContext` no depende de `IHttpContextAccessor` ni de ningun otro servicio registrado -- a diferencia de `ProxyTenantResolver`/`TrustedHeadersTenantResolver`, no hay ningun wiring adicional que probar antes de revertir (el fallback `AddHttpContextAccessor()` de la version anterior de este skill ya no aplica). Los archivos tocados estan tracked en `HEAD` (la eliminacion del paso e, si ocurrio, es solo del working tree, todavia sin commitear -- el commit es el paso 10), asi que `git restore` los devuelve a su estado original sin reconstruir nada a mano:

  ```bash
  git restore "src/<RootNamespace>.{PascalCase}/<RootNamespace>.{PascalCase}.csproj" \
              "src/<RootNamespace>.{PascalCase}/Infraestructura/ComposicionServicios{PascalCase}.cs" \
              "src/<RootNamespace>.{PascalCase}/Program.cs" \
              ".github/workflows/deploy-{kebab}.yml"
  # Solo si el paso e borro el archivo (dominio que venia de la etapa a):
  git restore "src/<RootNamespace>.{PascalCase}/Infraestructura/TenantResolverMonoTenantPorDefecto.cs"
  ```

  y reportalo como "degradado -- migracion manual pendiente para este dominio". **No** dejes un dominio commiteado con el contenedor sin construir (reintroduciria el incidente #318/#207/#538 que MEF-ADR-0028/0029 existen para atrapar). No abortes el resto del batch por un dominio que degrada.

### 10. Commitear la migracion de tenancy

Solo si el paso 9 tuvo al menos un cambio (token flip, scaffold de la biblioteca, o algun dominio migrado):

```bash
git add .claude/harness.config.json
# solo si el paso 9.3 la creo en esta corrida (incluido el <SolutionFile>, que el paso 9.3.g toco):
git add "src/<RootNamespace>.TenantResolver" "tests/<RootNamespace>.TenantResolver.Tests" <SolutionFile>
# por cada dominio migrado con exito (paso 9.4):
git add "src/<RootNamespace>.<PascalCase>/<RootNamespace>.<PascalCase>.csproj" \
        "src/<RootNamespace>.<PascalCase>/Infraestructura/ComposicionServicios<PascalCase>.cs" \
        "src/<RootNamespace>.<PascalCase>/Program.cs" \
        ".github/workflows/deploy-<kebab>.yml"
# si el dominio tenia TenantResolverMonoTenantPorDefecto.cs (etapa a):
git rm "src/<RootNamespace>.<PascalCase>/Infraestructura/TenantResolverMonoTenantPorDefecto.cs"
git commit -m "tenancy(a->b): migrar a TenantExecutionContext (AsyncLocal + middleware) en <lista de dominios migrados> (MEF-ADR-0028 seccion 4, enmendada por el issue #802)"
```

(Commit separado del que ya hizo el agente en el paso 8, en la misma rama.)

### 11. Push + PR unico (CA-5, solo si nada quedo roto)

- **Si el paso 8 termino con `terraform validate` en verde y el paso 9 no dejo ningun dominio degradado**: push + PR unico cubriendo ambos commits.

  ```bash
  git push -u origin "install-apim/${ENV}"
  gh pr create --title "feat(apim): instalar gateway APIM y migrar tenancy a etapa b en <env>" --body "Instala/actualiza el gateway APIM (agente apim-gateway-scaffolder) para <dominios> y ejecuta la transicion a->b de tenancy (MEF-ADR-0028 seccion 4) sobre todos los dominios scaffoldeados. Si este skill lo disparo un issue concreto, agrega aca 'Closes #<numero>'."
  ```

- **Si el agente reporto algun `--domain` omitido** (no scaffoldeado) **o el paso 9 dejo algun dominio degradado**: **no hagas push todavia**. Detente y deja explicito en el reporte (paso 13) que falta reconciliar antes de push+PR -- nunca un PR con un dominio sin construir.

### 12. Emitir el checklist post-deploy (CA-6)

Presentalo tal cual, aclarando que corre **despues** de que CI aplique el PR (MEF-ADR-0022) -- este skill nunca lo ejecuta:

```
Checklist post-deploy (correr una vez que el apply de CI termine, contra el gateway_url real):

  1. OPTIONS sin header Authorization -> CORS responde (200/204, nunca 404).
  2. POST sin token -> 401.
  3. POST con token WorkOS valido -> 202 Accepted, y el request llega a la Function App backend
     (confirmar en App Insights que el request aparece, no solo que APIM respondio -- B2 de
     MEF-ADR-0032, el "acepta y no hace nada" es el bug mas traicionero del catalogo).
  4. En el backend, X-User-Id y X-Tenant-Id llegan no vacios (confirma que el mapping de claims
     esta resolviendo valores reales, no cadenas vacias por un claim mal nombrado -- B10 de
     MEF-ADR-0032).
  5. QUERY con token valido y Content-Type: application/json -> llega a la Function App (ni 404 ni
     405 en el borde). Gate empirico del verbo QUERY (issue #608): cierra el punto NO VERIFICADO
     "APIM Consumption reenviando QUERY end-to-end" de MEF-ADR-0042 seccion 6 -- correrlo antes de
     exponer el primer endpoint QUERY real detras del gateway.
  6. Si un request con token valido responde 404 (ni 401 ni 400), la causa no es CORS (B3) ni el
     <backend> vacio (B2): es la operacion faltante -- B11 de MEF-ADR-0032. Confirmar que la
     azurerm_api_management_api del dominio tiene al menos una azurerm_api_management_api_operation
     que matchee el metodo del request (el modulo genera la wildcard por verbo automaticamente,
     incluido QUERY).
```

### 13. Reportar

Resumen claro y en orden:

- **Prerequisitos** (paso 2): verificados.
- **`WORKOS_CLIENT_ID`/`CORS_ALLOWED_ORIGINS`** (pasos 6-7): resueltos, registrados, o `NO VERIFICADO`.
- **Servidores MCP detectados** (paso 2b, issue #820): lista de `SERVIDORES_MCP` (o "ninguno" -- CA-5); si vino al menos uno, `WORKOS_AUTHORIZATION_SERVER_URL` (paso 7b): resuelta, registrada, o el bloqueo si faltaba y no vino `--authorization-server-url`.
- **Agente `apim-gateway-scaffolder`** (paso 8): modulos creados/omitidos, dominios agregados/omitidos (con el motivo si alguno fallo el guard de scaffold), resultado de `terraform validate`, gates B5/B10 pendientes que el agente haya reportado, y el delta manual de CORS (`<method>QUERY</method>` ausente en un modulo `api-management` preexistente, issue #608) si el agente lo reporto.
- **Servidores MCP expuestos** (paso 8, issue #820), si `SERVIDORES_MCP` no vino vacia: `apim-mcp-api`/`apim-mcp-prm.tf` creados u omitidos; `apim-mcp-{proposito-kebab}.tf` por servidor, creado u omitido; cualquier servidor MCP que fallo el guard de scaffold del agente (indicar `/scaffold-mcp <Proposito>`); si el patch de `Mcp__ResourceUri`/`Mcp__AuthorizationServer` en `mcp-{proposito-kebab}.tf` se aplico o ya estaba resuelto (CA-4); gate B12 (dominio AuthKit del entorno) marcado `NO VERIFICADO` si el agente no pudo confirmarlo contra el discovery doc en vivo; si algun servidor MCP detectado todavia no tuvo su primer deploy de codigo exitoso (el `apply` de su modulo fallaria al leer `mcp_extension` -- avisa antes de mergear el PR).
- **Checklist operativo CA-4, por cada servidor MCP expuesto**: el `resource_uri` resuelto y el recordatorio de confirmar en el dashboard de WorkOS que el Resource Indicator del cliente MCP es ese mismo string byte a byte (trailing slash incluido), y de reconectar cualquier cliente MCP ya conectado despues del `apply`.
- **Migracion de tenancy** (paso 9): token flip (hecho / ya estaba en etapa b); biblioteca `src/<RootNamespace>.TenantResolver/` (creada y verificada por build+test / ya existia); lista de dominios migrados (distinguiendo si venian de la etapa (a) mono-tenant o del hibrido roto `AgregarTenantResolverHibrido()`, issue #802); lista de dominios ya migrados al patron nuevo (omitidos); lista de dominios degradados (con el motivo) o con resolver custom (revision manual pendiente).
- **Siguiente paso**: push + PR (si todo quedo verde) o la lista de reconciliacion pendiente.
- **Checklist post-deploy** (paso 12): recordatorio de correrlo tras el `apply` de CI.

## Reglas

- **Nunca ejecutes `terraform plan` ni `terraform apply`.** El `apply` real corre en CI al mergear el PR (MEF-ADR-0022); este skill (via el agente del paso 8) solo llega hasta `fmt`/`validate`.
- **Nunca crees el/los dominio(s) destino ni ningun servidor MCP.** Si un `--domain` o un servidor MCP detectado en el paso 2b no esta scaffoldeado, el agente del paso 8 lo omite y lo reporta -- indica `/scaffold <dominio>` o `/scaffold-mcp <Proposito>` en el reporte final, no lo crees vos.
- **Un BC sin servidores MCP corre este skill identico a como corria antes del issue #820** (CA-5): el paso 2b detecta la lista vacia, el paso 7b se omite entero, y el agente del paso 8 nunca genera `infra/modules/apim-mcp-api/` ni toca `providers.tf`.
- **Nunca pidas ni imprimas el valor de `WORKOS_API_KEY`** ni de ningun otro secreto, incluida `WORKOS_AUTHORIZATION_SERVER_URL` -- esta ultima es un dominio publico, no una credencial, pero sigue el mismo tratamiento no-secreto que `WORKOS_CLIENT_ID`/`CORS_ALLOWED_ORIGINS` (GitHub **variable**, nunca secret).
- **Nunca migres un dominio fuera de los descubiertos en el paso 9.4** (todo `src/<RootNamespace>.*/Infraestructura/ComposicionServicios*.cs`) -- la migracion aplica a **todo** el BC, no solo a los `--domain` de esta corrida, pero nunca a una forma de registro que no sea exactamente la mono-tenant transitoria de MEF-ADR-0028 seccion 2 o el hibrido roto `AgregarTenantResolverHibrido()` que esta migracion reemplaza (issue #802) -- un resolver custom sigue siendo revision manual, nunca auto-migrado.
- **Nunca dejes un dominio commiteado con el contenedor DI sin construir** (gate MEF-ADR-0029): `TenantExecutionContext` no depende de `IHttpContextAccessor` ni de ningun otro servicio registrado -- si el test de composicion no pasa, revierte ese dominio completo antes de commitear (ya no hay ningun wiring adicional que probar primero).
- **Nunca migres ni referencies un dominio contra la biblioteca `src/<RootNamespace>.TenantResolver/` sin que el paso 9.3 la haya compilado y testeado en verde** -- una biblioteca sin verificar rompe la compilacion de todo dominio que la referencie.
- **Nunca dupliques** un `PackageReference`, un `using`, o un registro de `ITenantResolver` ya presente -- verifica antes de escribir (mismo criterio de idempotencia que el resto del harness).
- **Nunca trabajes contra `main` directo.** Crea la rama compartida del paso 4 antes de invocar el agente o de tocar cualquier archivo.
- **Nunca hagas push si el agente omitio un dominio pedido o si algun dominio quedo degradado** en la migracion de tenancy (paso 11) -- deja la reconciliacion pendiente explicita en el reporte.
- Si `$ARGUMENTS` no trae al menos un `--domain`, responde con el uso exacto y detente -- no adivines dominios.
- Si es la primera instalacion del gateway (`apim.tf` ausente) y falta `--cors-origin`, responde con el uso exacto y detente -- no inventes origenes.
- Si el paso 2b detecto al menos un servidor MCP y `WORKOS_AUTHORIZATION_SERVER_URL` no existe ni vino `--authorization-server-url`, responde con el uso exacto y detente -- no inventes ni adivines el dominio AuthKit del entorno.
