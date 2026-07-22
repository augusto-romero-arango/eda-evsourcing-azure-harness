---
model: sonnet
---

Instala/actualiza el gateway APIM (Azure API Management) delante de las Function Apps del BC, fiel a MEF-ADR-0032: invoca el agente `apim-gateway-scaffolder` (issue #335) para generar/actualizar los modulos Terraform `api-management`/`apim-function-api` de forma aditiva por dominio, cablea `TF_VAR_workos_client_id` desde la GitHub variable `WORKOS_CLIENT_ID` (la que registro `/install-workos`), y ejecuta la **transicion a->b de tenancy** (MEF-ADR-0028 seccion 4, issue #337): flip de `tenancy.strategy` a `"multi-tenant-header"` y migracion del `ITenantResolver` de **todos** los dominios ya scaffoldeados del BC a `AgregarTenantResolverHibrido()`. Es la capa de **borde** de la auth (segunda tras `/install-workos`): APIM se monta delante de Function Apps existentes, asi que exige infra base + al menos un dominio ya scaffoldeado. Comunicate en **espanol**.

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
--domain <Dominio> [--domain <Dominio2> ...] [--env <env>] [--cors-origin <origin> ...]
```

- **`--domain <Dominio>`** (obligatorio, repetible): uno o mas dominios **ya scaffoldeados** (`/scaffold`) a exponer detras del gateway. Acepta kebab o PascalCase. Podes correr este skill varias veces agregando dominios nuevos cada vez (CA-2, aditivo) sin re-crear la instancia.
- **`--env <env>`** (opcional, default `dev`): ambiente Terraform.
- **`--cors-origin <origin>`** (repetible): origen del SPA para el preflight CORS (B3, MEF-ADR-0032). **Obligatorio solo la primera vez** que se instala el gateway en este entorno (cuando `apim.tf` todavia no existe); en corridas posteriores se ignora -- agregar un origen a un gateway ya instalado es cambiar el valor de la GitHub variable `CORS_ALLOWED_ORIGINS` (fuera del alcance de este skill, se hace con `gh variable set CORS_ALLOWED_ORIGINS`).

Si falta `--domain`, responde con el uso exacto y detente sin ejecutar nada.

## Nombres fijos de este skill (no configurables)

| Artefacto | Nombre | Por que |
|---|---|---|
| GitHub **variable** (client_id de login) | `WORKOS_CLIENT_ID` | Ya la registro `/install-workos` (MEF-ADR-0032 seccion 6/7); este skill solo la **lee/verifica**, nunca la crea desde cero. |
| GitHub **variable** (origenes CORS) | `CORS_ALLOWED_ORIGINS` | JSON list; requerida sin default por `apim.tf` (`var.cors_allowed_origins`), solo la primera vez que se crea el archivo (`agents/apim-gateway-scaffolder.md` Paso 3b). |
| Token en `harness.config.json` | `tenancy.strategy = "multi-tenant-header"` | Flip que ejecuta CA-4 (MEF-ADR-0028 seccion 4). |
| Registro de `ITenantResolver` que reemplaza el transitorio | `services.AgregarTenantResolverHibrido()` | Extension de `Cosmos.MultiTenancy.CritterStack` (MEF-ADR-0028 seccion "Contexto"). |

## Proceso

### 1. Parsear `$ARGUMENTS`

Extrae la lista de `DOMINIOS` (uno o mas `--domain`), `ENV` (default `dev`) y la lista de `CORS_ORIGINS` (`--cors-origin`, puede venir vacia). Si no hay ningun `--domain`, responde con el uso exacto y detente.

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

### 3. Confirmar con el usuario

Muestra exactamente lo que va a pasar y pide confirmacion explicita -- este skill escribe Terraform, GitHub variables, y **reescribe codigo C# existente** en todos los dominios del BC (la migracion de tenancy, no solo en los dominios pasados por `--domain`):

```
Se va a instalar/actualizar el gateway APIM en el entorno "<env>" para: <lista de dominios>

  1. Modulos Terraform api-management/apim-function-api (agente apim-gateway-scaffolder, issue #335),
     aditivo por dominio -- nunca re-crea la instancia si ya existe.
  2. Cableado de TF_VAR_workos_client_id (y TF_VAR_cors_allowed_origins la primera vez) en infra-cd.yml.
  3. TRANSICION DE TENANCY (a)->(b) (MEF-ADR-0028 seccion 4): flip de tenancy.strategy a
     "multi-tenant-header" + migracion del ITenantResolver de TODOS los dominios ya scaffoldeados
     del BC (no solo los de arriba) a AgregarTenantResolverHibrido(), eliminando
     TenantResolverMonoTenantPorDefecto.cs de cada uno. Cada dominio migrado se valida con su propio
     test de composicion del contenedor (MEF-ADR-0029) antes de commitear.

El apply real (el que provisiona APIM en Azure) corre en CI al mergear el PR (MEF-ADR-0022); este
skill nunca ejecuta terraform plan/apply. El checklist post-deploy (CORS, 401, 202, headers de
identidad) queda pendiente para despues de ese apply.

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

### 8. Invocar el agente `apim-gateway-scaffolder` (CA-2, CA-3)

```bash
claude --agent apim-gateway-scaffolder "Instala/actualiza el gateway APIM en el entorno <env> para los dominios: <lista de --domain, separados por coma>. WorkOS client_id: <WORKOS_CLIENT_ID resuelto, o 'NO VERIFICADO' si vacio>. CORS allowed origins: <lista de --cors-origin, o 'gateway ya instalado, no recrear cors_allowed_origins' si GATEWAY_EXISTE=true>."
```

El agente es aditivo/idempotente por su cuenta (sus Pasos 0.2/1/2/3/4): si algun `--domain` no esta scaffoldeado, lo omite y lo reporta sin abortar el resto del batch -- reflejalo en el reporte final (paso 13). Tambien cablea `TF_VAR_workos_client_id`/`TF_VAR_cors_allowed_origins` en `infra-cd.yml` (su Paso 3b -- esto **es** el CA-3 de este issue, ya resuelto por el agente) y corre `fmt`/`init -backend=false`/`validate` (su Paso 5) antes de commitear (su Paso 6, en la rama que ya creaste en el paso 4).

### 9. Ejecutar la transicion a->b de tenancy (CA-4, MEF-ADR-0028 seccion 4)

#### 9.1 Resolver `<RootNamespace>`

Lee el `CLAUDE.md` raiz del proyecto consumidor (contrato, seccion "Tokens del harness") para resolver `<RootNamespace>`. Si no esta declarado, detente y pide al usuario que lo declare -- mismo criterio que `domain-scaffolder`.

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

#### 9.3 Migrar el resolver de cada dominio ya scaffoldeado

Descubre **todos** los dominios del BC, no solo los pasados por `--domain` -- MEF-ADR-0028 seccion 4 exige migrar todos los ya scaffoldeados:

```bash
ls src/<RootNamespace>.*/Infraestructura/ComposicionServicios*.cs 2>/dev/null
```

Por cada archivo encontrado (dominio `{PascalCase}`, proyecto `src/<RootNamespace>.{PascalCase}/`):

- **Si ya contiene `AgregarTenantResolverHibrido()`**: ya migrado (scaffoldeado directo en etapa b, o migrado en una corrida previa de este skill). Omite y reporta.
- **Si contiene exactamente `services.AddScoped<ITenantResolver, TenantResolverMonoTenantPorDefecto>();`** (el registro que emite `domain-scaffolder`, MEF-ADR-0028 seccion 2): migralo (pasos siguientes).
- **Si no contiene ninguno de los dos** (un resolver custom, o una forma no estandar de un dominio anterior a MEF-ADR-0028): **no lo toques**. Repórtalo como pendiente de revision manual -- el limite manual de MEF-ADR-0028 seccion 3 sigue vigente para cualquier forma que no sea la exacta de la seccion 2.

Para cada dominio a migrar:

**a. `.csproj`** (`src/<RootNamespace>.{PascalCase}/<RootNamespace>.{PascalCase}.csproj`): si no tiene ya una referencia a `Cosmos.MultiTenancy.CritterStack`, agrega en el mismo `<ItemGroup>` de paquetes `Cosmos.*`:

```xml
<PackageReference Include="Cosmos.MultiTenancy.CritterStack" Version="2.1.0" />
```

(mismo lockstep de version `2.1.0` que el resto del stack `Cosmos.Event*`, MEF-ADR-0003. **No** agregues `Cosmos.MultiTenancy` explicito -- ya es transitivo via `Cosmos.EventSourcing.CritterStack`.)

**b. `Infraestructura/ComposicionServicios{PascalCase}.cs`**: reemplaza el using

```csharp
using Cosmos.MultiTenancy;
```

por

```csharp
using Cosmos.MultiTenancy.CritterStack;
```

y reemplaza el bloque

```csharp
        // Tenancy (MEF-ADR-0028): etapa (a), mono-tenant transitorio por defecto mientras el proyecto no
        // tiene autenticacion que produzca un TenantContext. Reemplazar por el resolver real (header-based /
        // hibrido de Cosmos.MultiTenancy.CritterStack) cuando esa autenticacion exista -- ver el TODO
        // en Infraestructura/TenantResolverMonoTenantPorDefecto.cs.
        services.AddScoped<ITenantResolver, TenantResolverMonoTenantPorDefecto>();
```

por

```csharp
        // Tenancy (MEF-ADR-0028 etapa b, migrado por /install-apim -- issue #337/#340): resolver real
        // basado en TenantContext (header-based via HttpContext, o WolverineMessageContextTenantResolver
        // dentro de handlers de Wolverine sin HttpContext). El mapping claim -> header (user_email ->
        // X-User-Id, tenant_id -> X-Tenant-Id) ya lo normaliza la politica global del gateway APIM
        // (MEF-ADR-0032 seccion 4/5) -- a diferencia del auto-cableo generico de domain-scaffolder,
        // esta migracion NO deja ningun TODO de mapping de claims por dominio: queda resuelto por
        // construccion (MEF-ADR-0028 seccion 4).
        services.AgregarTenantResolverHibrido();
```

El bloque de comentario de 4 lineas de arriba es el que emite `domain-scaffolder` en etapa (a) (el caso normal del flujo greenfield -> `/scaffold` -> `/install-apim`). Un dominio scaffoldeado **directo** en etapa (b) que degrado al fallback CA-7 de `domain-scaffolder` (ver `agents/domain-scaffolder.md`, "El fallback CA-7 tambien debe dejar el contenedor construible") lleva la **misma** linea `services.AddScoped<ITenantResolver, TenantResolverMonoTenantPorDefecto>();` -- la que dispara la deteccion del paso 9.3 -- pero bajo un comentario distinto. En ese caso reemplaza igual la linea de registro (y el comentario de tenancy que la precede, sea cual sea): el invariante que debe quedar es que `AddScoped<ITenantResolver, TenantResolverMonoTenantPorDefecto>()` pase a `services.AgregarTenantResolverHibrido()` y el `using` quede en `Cosmos.MultiTenancy.CritterStack` -- no que el comentario previo matchee textualmente.

**c. Elimina** `Infraestructura/TenantResolverMonoTenantPorDefecto.cs` de ese dominio -- ya no lo referencia nadie.

**d. Gate MEF-ADR-0029 (obligatorio -- "el gate no se relaja"):** corre el test de composicion de ese dominio:

```bash
dotnet test "tests/<RootNamespace>.{PascalCase}.Tests" --filter "FullyQualifiedName~ComposicionContenedorTests"
```

- Si pasa, el dominio queda migrado y construible -- segui con el siguiente.
- Si falla porque `ProxyTenantResolver`/`TrustedHeadersTenantResolver` exige una dependencia no registrada (tipicamente `IHttpContextAccessor`, ver `agents/domain-scaffolder.md` seccion CA-6), agrega `services.AddHttpContextAccessor();` en `AgregarServicios{PascalCase}` (junto al resto de registros de infraestructura) y vuelve a correr el test.
- Si sigue fallando, o `dotnet`/el SDK no estan disponibles para correr el test: **revierte las ediciones a-c de este dominio**. Los tres archivos estan tracked en `HEAD` (la eliminacion del paso c es solo del working tree, todavia sin commitear -- el commit es el paso 10), asi que `git restore` los devuelve a su estado original sin reconstruir nada a mano -- incluido `TenantResolverMonoTenantPorDefecto.cs`, que vuelve tal cual estaba:

  ```bash
  git restore "src/<RootNamespace>.{PascalCase}/<RootNamespace>.{PascalCase}.csproj" \
              "src/<RootNamespace>.{PascalCase}/Infraestructura/ComposicionServicios{PascalCase}.cs" \
              "src/<RootNamespace>.{PascalCase}/Infraestructura/TenantResolverMonoTenantPorDefecto.cs"
  ```

  y reportalo como "degradado -- migracion manual pendiente para este dominio". **No** dejes un dominio commiteado con el contenedor sin construir (reintroduciria el incidente #318/#207 que MEF-ADR-0028/0029 existen para atrapar). No abortes el resto del batch por un dominio que degrada.

### 10. Commitear la migracion de tenancy

Solo si el paso 9 tuvo al menos un cambio (token flip o algun dominio migrado):

```bash
git add .claude/harness.config.json
# por cada dominio migrado con exito (paso 9.3):
git add "src/<RootNamespace>.<PascalCase>/<RootNamespace>.<PascalCase>.csproj" \
        "src/<RootNamespace>.<PascalCase>/Infraestructura/ComposicionServicios<PascalCase>.cs"
git rm "src/<RootNamespace>.<PascalCase>/Infraestructura/TenantResolverMonoTenantPorDefecto.cs"
git commit -m "tenancy(a->b): migrar a AgregarTenantResolverHibrido() en <lista de dominios migrados> (MEF-ADR-0028 seccion 4)"
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
```

### 13. Reportar

Resumen claro y en orden:

- **Prerequisitos** (paso 2): verificados.
- **`WORKOS_CLIENT_ID`/`CORS_ALLOWED_ORIGINS`** (pasos 6-7): resueltos, registrados, o `NO VERIFICADO`.
- **Agente `apim-gateway-scaffolder`** (paso 8): modulos creados/omitidos, dominios agregados/omitidos (con el motivo si alguno fallo el guard de scaffold), resultado de `terraform validate`, gates B5/B10 pendientes que el agente haya reportado.
- **Migracion de tenancy** (paso 9): token flip (hecho / ya estaba en etapa b), lista de dominios migrados, lista de dominios ya migrados (omitidos), lista de dominios degradados (con el motivo) o con resolver custom (revision manual pendiente).
- **Siguiente paso**: push + PR (si todo quedo verde) o la lista de reconciliacion pendiente.
- **Checklist post-deploy** (paso 12): recordatorio de correrlo tras el `apply` de CI.

## Reglas

- **Nunca ejecutes `terraform plan` ni `terraform apply`.** El `apply` real corre en CI al mergear el PR (MEF-ADR-0022); este skill (via el agente del paso 8) solo llega hasta `fmt`/`validate`.
- **Nunca crees el/los dominio(s) destino.** Si un `--domain` no esta scaffoldeado, el agente del paso 8 lo omite y lo reporta -- indica `/scaffold <dominio>` en el reporte final, no lo crees vos.
- **Nunca migres un dominio fuera de los descubiertos en el paso 9.3** (todo `src/<RootNamespace>.*/Infraestructura/ComposicionServicios*.cs`) -- la migracion aplica a **todo** el BC, no solo a los `--domain` de esta corrida, pero nunca a una forma de registro que no sea exactamente la de MEF-ADR-0028 seccion 2 (resolver custom = revision manual, nunca auto-migrado).
- **Nunca dejes un dominio commiteado con el contenedor DI sin construir** (gate MEF-ADR-0029): si el test de composicion no pasa tras el intento de `AddHttpContextAccessor()`, revierte ese dominio completo antes de commitear.
- **Nunca dupliques** un `PackageReference`, un `using`, o un registro de `ITenantResolver` ya presente -- verifica antes de escribir (mismo criterio de idempotencia que el resto del harness).
- **Nunca pidas ni imprimas el valor de `WORKOS_API_KEY`** ni de ningun otro secreto -- este skill solo lee la GitHub **variable** `WORKOS_CLIENT_ID` (no secreta, MEF-ADR-0032 seccion 6/7) y registra `CORS_ALLOWED_ORIGINS` (tampoco secreta).
- **Nunca trabajes contra `main` directo.** Crea la rama compartida del paso 4 antes de invocar el agente o de tocar cualquier archivo.
- **Nunca hagas push si el agente omitio un dominio pedido o si algun dominio quedo degradado** en la migracion de tenancy (paso 11) -- deja la reconciliacion pendiente explicita en el reporte.
- Si `$ARGUMENTS` no trae al menos un `--domain`, responde con el uso exacto y detente -- no adivines dominios.
- Si es la primera instalacion del gateway (`apim.tf` ausente) y falta `--cors-origin`, responde con el uso exacto y detente -- no inventes origenes.
