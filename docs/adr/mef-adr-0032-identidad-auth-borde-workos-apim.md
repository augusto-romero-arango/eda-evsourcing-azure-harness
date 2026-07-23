# MEF-ADR-0032: Identidad y autenticacion en el borde -- WorkOS AuthKit + Azure API Management

- **Fecha**: 2026-07-22
- **Estado**: aceptado
- **Aplica a**: doctrina de identidad, autenticacion y autorizacion en el borde del marco. Es el **ancla** del agente `apim-gateway-scaffolder` (issue #335, generador del modulo APIM) y de la familia de skills `/install-workos` (issue #339, implementado), `/install-apim` (issue #340, implementado) y `/install-auth` (issue #342, implementado: orquesta a los dos anteriores con un gate humano en medio). Cross-referencia MEF-ADR-0025 (custodia de secretos), MEF-ADR-0028 (estrategia de tenancy, materializa la etapa b), MEF-ADR-0022 (autenticacion de CI por OIDC), MEF-ADR-0021 (infraestructura base), MEF-ADR-0020 (hosting de Functions) y MEF-ADR-0030 (esquema de numeracion de ADRs).

## Contexto

En **Cosmos.ControlPlane** (consumidor real del marco) se implemento identidad, autenticacion y autorizacion con **WorkOS** (Identity Provider, SDK `WorkOS.net`) como proveedor y **Azure API Management** (tier Consumption) como **front door unico** delante de las Function Apps: APIM valida el JWT de WorkOS AuthKit en el borde (politica `validate-jwt`) y reenvia el request a la funcion correspondiente, inyectando la host key -- las funciones quedan `AuthorizationLevel.Function`, **sin ningun cambio de codigo**. El patron quedo documentado localmente en ese consumidor como `ADR-0027` ("Propuesto", sin el prefijo del esquema del marco -- ver MEF-ADR-0030), y referencia los PRs `#96`-`#100` (modulos `api-management`/`apim-function-api`) y `#103`/`#104` (propagacion claim->header) del repo `Cosmos-SincoERP/Cosmos.ControlPlane`.

Llegar a ese patron funcionando le costo a ControlPlane **~5 PRs y varios `apply` rotos** por trampas de APIM/Terraform no obvias: politicas que compilan pero responden `400 ValidationError` sin decir por que, un `<backend>` vacio que acepta el request con `200 OK` y **nunca** lo reenvia al backend, un preflight CORS que el navegador bloquea aunque `curl` funcione, un IdP que no emite el claim `aud` que casi todo tutorial de `validate-jwt` asume, y un header de identidad que sale vacio porque el nombre del claim se adivino en vez de confirmarse. Ese catalogo -- con sintoma, causa raiz y fix -- se documento en el issue #335 (que ahora se acota al agente que genera el HCL) y **este ADR lo absorbe como doctrina del marco**.

Un grep del harness (`agents/`, `commands/`, `scripts/`, `docs/adr/`) por `workos`, `apim`, `api-management` y `authkit` confirma **cero** referencias: Mefisto hoy no tiene ninguna doctrina de identidad/autenticacion en el borde, ni de IdPs de terceros. Sin un ADR que fije el patron, la eleccion de IdP, la forma de validacion en el borde y el catalogo de trampas verificadas, no hay contra que agente ni skill de auth puedan diseñarse -- de ahi que este issue **bloquee** al agente APIM (#335) y a toda la familia `/install-*` de auth.

**Fuente de verdad**: el codigo funcionando en ControlPlane (`src/Cosmos.ControlPlane.UserManagement/Identity/*`, `infra/modules/api-management/main.tf`, `infra/environments/dev/main.tf`), por encima de cualquier documentacion -- varias de las trampas de la seccion 3 no estan confirmadas (o estan confirmadas de forma ambigua) en la documentacion publica de WorkOS, y solo se cerraron decodificando un token real emitido en produccion.

## Decision

### 1. WorkOS AuthKit (OIDC) como IdP de referencia; Azure API Management Consumption como front door unico

El marco adopta **WorkOS AuthKit** [1][2] como Identity Provider de referencia: emite tokens OIDC (JWT) via un flujo de autenticacion hospedado, sin que el marco tenga que implementar su propio almacen de credenciales. **Azure API Management, tier `Consumption` (`sku_name = "Consumption_0"`)**, es el **unico** punto de entrada publico delante de las Function Apps de un Bounded Context: valida el JWT en el borde (politica `validate-jwt` [3]) y reenvia el request ya autenticado al backend.

La politica `validate-jwt` esta disponible en **todos** los tiers de APIM, incluido `Consumption` (gateways `classic, v2, consumption, self-hosted, workspace` [3]), y el tier Consumption provisiona en minutos, sin exigir capacidad reservada. La contrapartida -- sin VNet, sin `rate-limit-by-key` (no soportado en Consumption, confirmado en la guia oficial de APIM + Azure AD B2C para SPAs [4]), sin Log Analytics de requests -- se acepta para el caso de uso del marco (backend serverless de bajo/medio volumen); ver "Consecuencias".

El nombre de la instancia APIM es **unico en todo Azure** (expone `<name>.azure-api.net`): el modulo que la genere debe sufijarlo con `random_string` para evitar colisiones entre BCs de distintos consumidores.

### 2. El JWT se valida en el borde; las Function Apps no cambian codigo

Las Function Apps del BC permanecen en `AuthorizationLevel.Function`: nunca implementan su propio middleware de validacion de JWT. APIM inyecta la host key de cada Function App como header `x-functions-key` al reenviar el request ya validado (recurso `data.azurerm_function_app_host_keys` [5], que expone `default_function_key` -- data source estable del provider `azurerm` desde la version `2.27.0` [6]). Este es el patron que absorbe el issue #335: un modulo `apim-function-api` por dominio, `subscription_required = false` (la puerta de acceso es el JWT, no una subscription key de APIM), con `<base/>` + `set-backend-service` en su politica (a diferencia de la politica global, ver B1).

**Por que centralizar la validacion en el borde y no en cada Function App** (en vez de repetir un middleware de validacion de JWT en cada dominio del BC): una sola superficie de configuracion (una politica, un `openid-config`), un solo lugar donde auditar el catalogo de trampas de la seccion 3, y el backend queda desacoplado del IdP concreto -- cambiar de WorkOS a otro IdP OIDC-compliant es, en principio, un cambio de politica APIM, no un redeploy de N Function Apps.

### 3. Catalogo de trampas verificadas de APIM/Terraform (B1-B10)

Cada punto de este catalogo es una decision verificable con sintoma/causa/fix, extraida del incidente real en ControlPlane (issue #335). Un agente o desarrollador que reproduzca el patron debe tratar cada item como un gate, no como una nota informativa.

**B1. `<base/>` prohibido en la politica de scope GLOBAL.** En el scope global no hay politica padre: la documentacion oficial confirma que *"a globally scoped policy has no parent scope, and using the `base` element in it has no effect"* [7]. ControlPlane observo ademas un `400 ValidationError` (`target: "base"`) al intentar aplicar `<base/>` en global via el provider `azurerm` -- un comportamiento mas estricto que "sin efecto" que documenta el editor de politicas del portal. **Fix**: la politica global nunca lleva `<base/>` en ninguna seccion; `<base/>` solo va en politicas **por-API**, que si heredan de la global.

**B2. `<backend>` global vacio responde `200` sin reenviar nada al backend.** Al vaciar las secciones de la politica global para quitar los `<base/>` (B1), la seccion `<backend>` tambien quedo vacia. Sin `<forward-request/>`, APIM acepta el request y responde `200 OK`/`Content-Length: 0` **sin llamar al backend** -- ningun request llega a la Function App (confirmado por ausencia total de requests en Application Insights). Es el bug mas traicionero del catalogo: el gateway "acepta y no hace nada". **Fix**: la seccion `<backend>` de la politica global **debe** contener `<forward-request/>`. Lo prohibido en global es `<base/>` (B1), no `<forward-request/>`; `outbound`/`on-error` si pueden quedar vacias.

**B3. Sin `<cors>` antes de `<validate-jwt>`, el preflight del navegador nunca llega.** Un SPA cross-origin dispara un preflight `OPTIONS` sin header `Authorization`; si `<validate-jwt>` lo intercepta primero, lo rechaza con 401 (o, sin ninguna politica CORS, el navegador ve `404 Resource Not Found` y bloquea la llamada real). La documentacion oficial de la politica `cors` confirma que *"only the `cors` policy is evaluated on the `OPTIONS` request during preflight"* [8] -- es decir, `cors` debe ser la primera politica en `<inbound>`, antes de `<validate-jwt>`, para que APIM responda el preflight automaticamente. **Fix**: `<cors>` primero en `<inbound>` de la politica global, listando el/los `<origin>` del front; para tokens Bearer no hace falta `allow-credentials`.

**B4. IdP sin claim `aud` (caso WorkOS AuthKit).** Los access tokens que ControlPlane decodifico de WorkOS AuthKit no emiten `aud`. La documentacion publica generica de OIDC de WorkOS si documenta un claim `aud` en el contexto de **WorkOS Connect** (conexiones OIDC empresariales) [9], pero **no** confirma su presencia en los access tokens que emite la propia AuthKit del proyecto (login primario) -- discrepancia que solo se resuelve decodificando un token real (ver seccion 8, "NO VERIFICADO"). **Fix**: no usar `<audiences>`; validar la "audiencia" con `<required-claims>` sobre el claim `client_id`, verificado presente en el token real.

**B5. El issuer real no es el "obvio".** ControlPlane confirmo -- via el discovery doc en vivo -- que el issuer de su proyecto AuthKit es la variante **client-specific** `https://api.workos.com/user_management/{client_id}`, no `https://api.workos.com` a secas. **Fix**: nunca asumir el issuer; leer `GET https://api.workos.com/user_management/{client_id}/.well-known/openid-configuration` y copiar el campo `issuer` (y `jwks_uri`) literal de la respuesta -- mismo principio de "leer el discovery doc en vivo" que exige la doctrina general de OIDC (`issuer`, la URL del emisor, es parte de los metadatos que expone el discovery endpoint [10]).

**B6. `validate-jwt`: orden estricto de elementos, sin comentarios XML interpuestos.** La referencia oficial de la politica es explicita: *"set the policy's elements and child elements in the order provided in the policy statement"* [3] -- `openid-config` -> `issuers`/`audiences` -> `required-claims`, sin excepcion, y sin `<!-- -->` interpuestos entre esos hijos (el schema los trata como ruptura del orden). **Fix**: respetar el orden documentado; cualquier nota va en comentarios **HCL** (`#`), nunca dentro del `xml_content`.

**B7. El `400` de `azurerm` es generico/truncado -- diagnostico.** Terraform reporta `ValidationError: One or more fields contain incorrect values:` sin decir que campo. **Fix de diagnostico**: reproducir el `PUT` de la politica directo con `az rest --method put --url ".../policies/policy?api-version=2022-08-01" --body @body.json` -- la respuesta de `az` si trae `error.details[].target`/`.message` con el elemento exacto que falla.

**B8. Wiring del backend y la host key.** `data.azurerm_function_app_host_keys` expone `default_function_key` [5][6]. Se inyecta como header con `credentials { header = { "x-functions-key" = "{{<named_value>}}" } }` (`header` es `map(string)`, no un bloque; el named value se referencia con `{{...}}`), y la key se guarda en `azurerm_api_management_named_value` con `secret = true` -- nunca en texto plano (ver seccion 7 / MEF-ADR-0025).

**B9. Limites del tier Consumption y otras notas operativas.** Sin `rate-limit-by-key`, sin VNet, sin IP estatica ni Log Analytics de requests (si App Insights) -- confirmado en la guia oficial de APIM + Azure AD B2C para SPAs, que instruye retirar `rate-limit-by-key` explicitamente cuando el tier es Consumption [4]. Runs de Terraform solapados (plan de PR + apply de main) pueden chocar con `Error acquiring the state lock` -- no es un bug del HCL, es reintentable. Propiedad obsoleta a evitar en HCL nuevo: `enable_rbac_authorization` -> `rbac_authorization_enabled` (se elimina en v5 del provider `azurerm`).

**B10. Claims a headers: el nombre del claim no se adivina, y exige anti-spoofing.** Ver seccion 4 (decision dedicada, por ser ademas el insight que conecta con MEF-ADR-0028).

### 4. Propagacion de identidad: claim -> header canonico, con anti-spoofing

En la **misma politica global**, dentro de `<inbound>` y **despues** de `<validate-jwt>` (que debe declarar `output-token-variable-name="jwt"` para dejar el token ya validado como objeto `Jwt` en `context.Variables["jwt"]`), la politica agrega un `set-header` por claim que el backend necesita sin volver a parsear el token:

```xml
<set-header name="X-User-Id" exists-action="override">
  <value>@(((Jwt)context.Variables["jwt"]).Claims.GetValueOrDefault("user_email", ""))</value>
</set-header>
<set-header name="X-Tenant-Id" exists-action="override">
  <value>@(((Jwt)context.Variables["jwt"]).Claims.GetValueOrDefault("tenant_id", ""))</value>
</set-header>
```

- **Mapeo canonico confirmado en ControlPlane decodificando un token real**: el claim del correo es `user_email` (no `email`, que fue el nombre adivinado y produjo un header vacio via `GetValueOrDefault`), el claim del tenant es `tenant_id`.
- **`exists-action="override"` es obligatorio, no cosmetico**: es el mecanismo **anti-spoofing** del patron. Sin `override`, un cliente que manda su propio header `X-User-Id`/`X-Tenant-Id` en el request lo hace pasar intacto hasta el backend, suplantando identidad; con `override`, el gateway **siempre** pisa cualquier header homonimo entrante con el valor derivado del JWT ya validado. El patron `set-header` + `exists-action="override"` para propagar datos de contexto al backend esta documentado oficialmente [11]. Si el claim falta en el token, el header sale cadena vacia -- no se aborta la peticion (comportamiento deliberado: la ausencia de un claim opcional no es motivo de bloqueo en el borde).
- **Orden**: va en `inbound`, despues de `<validate-jwt>` (necesita el token ya validado) y en la politica **global** (para que el header viaje al backend por el `<forward-request/>` de B2, sin duplicarlo por-API).

### 5. Por que centralizar el mapping en el borde habilita la migracion generica de tenancy (etapa b, MEF-ADR-0028)

MEF-ADR-0028 fija dos etapas de `ITenantResolver`: (a) mono-tenant transitorio (greenfield, sin autenticacion) y (b) un resolver real basado en `TenantContext`, cableado con `Cosmos.MultiTenancy.AspNetCore.AgregarTenantResolverConHeadersConfiables()` o el hibrido de `Cosmos.MultiTenancy.CritterStack`. Esos resolvers **ya esperan** exactamente los headers `X-Tenant-Id`/`X-User-Id` que la seccion 4 de este ADR produce -- `TrustedHeadersTenantResolver` los lee de `IHttpContextAccessor` y lanza si faltan.

El insight que este ADR aporta a esa transicion: **el mapping claim -> header vive una sola vez, en la politica global del gateway -- no en cada dominio**. Sin este patron, pasar un BC de la etapa (a) a la (b) dejaba un `// TODO(tenancy claims)` explicitamente marcado como "siempre project-specific" en el `Program.cs` de cada dominio (MEF-ADR-0028, seccion 3): cada Function App tendria que saber decodificar el JWT y extraer sus propios claims. Con APIM como front door unico normalizando la identidad **antes** de que el request llegue a cualquier Function App, esa logica deja de ser project-specific por dominio y pasa a ser una **unica** politica de gateway, compartida por todos los dominios del BC: cualquier Function App detras de APIM recibe directamente los headers canonicos que `AgregarTenantResolverConHeadersConfiables()` ya sabe leer, sin que el `domain-scaffolder` tenga que generar codigo de parsing de claims por dominio.

**Este ADR no enmienda MEF-ADR-0028 directamente** -- esa enmienda (el `ITenantResolver` que se cablea cuando el BC adopta WorkOS+APIM) es alcance de un issue de seguimiento cruzado, ya identificado en la planificacion. Este ADR deja fijado el insight (la normalizacion en el borde) del que esa enmienda depende.

### 6. Separacion de credenciales/proyectos del IdP

Cuando el IdP tiene mas de un proyecto/entorno (por ejemplo, uno para el login de administradores del BC y otro para las organizaciones de los tenants de negocio), las dos credenciales **no son intercambiables** y un consumidor real ya las mezclo por error, creando organizaciones en el proyecto equivocado:

- El **`client_id` de login** (el que identifica la app que autentica usuarios finales, usado en `issuer`/`required-claims` de la politica del gateway, seccion 3) vive en la **politica de APIM**.
- La **API key del proyecto de negocio** del IdP (la que usa el SDK `WorkOS.net` desde el backend para crear organizaciones, invitar usuarios, etc.) vive en la **Function App** que la consume, nunca en la politica del gateway.

Cualquier agente o skill que instale este patron debe documentar explicitamente, para el operador humano, que credencial corresponde a cada lado antes de escribirlas en su destino respectivo.

### 7. Custodia de secretos: ninguna key de WorkOS ni host key en texto plano

Consistente con MEF-ADR-0025 (custodia de secretos, principio general: ningun secreto ni key en texto plano en app settings ni en el estado de Terraform): la **API key del proyecto de negocio de WorkOS** se custodia en el Key Vault del BC (referencia `@Microsoft.KeyVault(...)` en la Function App que la consume, sembrada por CI) y la **host key de cada Function App** (B8) se custodia como `azurerm_api_management_named_value` con `secret = true` -- nunca como valor literal en el HCL ni en un output de Terraform legible en claro. El `client_id` de login (seccion 6) **no** es un secreto (es un identificador publico de la app OIDC) y puede viajar como variable no sensible de la politica del gateway.

### 8. Fuentes de documentacion de WorkOS: verificadas vs. a re-verificar en vivo

Por ser WorkOS un servicio de terceros (regla de verificacion de fuentes de `CLAUDE.md`), este ADR distingue lo que la documentacion publica confirma de lo que solo quedo confirmado empiricamente por ControlPlane decodificando un token real:

| Referencia | Confirma | Estado |
|---|---|---|
| AuthKit -- overview [1] | AuthKit es la solucion de autenticacion hospedada de WorkOS | verificado (documentacion oficial) |
| User Management -- AuthKit [2] | Flujo de login, `redirect URI`, intercambio de codigo por `User` | verificado (documentacion oficial) |
| Discovery endpoint client-specific: `https://api.workos.com/user_management/{client_id}/.well-known/openid-configuration` | El patron de URL del discovery endpoint termina en `/.well-known/openid-configuration` [10]; la variante **client-specific** exacta la confirmo la busqueda de la documentacion vigente | **verificado parcialmente** -- re-confirmar el `issuer`/`jwks_uri` exactos contra el discovery doc en vivo del proyecto WorkOS concreto al implementar (B5) |
| Ausencia de `aud` en el access token de AuthKit (B4) | Documentacion generica de WorkOS Connect si documenta `aud` para conexiones OIDC empresariales [9], pero no para el access token primario de AuthKit | **NO VERIFICADO en documentacion publica** -- confirmado unicamente decodificando un token real en ControlPlane; **re-verificar decodificando un token en vivo del proyecto concreto** antes de fijar `required-claims` sobre `client_id` en cualquier consumidor nuevo |
| Nombres de claim `user_email`/`tenant_id` (B10) | No documentados como nombres fijos en la documentacion publica generica de AuthKit | **NO VERIFICADO en documentacion publica** -- confirmado unicamente decodificando un token real; **re-verificar por consumidor**, porque `tenant_id` en particular depende de como cada proyecto de negocio modele sus organizaciones en WorkOS |

**Regla operativa para el agente/skill que implemente este patron**: los items marcados "NO VERIFICADO en documentacion publica" en la tabla anterior son un gate obligatorio de verificacion empirica (decodificar un token real del proyecto WorkOS concreto, o consultar su discovery doc en vivo) antes de fijar la politica de `validate-jwt` o el mapping de claims -- nunca asumirlos por analogia con otro consumidor o con otro IdP.

## Alternativas consideradas

### Alt 1: validar el JWT dentro de cada Function App (middleware propio) en vez de en el borde

**Descartada**: exigiria que cada dominio del BC importe y mantenga su propia logica de validacion de JWT (fetch del `jwks_uri`, verificacion de firma, chequeo de claims), duplicando la superficie de configuracion N veces y tocando el codigo de cada Function App -- justo lo que este ADR busca evitar (seccion 2). Ademas dispersaria el catalogo de trampas de la seccion 3 en N implementaciones en vez de una sola politica auditable.

### Alt 2: Microsoft Entra External ID / Azure AD B2C como IdP en vez de WorkOS AuthKit

Azure ofrece su propio IdP para escenarios de identidad de clientes (CIAM), con integracion nativa a APIM documentada oficialmente [4][12]. **No se adopta como default de este ADR**: el patron ya esta validado en produccion real (ControlPlane) con WorkOS, y migrar de IdP no es gratis (afecta UI de login, SDKs de backend, modelo de organizaciones/tenants). El patron de validacion en el borde (`validate-jwt` contra un `openid-config`) es **agnostico del IdP** -- este ADR fija WorkOS como IdP de *referencia* (el que ya funciona), no como el unico soportable; un consumidor que ya use Entra External ID puede aplicar la misma doctrina de la seccion 2-4 sustituyendo el discovery endpoint y re-verificando su propio catalogo de claims (secciones 3/8 aplican igual, con sus propios valores).

### Alt 3: tier APIM Standard/Premium en vez de Consumption

**Descartada por ahora**: Standard/Premium habilitan VNet, `rate-limit-by-key` y capacidad reservada, pero exigen un costo fijo mensual sustancialmente mayor y un tiempo de aprovisionamiento mas largo. El caso de uso del marco (backend serverless de bajo/medio volumen, MEF-ADR-0020) no justifica ese costo; se anota como alternativa valida a evaluar si un consumidor concreto necesita VNet injection o rate limiting por clave.

### Alt 4: dejar el `<base/>` por defecto en la politica global (seguir el default del editor del portal)

El editor de politicas del portal de APIM incluye `<base/>` por defecto en cada seccion nueva, y la documentacion oficial recomienda *"include a `base` element at the beginning of each policy section"* como best practice general [13]. **Descartada para el scope global especificamente**: esa recomendacion aplica a scopes con padre (product, API, operation); en el scope global no hay politica padre que heredar, y dejar `<base/>` ahi reproduce el `400 ValidationError` documentado en B1. El fix (sin `<base/>` en global) es la excepcion deliberada a esa best practice general, no una desviacion sin justificar.

## Consecuencias

### Positivas

- **Las Function Apps del BC no necesitan ningun cambio de codigo para ganar autenticacion**: `AuthorizationLevel.Function` + host key inyectada por el gateway (seccion 2) es un cambio puramente de infraestructura.
- **El catalogo de trampas verificadas (seccion 3) evita que un consumidor nuevo repita el costo real que pago ControlPlane** (~5 PRs, varios `apply` rotos) -- cada trampa queda como gate verificable, no como nota informativa a descubrir de nuevo.
- **La normalizacion de identidad en un solo punto (seccion 4/5) desbloquea la migracion generica de tenancy de la etapa (a) a la (b)** (MEF-ADR-0028): el mapping claim -> header deja de ser codigo project-specific repetido por dominio.
- **Anti-spoofing por diseno, en la capa que termina el trafico externo**: `exists-action="override"` en la politica global es el unico lugar donde hay que garantizar que un cliente no pueda suplantar un header de identidad, en vez de exigirselo a cada dominio.
- **Separacion explicita de custodia de secretos** (seccion 7), consistente con MEF-ADR-0025: ni la API key de WorkOS ni la host key de cada Function App viajan en claro.

### Negativas

- **Dependencia dura de un IdP de terceros cuya documentacion publica generica no siempre coincide con el comportamiento observado** (seccion 8): el issuer client-specific, la ausencia de `aud` y los nombres exactos de claim exigen verificacion empirica por consumidor, no solo lectura de docs -- un costo recurrente que este ADR no elimina, solo lo hace explicito.
- **Azure API Management es un front door unico (single point of failure) delante de todas las Function Apps del BC**, y el tier `Consumption` elegido (Alt 3) no soporta VNet, `rate-limit-by-key` ni Log Analytics de requests -- limites aceptados por costo/velocidad de aprovisionamiento, no por ausencia de alternativa.
- **Parte del catalogo B1-B10 es especifica de WorkOS (B4/B5/B10) y parte es generica de APIM/Terraform (B1-B3/B6-B9)**: un consumidor que adopte otro IdP (Alt 2) reutiliza integramente la mitad generica, pero debe re-verificar la mitad especifica de IdP desde cero contra su propio discovery doc y sus propios tokens.
- **El comportamiento documentado de `<base/>` en scope global ("sin efecto", `set-edit-policies` [7]) no coincide exactamente con el `400 ValidationError` observado empiricamente en el `apply` de ControlPlane** (B1): este ADR documenta ambos hechos en vez de resolver la discrepancia, y deja como riesgo conocido que el comportamiento pueda variar entre editor de portal, API version de gestion y el provider `azurerm` de Terraform.

## Referencias

- **[1]** "AuthKit" -- WorkOS Docs. Overview de la solucion de autenticacion hospedada de WorkOS. https://workos.com/docs/authkit
- **[2]** "User Management" -- WorkOS Docs. Flujo de AuthKit, redirect URI, intercambio de codigo de autorizacion por un `User`. https://workos.com/docs/user-management
- **[3]** "Validate JWT" -- Microsoft Learn, referencia de la politica `validate-jwt` de Azure API Management: scopes (`global, workspace, product, API, operation`), gateways (`classic, v2, consumption, self-hosted, workspace`), elementos (`openid-config`, `issuers`, `audiences`, `required-claims`) y la nota *"set the policy's elements and child elements in the order provided in the policy statement"*. https://learn.microsoft.com/azure/api-management/validate-jwt-policy
- **[4]** "Protect serverless APIs with Azure API Management and Azure AD B2C for consumption from a SPA" -- Microsoft Learn. Confirma que la politica `rate-limit-by-key` no esta disponible en el tier Consumption de APIM. https://learn.microsoft.com/azure/api-management/howto-protect-backend-frontend-azure-ad-b2c
- **[5]** `azurerm_function_app_host_keys` -- Terraform Registry, provider `azurerm`, data source que expone `default_function_key` y las extension keys de los distintos triggers. https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/function_app_host_keys
- **[6]** "Terraform AzureRM provider version history: 2.0.0 - 2.99.0" -- Microsoft Learn/HashiCorp. Confirma la introduccion del data source `azurerm_function_app_host_keys` en la version `2.27.0` del provider. https://learn.microsoft.com/azure/developer/terraform/provider-history/provider-version-history-azurerm-2-0-0-to-2-99-0
- **[7]** "How to set or edit Azure API Management policies" -- Microsoft Learn, seccion sobre el elemento `base`: *"A globally scoped policy has no parent scope, and using the `base` element in it has no effect."* https://learn.microsoft.com/azure/api-management/set-edit-policies
- **[8]** "CORS" -- Microsoft Learn, referencia de la politica `cors`: *"Only the `cors` policy is evaluated on the `OPTIONS` request during preflight."* https://learn.microsoft.com/azure/api-management/cors-policy
- **[9]** "OpenID configuration" (API Reference, metadatos de WorkOS Connect) -- WorkOS Docs. Documenta un discovery endpoint generico (`{authkit_domain}/.well-known/openid-configuration`) y un claim `aud` en el contexto de conexiones OIDC empresariales -- **alcance distinto** del access token primario de AuthKit citado en B4; no asumir equivalencia sin re-verificar. https://workos.com/docs/reference/workos-connect/metadata/openid-configuration
- **[10]** "What is OpenID Connect (OIDC)?" -- WorkOS Guides. Describe el discovery endpoint OIDC estandar (`/.well-known/openid-configuration`) y los metadatos que expone, incluido `issuer`. https://workos.com/guide/oidc
- **[11]** "Policies in Azure API Management" -- Microsoft Learn, seccion "Use policy expressions to modify requests": ejemplo oficial de `set-header` con `exists-action="override"` para propagar datos de contexto al backend. https://learn.microsoft.com/azure/api-management/api-management-howto-policies
- **[12]** "Secure an Azure API Management API with Azure AD B2C" -- Microsoft Learn. Referencia de integracion nativa APIM + IdP de Microsoft, citada en Alt 2. https://learn.microsoft.com/azure/active-directory-b2c/secure-api-management
- **[13]** "Policies in Azure API Management" -- Microsoft Learn, seccion "Scopes": recomienda incluir `<base/>` al inicio de cada seccion de politica como best practice para heredar politicas del scope padre. https://learn.microsoft.com/azure/api-management/api-management-howto-policies
- issue #335 ("Crear agente generador del modulo APIM..."): origen del catalogo de trampas B1-B10, el HCL de referencia C1-C4 y la seccion D (separacion de credenciales del IdP); refinado por el planner para acotarse al agente que consume la doctrina de este ADR.
- `Cosmos-SincoERP/Cosmos.ControlPlane`, `ADR-0027` (consumidor, sin prefijo del esquema del marco -- ver MEF-ADR-0030) y PRs `#96`-`#100`/`#103`/`#104`: origen real del patron, codigo funcionando que es la fuente de verdad de este ADR.
- MEF-ADR-0025 (custodia de secretos): la API key de WorkOS y la host key de cada Function App se custodian por su doctrina general (seccion 7).
- MEF-ADR-0028 (estrategia de tenancy): este ADR materializa la etapa (b) (resolver real basado en `TenantContext`) y aporta el insight de normalizacion de claims en el borde (seccion 5); la enmienda formal de MEF-ADR-0028 queda en un issue de seguimiento cruzado.
- MEF-ADR-0022 (autenticacion de CI por OIDC): el `apply` del modulo APIM y la siembra de la API key de WorkOS en Key Vault corren en CI, bajo la misma identidad federada.
- MEF-ADR-0021 (infraestructura base): APIM se monta delante de Function Apps ya provisionadas por este ADR ancla.
- MEF-ADR-0020 (hosting de Azure Functions): el backend que el gateway de este ADR reenvia.
- MEF-ADR-0030 (esquema de identificacion de ADRs): este documento nace ya con el prefijo `MEF-ADR-`, numero `0032`.

## Control de cambios

- 2026-07-22: creacion como `aceptado` (issue #336). Fija WorkOS AuthKit como IdP de referencia y Azure API Management Consumption como front door unico que valida el JWT en el borde sin tocar codigo de las Function Apps; embebe el catalogo de trampas verificadas B1-B10 de APIM/Terraform (origen: issue #335, incidente real en Cosmos.ControlPlane); fija la propagacion de identidad claim -> header canonico (`user_email` -> `X-User-Id`, `tenant_id` -> `X-Tenant-Id`) con anti-spoofing (`exists-action="override"`) y documenta por que centralizar ese mapping en el borde habilita la migracion generica de la etapa (a) a la (b) de MEF-ADR-0028; fija la separacion de credenciales/proyectos del IdP (client_id de login en la politica del gateway, API key de negocio en la Function App); y marca explicitamente que partes del catalogo (issuer client-specific, ausencia de `aud`, nombres de claim) estan verificadas solo empiricamente contra un token real de ControlPlane y no contra documentacion publica generica de WorkOS, exigiendo re-verificacion contra el discovery doc en vivo de cada consumidor. Bloquea al agente `apim-gateway-scaffolder` (issue #335) y a la familia de skills `/install-workos`/`/install-apim`/`/install-auth`.
- 2026-07-22: implementacion (issue #340). El skill `/install-apim` (`commands/install-apim.md`) invoca
  `apim-gateway-scaffolder` (#335) para instalar/actualizar el gateway y ejecuta la transicion de tenancy
  que fija MEF-ADR-0028 seccion 4. Se actualiza en el cuerpo ("Aplica a") la mencion a `/install-apim` de
  "aun no implementado" a implementado (`/install-workos`, issue #339, ya estaba implementado); `/install-auth`
  sigue sin implementar. Ninguna decision de este ADR cambia.
- 2026-07-22: implementacion (issue #342). El skill `/install-auth` (`commands/install-auth.md`) orquesta
  la familia completa: encadena `/install-workos` (etapa 1) y `/install-apim` (etapa 2) con un gate humano
  en medio que verifica (via `gh secret`/`variable list`) que `WORKOS_CLIENT_ID` y `WORKOS_API_KEY` existen
  en el repo antes de arrancar la etapa 2 -- el mismo requisito de credenciales que ya documentaba este ADR
  (seccion 6/7), ahora reforzado como gate bloqueante en vez de dejarlo a criterio del usuario. Es stateless:
  delega integramente en la idempotencia de ambos sub-skills, sin reimplementar su logica. Se actualiza en
  el cuerpo ("Aplica a") la mencion a `/install-auth` de "aun no implementado" a implementado. Ninguna
  decision de este ADR cambia.
