# ADR-0021: Infraestructura base del consumidor - 7 modulos + esqueleto del entorno generados por un agente

- **Fecha**: 2026-06-25 (reformado 2026-06-30)
- **Estado**: aceptado
- **Aplica a**: scaffolding de infraestructura del proyecto consumidor (Terraform), agentes `infra-base-scaffolder`, `domain-scaffolder` e `infra-writer`, flujo greenfield.

## Contexto

El marco despliega cada dominio como una Function App sobre un App Service Plan dedicado (ADR-0020), con su Storage Account, y los dominios comparten un Resource Group, monitoreo (Log Analytics + Application Insights), PostgreSQL (event store de Marten, ADR-0003) y un namespace de Azure Service Bus con topics por evento (ADR-0001). Tanto el `domain-scaffolder` (Paso 4) como el `infra-writer` **asumian preexistente** un conjunto de modulos Terraform base bajo `infra/modules/` del consumidor:

- `domain-scaffolder.md` (Paso 4) instancia `../../modules/storage`, `../../modules/service-plan` y `../../modules/function-app`, y referencia `module.resource_group`, `module.monitoring`, `module.service_bus` y `module.postgresql`.
- `infra-writer.md` instruye "lee los modulos existentes en `infra/modules/` que puedas reutilizar" y "lee el ambiente target en `infra/environments/<env>/`".

Pero **el harness no proveia esa base de ninguna forma**: ni plantilla copiable, ni generador, ni agente (verificado: no existe directorio `templates/` ni comando/agente que la cree). En el primer greenfield real (`Bitakora.ControlAsistencia`, arrancado desde cero) hubo que escribir a mano `infra/modules/*` y `infra/environments/dev/*` antes de poder provisionar nada. Sintomas concretos del vacio:

- Las **Notas del Paso 4** del scaffolder lo admitian explicitamente ("el modulo `postgresql` debe estar en la infraestructura base antes de ejecutar `terraform apply`"; "el modulo `modules/service-plan` debe aceptar los inputs `os_type`, `sku_name`, `worker_count`, `always_on` ... antes de ejecutar `terraform apply`"): convertian una dependencia dura del harness en una advertencia pasiva al usuario.
- El `terraform output` de un greenfield salia **vacio** porque nadie generaba el esqueleto del entorno con sus `outputs.tf`.
- El modulo `service-plan` que se escribio a mano en campo **incumplia el contrato de ADR-0020**: solo aceptaba `name`, `resource_group_name`, `location`, `sku_name`, `tags`, mientras el scaffolder le pasa ademas `os_type`, `worker_count` y `always_on`. Sin esos inputs, el `terraform validate` del Paso 4 falla.

