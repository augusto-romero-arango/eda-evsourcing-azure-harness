# ADR-0025: Custodia de secretos (ningun secreto ni key en texto plano en app settings)

- **Fecha**: 2026-07-01 (reformado 2026-07-06)
- **Estado**: aceptado
- **Aplica a**: doctrina de manejo de secretos del marco; gobierno de los agentes `infra-base-scaffolder`, `domain-scaffolder`, `implementer` e `infra-writer`, y del backend remoto del tfstate (`scripts/bootstrap-backend.sh`). Generaliza ADR-0024 (decision #6) y reencuadra el modulo Key Vault de ADR-0021.

## Contexto

ADR-0024 decision #6 introdujo la custodia de secretos en **Azure Key Vault**, pero acotada a las **cadenas de conexion de Azure Service Bus**. La auditoria posterior a la implementacion de ADR-0024 encontro que otros secretos del harness siguen viajando en **texto plano** en los app settings de la Function App:

- El **password de PostgreSQL** embebido en `MartenConnectionString` (`...Password=${var.postgresql_admin_password}...`), generado por `domain-scaffolder`.
- La **access key de la Storage Account** del host de Functions (`AzureWebJobsStorage`), pasada como argumento nativo al recurso Function App.
- La **connection string de Application Insights** (que incluye la instrumentation key), como app setting literal.

El riesgo: cualquiera con lectura del recurso Function App -- o del estado de Terraform, donde el valor tambien se materializa -- ve secretos en claro. Es superficie de rotacion y de fuga.

El principio que faltaba enunciar de forma general (ADR-0024 lo aplico solo a un caso): **los app settings no deben contener ningun secreto ni key en texto plano**. Todo secreto se custodia fuera del app setting -- en Key Vault, referenciado -- o se accede por **identidad administrada** cuando el runtime lo exige. Las cadenas de ASB de ADR-0024 son una **instancia** de este principio, no su alcance total.

## Decision

### 1. Principio general: ningun secreto ni key en texto plano

Un app setting nunca contiene el **valor** de un secreto (cadena de conexion con password, access key, instrumentation key, token de API, etc.). Lleva una **referencia** `@Microsoft.KeyVault(...)`, o el secreto se resuelve por **identidad administrada**. El principio aplica por igual al valor en el recurso desplegado y al **estado de Terraform**: Terraform no materializa el valor de ningun secreto.

### 2. Mecanismo por defecto: referencia a Key Vault

Igual que ADR-0024 decision #6: el secreto vive en el Key Vault del BC y el app setting lleva `@Microsoft.KeyVault(SecretUri=...)` **versionless** (toma la ultima version al rotar). El **valor** lo coloca infra / un admin (`az keyvault secret set`), nunca Terraform; el harness provisiona (a) la referencia en app settings y (b) el rol **Key Vault Secrets User** de la managed identity de la Function App.

### 3. Mecanismo alterno: identidad administrada donde el runtime lo exige

`AzureWebJobsStorage` (el storage del host de Azure Functions) **no** puede ir por referencia de Key Vault: el runtime necesita el storage al arrancar, **antes** de que se resuelvan las referencias `@Microsoft.KeyVault(...)`. La ruta soportada por Azure es la **conexion por identidad administrada** (`storage_uses_managed_identity = true` + rol de datos de Storage a la managed identity de la Function App). No es un secreto custodiado: es acceso identity-based, coherente con ADR-0022 (OIDC) y con el norte de ADR-0024 Alt 4.

### 4. Clasificacion de los secretos actuales y su custodia

| Secreto | Custodia | Estado |
|---|---|---|
| Cadenas de ASB (interno propio, backbone compartido, externo) | referencia Key Vault | ya implementado (ADR-0024 decision #6) |
| Password de PostgreSQL (`MartenConnectionString`) | referencia Key Vault | a implementar |
| Connection string de Application Insights (instrumentation key) | referencia Key Vault | a implementar |
| Access key de Storage / `AzureWebJobsStorage` | identidad administrada | a implementar |

### 5. El Key Vault del BC es un almacen general de secretos

El modulo Key Vault que introdujo la implementacion de ADR-0024 deja de ser "custodia de cadenas de ASB" y pasa a ser el **almacen general de secretos del BC**: cualquier secreto que emerja (cadenas, keys, tokens, credenciales) se custodia ahi. Es el vehiculo por defecto del principio de la decision #1.

### 6. Propiedad del valor

El valor de todo secreto de Key Vault se coloca de forma **administrativa** (fuera del ciclo de Terraform y del repo), igual que ADR-0024 decision #6. El harness provisiona la referencia y el RBAC; nunca el valor.

### 7. El desarrollador no custodia secretos de Azure en local

Consecuencia directa de la reforma de ADR-0022 (issue #196): el `apply` de infraestructura -- el unico paso que necesita permisos elevados de escritura y acceso a los secretos custodiados (Key Vault del BC, tfstate) -- ocurre en CI, bajo la identidad federada del Service Principal (OIDC/WIF). El desarrollador que corre el pipeline IaC local (`iac-pipeline.sh`, stages de escritura y revision/plan) nunca necesita una credencial elevada de Azure en su maquina ni custodia ningun secreto: su `terraform plan` local es de solo lectura sobre el tfstate y sobre los recursos existentes.

### 8. Backend del tfstate keyless (AAD)

El bloque `backend "azurerm"` que genera `scripts/bootstrap-backend.sh` usa `use_azuread_auth = true` en vez de una `access_key` o SAS token. Tanto el `terraform plan` local del desarrollador como el `terraform apply` de CI acceden al state por AAD/RBAC -- nunca por una key en texto plano que viajaria en `backend.tf`, en variables de entorno o en un secret de GitHub. El SP de CI recibe `Storage Blob Data Contributor` sobre la cuenta del tfstate (ADR-0022, necesario para escribir el state y tomar el lease del blob durante el `apply`); el desarrollador que corre el `plan` local necesita, a su vez, un rol de datos de Storage sobre esa misma cuenta asignado a su propia identidad de Azure AD (asignacion administrativa por consumidor, fuera del alcance de este ADR). Es el cierre coherente del principio de la decision #1 (ningun secreto ni key en texto plano) aplicado al propio backend de Terraform, y del espiritu identity-based de ADR-0022.

## Alternativas consideradas

### Alt 1: dejar los secretos no-ASB en texto plano

**Descartada**: es el estado tras ADR-0024. Deja el password de Postgres, la access key de Storage y la connection string de App Insights en claro en app settings y en el state. Contradice la intencion de custodia y es una brecha de seguridad real.

### Alt 2: Key Vault para todo, incluido `AzureWebJobsStorage`

**Descartada**: el runtime de Azure Functions requiere el storage del host **al arrancar**, antes de resolver referencias de Key Vault; una referencia `@Microsoft.KeyVault(...)` para `AzureWebJobsStorage` no resuelve de forma fiable en el arranque. La ruta soportada es identidad administrada.

### Alt 3: identidad administrada para todo (ASB incluido) ahora

**Diferida**: el paquete `Cosmos.EventDriven.CritterStack.AzureServiceBus` no soporta wiring por identidad para la publicacion de Wolverine (ADR-0024 Alt 4). Se aplica identidad administrada **donde ya es viable** (Storage) y referencia de Key Vault **donde no** (ASB, Postgres, App Insights). La migracion de esos a identidad queda como trabajo diferido.

## Consecuencias

### Positivas

- **App settings sin secretos en claro**: ni en el recurso desplegado ni en el state de Terraform.
- **Almacen unico**: el Key Vault del BC concentra todos los secretos; base para secretos futuros (API keys de terceros, etc.) sin decidir de nuevo el mecanismo.
- **Alineado con best-practice de Azure**: referencias de Key Vault para app settings; identidad administrada para el storage del host.
- **Ningun secreto de Azure en la maquina del desarrollador**: el `apply` (unico paso que escribe secretos/RBAC) ocurre en CI (ADR-0022); el backend del tfstate es keyless (AAD) tanto para el `plan` local como para el `apply` de CI.

### Negativas

- **Mas RBAC y referencias que provisionar**: cada secreto suma una referencia y, donde aplique, un role assignment de datos.
- **Siembra administrativa**: el valor de cada secreto es una accion manual post-`apply` (mitigado por documentarlo en el output del `infra-base-scaffolder`).
- **Postgres y App Insights siguen siendo secretos**: se mantiene la deuda de rotacion (mitigada por Key Vault) hasta que existan alternativas identity-based para ellos.

### Enmiendas que este ADR ordena

Al implementar estas enmiendas, el contenido superado se **elimina del cuerpo** del ADR/agente afectado; no se marca como "obsoleto". El registro del cambio vive solo en el control de cambios del ADR correspondiente (convencion del proyecto).

- **ADR-0024 decision #6**: generalizar. La custodia en Key Vault no es exclusiva de las cadenas de ASB; remite a este ADR como doctrina general. Incluir explicitamente la cadena del ASB **propio (interno)** en la custodia (ya implementada por el contrato del registro `serviceBus` y el modulo Key Vault; el cuerpo de #6 la omitia al nombrar solo "backbone y externo").
- **ADR-0021** (infraestructura base): el modulo Key Vault es el **almacen general de secretos del BC**, no "custodia de cadenas de ASB". Reencuadrar su descripcion.
- **`agents/domain-scaffolder.md`**: `MartenConnectionString` por referencia de Key Vault; connection string de App Insights por referencia de Key Vault; Storage por identidad administrada (`storage_uses_managed_identity` + rol de datos de Storage a la managed identity). El bloque `app_settings` no contiene ningun secreto literal.
- **`agents/infra-base-scaffolder.md`**: el modulo `function-app` soporta storage por identidad; el modulo `key-vault` reencuadrado como almacen general; role assignment de datos de Storage a la managed identity.
- **`agents/implementer.md`**: cualquier secreto nuevo que un flujo introduzca va por Key Vault (o identidad administrada); nunca texto plano en app settings.

### Trabajo diferido

- **Migracion de ASB, Postgres y App Insights a identidad administrada**: cuando exista soporte viable (para ASB, ver ADR-0024 Alt 4; para Postgres, autenticacion por Entra ID / token). Entonces esos dejarian de ser secretos custodiados.
- **Rotacion automatizada** de los secretos de Key Vault: fuera de alcance de este ADR.

## Referencias

- ADR-0024 (modelo de eventos de bus) decision #6: la custodia de cadenas de ASB es una instancia de esta doctrina; este ADR la generaliza e incluye la cadena interna.
- ADR-0021 (infraestructura base): reencuadra el modulo Key Vault como almacen general de secretos del BC.
- ADR-0022 (autenticacion de CI hacia Azure por OIDC): mismo espiritu identity-based; el storage por identidad administrada de la decision #3 se alinea con el. Reformado junto con este ADR (issue #196) para fijar que el `apply` de infraestructura ocurre en CI, nunca localmente -- el hecho que permite que el desarrollador nunca custodie secretos de Azure en su maquina (decision #7).
- ADR-0020 (hosting: un App Service Plan por Function App): el `AzureWebJobsStorage` afectado por la decision #3 es el storage del host de cada Function App.
- "Use Key Vault references for App Service and Azure Functions". https://learn.microsoft.com/azure/app-service/app-service-key-vault-references
- "Connect to host storage with an identity" (Azure Functions). https://learn.microsoft.com/azure/azure-functions/functions-reference#connecting-to-host-storage-with-an-identity
- "Configure managed identities for App Service and Azure Functions". https://learn.microsoft.com/azure/app-service/overview-managed-identity
- "Backend Type: azurerm" (Terraform, HashiCorp): `use_azuread_auth`, autenticacion del backend del tfstate por Microsoft Entra ID en vez de access key -- mecanismo de la decision #8. https://developer.hashicorp.com/terraform/language/backend/azurerm

## Control de cambios

- 2026-07-01: creacion como `propuesta` (nace de la auditoria de secretos posterior a la implementacion de ADR-0024: el password de Postgres, la access key de Storage y la connection string de App Insights quedaban en texto plano en app settings; se generaliza el principio de custodia mas alla de las cadenas de ASB).
- 2026-07-01: `aceptado` tras la revision con el usuario.
- 2026-07-06: reformado (issue #196, ancla doctrinal de la oleada de apply-en-CI, junto con ADR-0021 y ADR-0022) para fijar que el desarrollador no custodia secretos de Azure en local (decision #7, consecuencia de que el `apply` migra a CI) y que el backend del tfstate es keyless via `use_azuread_auth` (decision #8), coherente con el principio de la decision #1 aplicado al propio backend de Terraform.