**Nueva raiz doctrinal: ADR-0023 (#121, cerrado).** Este ADR fue escrito antes de que ADR-0023 existiera. ADR-0023 establece la topologia de dos namespaces de Azure Service Bus por Bounded Context — namespace interno (eventos privados intra-BC) y namespace de integracion (eventos publicos inter-BC) — como doctrina estrategica del marco. ADR-0021 describia el modelo anterior de "un namespace de Service Bus compartido"; esta reforma alinea ADR-0021 con la raiz de ADR-0023 para que la infraestructura base que genera el agente refleje la topologia correcta desde el primer greenfield.

## Decision

**El harness provee la infraestructura base mediante un agente generador (`infra-base-scaffolder`) que escribe el HCL inline con la tool `Write`, NO mediante un directorio de plantillas copiables.** El agente genera, en el consumidor:

1. Los **7 modulos base** bajo `infra/modules/`.
2. El **esqueleto del entorno** bajo `infra/environments/<env>/` (`main.tf`, `variables.tf`, `providers.tf`, `outputs.tf`), **sin** `backend.tf` (lo escribe `scripts/bootstrap-backend.sh`).

### Por que un agente y no un directorio de plantillas

1. **Es el unico patron de scaffold que el harness ya usa.** El `domain-scaffolder` no copia archivos de un `templates/`: emite el contenido inline desde su prompt (HCL del Paso 4, YAML del Paso 5). El harness no tiene directorio `templates/` ni mecanismo de copia. Crear uno seria inventar un mecanismo sin precedente (coherente con la separacion publicado/interno de ADR-0019: los agentes operan sobre el consumidor emitiendo contenido, no copiando blobs del plugin).
2. **El contenido no es estatico.** El `service-plan` debe cumplir ADR-0020 (que la plantilla de campo incumplia), la region de PostgreSQL depende del consumidor (algunas regiones restringen Flexible Server) y los nombres globales pueden necesitar un sufijo de unicidad. Un agente aplica reglas y lee `harness.config.json`/`CLAUDE.md` para parametrizar; un archivo copiado las congela.
3. **Encaja en el flujo greenfield existente.** `infra-bootstrap` ya orquesta "bootstrap del tfstate -> primer `/infra`". El esqueleto base es el eslabon que faltaba entre ambos: `bootstrap-backend.sh` crea el backend del `tfstate`; `infra-base-scaffolder` crea los modulos y el entorno; `/infra` aplica.

### Dos namespaces ASB por Bounded Context: cambio respecto a la version anterior

ADR-0023 (decision #2) establece que cada Bounded Context provisiona exactamente **dos** namespaces de Azure Service Bus con responsabilidades ortogonales:

| Namespace | Proposito | Interfaz de publicacion |
|---|---|---|
| **Namespace interno** | Eventos privados intra-BC; mensajeria entre dominios del mismo BC | `IPrivateEventSender` |
| **Namespace de integracion** | Eventos publicos inter-BC; los consumidores externos se suscriben aqui | `IPublicEventSender` |

La separacion es **topologica** (dos namespaces fisicos), no una convencion de naming dentro de un namespace unico. El namespace interno no es alcanzable desde fuera del BC: un consumidor externo solo puede recibir credenciales/RBAC sobre el namespace de integracion; el namespace interno no existe en su contexto de autenticacion. Este aislamiento es una propiedad arquitectonica del diseño, no una responsabilidad de configuracion.

**El enrutamiento (privado/publico) es puramente topologico**: la unica diferencia entre publicar en el namespace interno y en el de integracion es el namespace destino (`IPrivateEventSender` vs `IPublicEventSender`). Ambas categorias de evento son planas y portables (ADR-0023 decision #3, reformado en #122): el criterio de "plano" es "¿cruza un bus?", no "¿es publico?". No existe una regla distinta de serializacion entre eventos privados y publicos; ambos deben ser planos porque ambos cruzan un bus.

El modulo Terraform `service-bus` **no cambia su definicion**: sigue siendo "un namespace + topics/subscriptions parametrizables". Lo que cambia es que el **esqueleto del entorno lo instancia dos veces** — una para el namespace interno y otra para el de integracion — de modo que el BC queda con la topologia de dos namespaces desde el primer `terraform apply`.

### Los 7 modulos base y su contrato

| Modulo | Recursos | Inputs principales | Outputs | `prevent_destroy` |
|---|---|---|---|---|
| `resource-group` | `azurerm_resource_group` | `name`, `location`, `tags` | `name`, `location`, `id` | no |
| `monitoring` | Log Analytics + Application Insights + action group + 2 alertas de costo | `name`, `resource_group_name`, `location`, `alert_action_group_email` (requerido), `daily_data_cap_in_gb`, `daily_cap_warning_percent`, `tags` | `connection_string` (sensitive), `instrumentation_key` (sensitive) | no |
| `postgresql` | `azurerm_postgresql_flexible_server` (v17, `B_Standard_B1ms`) + database + firewall `allow-azure-services` | `name`, `resource_group_name`, `location`, `administrator_login`, `administrator_password` (sensitive), `database_name`, `zone`, `tags` | `server_fqdn`, `database_name`, `administrator_login` | **si** |
| `service-bus` | `azurerm_servicebus_namespace` + topics/subscriptions parametrizables + RBAC Data Sender del productor en el namespace de integracion | `name`, `resource_group_name`, `location`, `sku`, `topics_config`, `tags` | `id`, `name`, `default_primary_connection_string` (sensitive), `topic_ids` | **si** |
| `service-plan` | `azurerm_service_plan` Linux | `name`, `resource_group_name`, `location`, `os_type`, `sku_name`, `worker_count`, `always_on`, `tags` | `id`, `always_on` | no |
| `storage` | `azurerm_storage_account` Standard LRS | `name`, `resource_group_name`, `location`, `tags` | `id`, `name`, `primary_connection_string` (sensitive), `primary_access_key` (sensitive) | **si** |
| `function-app` | `azurerm_linux_function_app` (.NET 10 isolated, SystemAssigned identity) | `name`, `resource_group_name`, `location`, `service_plan_id`, `storage_account_name`, `storage_account_connection_string`, `storage_account_access_key`, `app_insights_connection_string`, `app_settings`, `tags` | `id`, `name`, `principal_id` | no |

**Nota sobre el modulo `service-bus`:** el modulo es parametrico (un namespace + topics/subscriptions) y se instancia **dos veces** en el entorno: una para el namespace interno y otra para el namespace de integracion (ver "El esqueleto del entorno y sus outputs"). Los inputs `name`, `resource_group_name`, `location`, `sku`, `topics_config`, `tags` aplican a cada instancia por separado; el entorno pasa nombres distintos a cada una. Ambas instancias exponen `name`, `id` y `default_primary_connection_string` que el entorno y los agentes usan para las dos variables de entorno del dominio (una por namespace). El RBAC Data Sender del productor (rol `Azure Service Bus Data Sender` sobre el namespace de integracion) se lista como recurso emitido por esta instancia del modulo; el detalle de implementacion HCL y las asignaciones de rol fino cross-BC quedan diferidos a #130 (scaffolder) y a la materializacion del Context Map (#131).

### El modulo `service-plan` cumple el contrato de ADR-0020 (resuelve la divergencia de campo)

El modulo base que genera el agente acepta los cuatro inputs de hosting del contrato de ADR-0020 (`os_type`, `sku_name`, `worker_count`, `always_on`), de modo que la llamada `module service_plan_<dominio>` que emite el `domain-scaffolder` en el Paso 4 valida sin la advertencia pasiva que antes se le pedia al usuario.

Nota sobre `always_on`: `azurerm_service_plan` no tiene un argumento `always_on` (esa propiedad vive en `site_config` de la Function App). El modulo `service-plan` **acepta** `always_on` por el contrato de ADR-0020 (centraliza los parametros de hosting por dominio) y lo **expone como output** (`always_on`) para que la Function App lo consuma en su `site_config`. Asi el contrato de inputs se honra literalmente y el valor no se pierde.

### El sufijo de unicidad vive en el ENTORNO, no en los modulos

Los nombres globalmente unicos (Storage Account, PostgreSQL y los dos namespaces de Service Bus) se resuelven en `infra/environments/<env>/`, no dentro de los `main.tf` de los modulos. Los modulos `postgresql`/`service-bus` reciben el nombre ya formado via `var.name`; es el esqueleto del entorno quien decide si lleva sufijo. Por eso el provider `random` se declara en el `providers.tf` del esqueleto.

**El sufijo de unicidad aplica a ambos namespaces de Service Bus.** Cada instancia del modulo `service-bus` (interno e integracion) recibe su propio `random_string` (length 6, `special = false`, `upper = false`), de modo que los nombres de DNS publico no colisionan entre si ni con otros tenants. Ejemplo de naming:

- Namespace interno: `sbint-controlasistencias-abc123` (prefix corto `sbint-`, identificador del proyecto, sufijo de unicidad)
- Namespace de integracion: `sbext-controlasistencias-def456` (prefix corto `sbext-`, mismo identificador del proyecto, sufijo de unicidad distinto)

Los dos sufijos son independientes entre si (dos recursos `random_string` distintos) y del sufijo de PostgreSQL.

**Unicidad global: que recursos la necesitan y por que (issue #94).** El nombre de un PostgreSQL Flexible Server (`*.postgres.database.azure.com`), de un namespace de Service Bus (`*.servicebus.windows.net`) y de una Storage Account (`*.blob.core.windows.net`) es un endpoint DNS publico y, por tanto, **unico en TODO Azure**, no solo dentro del resource group o de la suscripcion. Un nombre derivado solo de `local.prefix` choca con cualquier otro tenant que ya lo haya reservado. El primer greenfield real (`Bitakora.ControlAsistencia`) lo evidencio en dos mitades: la Storage del `tfstate` con `StorageAccountAlreadyTaken` (resuelto en `bootstrap-backend.sh`, issue #92) y el servidor PostgreSQL con `ServerNameAlreadyExists` (este issue #94). Por eso el esqueleto del entorno que genera el agente declara un `random_string` (length 6, `special = false`, `upper = false`) **por cada uno** de PostgreSQL y los dos namespaces de Service Bus, e incorpora su `.result` al `name` que pasa a cada modulo. Las Storage por dominio ya seguian este patron (lo agrega el `domain-scaffolder`). Es el mismo mecanismo que la Storage del tfstate, de modo que todos los tipos de recurso con DNS publico convergen al mismo patron.

**Limites de nombre de Azure.** Los nombres con sufijo deben caber en los limites de la plataforma: PostgreSQL Flexible Server admite 3-63 chars (minusculas, numeros, guiones) y Service Bus namespace 6-50 chars (empieza con letra, termina en letra/numero). Para los prefijos tipicos del harness, los patrones `sbint-${proyecto}-${sufijo}` y `sbext-${proyecto}-${sufijo}` quedan bajo 50 chars para proyectos con nombre de hasta ~25 chars; si el consumidor configura un `project` muy largo, debe acortarlo en `variables.tf` para no exceder el limite del namespace.

**Limitacion: el sufijo es para greenfield, no migra recursos ya desplegados.** `random_string` es idempotente sin `keepers` (Terraform persiste su valor en el state en el primer `apply` y lo mantiene estable). Pero anadir el sufijo a un PostgreSQL o namespace de Service Bus **ya creado** sin el cambia su `name`, que es un atributo `ForceNew`: Terraform querria destruir+recrear y el `prevent_destroy = true` de ambos modulos lo bloqueara. Por tanto el sufijo solo es seguro en el primer `apply` (recurso aun inexistente). Un consumidor que ya aplico sin sufijo debe migrar manualmente (`terraform state mv`/`import` o aceptar el nombre nuevo); no es automatico.

### El esqueleto del entorno y sus outputs

El `infra/environments/<env>/main.tf` generado instancia **solo** los modulos compartidos (`resource_group`, `monitoring`, `postgresql` y los **dos** modulos `service_bus`); las instancias por dominio (`storage`, `service-plan`, `function-app`) las agrega el `domain-scaffolder` al crear cada dominio. Las dos instancias del modulo `service-bus` viven en el mismo `main.tf`, no en archivos separados:

```hcl
module "service_bus_interno" {
  source = "../../modules/service-bus"
  # ... name = "sbint-${local.prefix}-${random_string.sb_interno_suffix.result}"
}

module "service_bus_integracion" {
  source = "../../modules/service-bus"
  # ... name = "sbext-${local.prefix}-${random_string.sb_integracion_suffix.result}"
}
```

El `outputs.tf` expone a nivel raiz, como minimo, `resource_group_name`, `postgresql_fqdn` y los outputs de **ambos** namespaces de Service Bus, de modo que `terraform output` no salga vacio tras el primer apply:

- `service_bus_interno_name` y `service_bus_interno_connection_string` (sensitive)
- `service_bus_integracion_name` y `service_bus_integracion_connection_string` (sensitive)

El `providers.tf` declara `azurerm` y `random` y el bloque `provider "azurerm"`, pero **no** incluye `backend "azurerm"`: el backend lo materializa `scripts/bootstrap-backend.sh` en `backend.tf`, y duplicarlo haria fallar a Terraform por doble definicion de backend.

### Region de PostgreSQL Flexible Server: la restriccion de oferta por suscripcion (issue #99)

El modulo `postgresql` recibe su region via `var.location`, que en el esqueleto del entorno se alimenta del local `postgresql_location` (revisable en `infra/environments/<env>/terraform.tfvars`). **Esa region es independiente del campo `azureLocation` de `harness.config.json`** -el que `scripts/bootstrap-backend.sh` usa para el backend del `tfstate` (Resource Group + Storage Account + container)- y puede, y a veces debe, **diferir**.

El motivo: la creacion de un PostgreSQL Flexible Server puede abortar con `LocationIsOfferRestricted` aunque la region figure como disponible en la lista oficial de regiones del servicio. Es una restriccion de **oferta a nivel de suscripcion** (la SKU/oferta de Flexible Server no esta habilitada para esa suscripcion en esa region), no una indisponibilidad global de la region. En el primer greenfield real (`Bitakora.ControlAsistencia`), `eastus2` -region perfectamente valida para el backend del tfstate, y listada como soportada en el overview de Postgres- devolvio `LocationIsOfferRestricted` al crear el servidor; se resolvio con `centralus` (region verificada con oferta de Postgres para esa suscripcion, y que quedo solo como comentario en el HCL de campo). Por eso **no existe una region "apta" universal** que el harness pueda fijar por defecto: depende de la suscripcion del consumidor.

**Verificacion antes del primer `apply`.** Como la restriccion es por suscripcion, cada consumidor debe verificar la suya antes de provisionar, en vez de descubrir el `LocationIsOfferRestricted` recien en el `terraform apply`:

```bash
az postgres flexible-server list-skus --location <region> -o table
```

Si el comando lista SKUs -incluida `Standard_B1ms`, la SKU de computo que usa este modulo- la region sirve para esa suscripcion; si sale vacio o falla, hay que elegir otra (p. ej. `centralus`).

**Naming de la SKU: `Standard_B1ms` (CLI) vs `B_Standard_B1ms` (Terraform).** `az postgres flexible-server list-skus` y `az postgres flexible-server create --sku-name` nombran esta SKU de computo `Standard_B1ms` (con el tier `Burstable` como parametro aparte); el provider `azurerm` la declara en `sku_name` como `B_Standard_B1ms`, anteponiendo el tier -ese es el valor que figura en la fila `postgresql` de la tabla de los 7 modulos-. Son la misma SKU de computo en dos convenciones, asi que al leer la salida de `list-skus` se busca `Standard_B1ms`, no `B_Standard_B1ms`.

Esta nota vive a nivel del **entorno/consumidor**, no del modulo: el `postgresql` recibe `location` ya resuelto via `var.location` y no decide la region. La documentacion operativa del campo `azureLocation` y del paso de bootstrap en el `README.md` enlaza a esta seccion, de modo que el proximo greenfield no reincida en el roce.

### Idempotencia

Re-ejecutar el generador sobre un repo que ya tiene parte de la base **no sobrescribe** lo presente: el agente detecta cada archivo existente y solo crea lo faltante, reportando que omitio (para no pisar personalizaciones del consumidor). No hay sobrescritura destructiva.

## Alternativas consideradas

### Alt 1: directorio `templates/` copiable dentro del plugin

Crear `templates/infra/modules/*` y copiarlos al consumidor.

**Descartado**: sin precedente en el harness (no existe mecanismo de copia ni `templates/`), congela contenido que debe ser parametrico (contrato de `service-plan`, region de Postgres, sufijos de unicidad) y rompe la separacion de ADR-0019 (los agentes operan emitiendo contenido sobre el consumidor, no copiando blobs del plugin).

### Alt 2: extender `infra-bootstrap` para que, ademas del tfstate, genere la base

Un solo agente que crea backend + modulos + entorno.

**Descartado como diseno primario** (aunque cumpliria los CAs): mezcla dos responsabilidades distintas ("crear backend del tfstate" vs "crear modulos y entorno") en un agente que hoy es `tools: Bash` puro. Separar el agente generador (`infra-base-scaffolder`, con `Write`/`Edit`) de `infra-bootstrap` es mas limpio y testeable. `infra-bootstrap` y el README solo referencian el nuevo paso.

## Consecuencias

### Positivas

- **El greenfield ya no reinventa la base a mano**: un agente genera los 7 modulos y el entorno con outputs.
- **El contrato de ADR-0020 se cumple desde el origen**: el `service-plan` generado acepta `os_type`/`sku_name`/`worker_count`/`always_on`; desaparece la advertencia pasiva del Paso 4.
- **`terraform output` deja de salir vacio**: el esqueleto expone outputs raiz, incluidos los de ambos namespaces de Service Bus.
- **Idempotente**: re-ejecutable sin pisar personalizaciones.
- **Aislamiento estructural por topologia**: la separacion de dos namespaces (no por convencion de naming) garantiza que el namespace interno es inaccesible desde fuera del BC, incluso si la configuracion de RBAC falla; es una propiedad arquitectonica del diseño, no una responsabilidad de configuracion.

### Negativas

- **El HCL base vive como prosa en el prompt del agente** (no como archivos `.tf` versionados del plugin), igual que el HCL del Paso 4 del `domain-scaffolder`. Mantenerlo exige editar el agente, no un archivo Terraform. Es el costo consciente del patron "agente emisor" del harness (ADR-0019) y se acepta por consistencia.
- **Deriva potencial entre el HCL del agente y el del Paso 4 del scaffolder**: ambos deben mantenerse coherentes (mismos nombres de modulo, mismos locals `prefix`/`prefix_func`). Se mitiga documentando el contrato en este ADR.
- **Cada BC provisiona dos namespaces de Service Bus en vez de uno, duplicando el recurso** (nombres DNS publicos, planes de precios del namespace, gestion de topics/subscriptions). Mitigado por `infra-base-scaffolder` (siendo #130) que emite el HCL base del BC con ambas instancias ya parametrizadas.
- **El Context Map queda diferido**: la declaracion formal de que BCs existen y como se conectan entre si (que BCs producen eventos publicos, que BCs los consumen, asignacion de RBAC cross-BC) no se materializa en este ADR; un consumidor que integra multiples BCs debe gestionar manualmente las conexiones hasta que #131 y sus sucesores lo formalicen.

## Referencias

- ADR-0023 (topologia de dos namespaces ASB y Open Host Service): **raiz doctrinal de esta reforma**. Define el proposito de cada namespace (interno vs integracion), la separacion topologica (no por naming), la estrategia de acceso inter-BC (Open Host Service + Published Language) y la regla de portabilidad de eventos que cruzan un bus. La evolucion de ADR-0021 de un namespace a dos es la consecuencia directa de ADR-0023.
- Issue #130 (Actualizar scaffolders): materializa en HCL las dos instancias del modulo `service-bus` que este ADR fija como doctrina, y completa el detalle de RBAC Data Sender del productor en el namespace de integracion.
- ADR-0001 (Service Bus, topic por evento): el modulo `service-bus` con `topics_config` parametrizable lo respeta; ADR-0023 anade la dimension faltante — en que namespace (interno o integracion) vive cada topic segun el alcance del evento.
- ADR-0003 (stack ES: Marten + Wolverine + Postgres): el modulo `postgresql`; origen de `IPublicEventSender` / `IPrivateEventSender`.
- ADR-0013 (smoke tests contra entorno dev): el modulo `service-bus` admite subscriptions de smoke-tests via `topics_config`.
- ADR-0019 (skills publicados vs internos): el `infra-base-scaffolder` es del lado publicado, opera solo sobre el consumidor y lleva guard "cwd != Mefisto"; sin equivalente interno (Mefisto no tiene infraestructura propia).
- ADR-0020 (un App Service Plan por dominio): contrato de inputs del modulo `service-plan`.
- Origen: issue #93 (primer greenfield real `Bitakora.ControlAsistencia`). El sufijo de unicidad global en `postgresql`/`service-bus` se aplico en el esqueleto del entorno generado aqui (issue #94, ver seccion "El sufijo de unicidad vive en el ENTORNO"); relacionado con #99 (region de PostgreSQL) y con #92 (mismo patron de unicidad global para la Storage del tfstate en `bootstrap-backend.sh`).
- Reglas de naming y unicidad global (Microsoft Learn, "Naming rules and restrictions for Azure resources", `https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules`): `Microsoft.DBforPostgreSQL/servers` es scope **global**, 3-63 chars, minusculas/numeros/guiones, no puede empezar ni terminar en guion; `Microsoft.ServiceBus/namespaces` es scope **global**, 6-50 chars, alfanumericos/guiones, empieza con letra y termina en letra o numero. El scope **global** de ambos es la fuente verificable de que el nombre debe ser unico en todo Azure (no solo en el resource group), lo que motiva el sufijo.
- Region de PostgreSQL Flexible Server (issue #99): verificacion de SKUs por region via Azure CLI (Microsoft Learn, "az postgres flexible-server list-skus", `https://learn.microsoft.com/cli/azure/postgres/flexible-server`) -- "Lists available sku's in the given region"; y lista oficial de regiones del servicio (Microsoft Learn, "What is Azure Database for PostgreSQL flexible server?", `https://learn.microsoft.com/azure/postgresql/overview#azure-regions`), que muestra `eastus2` como soportada -- evidencia de que `LocationIsOfferRestricted` es una restriccion de oferta por suscripcion, no una indisponibilidad global de la region.
- Fuente de referencia de campo: `Bitakora.ControlAsistencia/infra/modules/*` y `infra/environments/dev/*` (de donde se generalizaron los tokens hardcodeados).
