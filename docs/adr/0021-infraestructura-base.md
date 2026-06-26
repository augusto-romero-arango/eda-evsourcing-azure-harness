# ADR-0021: Infraestructura base del consumidor - 7 modulos + esqueleto del entorno generados por un agente

- **Fecha**: 2026-06-25
- **Estado**: aceptado
- **Aplica a**: scaffolding de infraestructura del proyecto consumidor (Terraform), agentes `infra-base-scaffolder`, `domain-scaffolder` e `infra-writer`, flujo greenfield.

## Contexto

El marco despliega cada dominio como una Function App sobre un App Service Plan dedicado (ADR-0020), con su Storage Account, y los dominios comparten un Resource Group, monitoreo (Log Analytics + Application Insights), PostgreSQL (event store de Marten, ADR-0003) y un Service Bus namespace con topics por evento (ADR-0001). Tanto el `domain-scaffolder` (Paso 4) como el `infra-writer` **asumian preexistente** un conjunto de modulos Terraform base bajo `infra/modules/` del consumidor:

- `domain-scaffolder.md` (Paso 4) instancia `../../modules/storage`, `../../modules/service-plan` y `../../modules/function-app`, y referencia `module.resource_group`, `module.monitoring`, `module.service_bus` y `module.postgresql`.
- `infra-writer.md` instruye "lee los modulos existentes en `infra/modules/` que puedas reutilizar" y "lee el ambiente target en `infra/environments/<env>/`".

Pero **el harness no proveia esa base de ninguna forma**: ni plantilla copiable, ni generador, ni agente (verificado: no existe directorio `templates/` ni comando/agente que la cree). En el primer greenfield real (`Bitakora.ControlAsistencia`, arrancado desde cero) hubo que escribir a mano `infra/modules/*` y `infra/environments/dev/*` antes de poder provisionar nada. Sintomas concretos del vacio:

- Las **Notas del Paso 4** del scaffolder lo admitian explicitamente ("el modulo `postgresql` debe estar en la infraestructura base antes de ejecutar `terraform apply`"; "el modulo `modules/service-plan` debe aceptar los inputs `os_type`, `sku_name`, `worker_count`, `always_on` ... antes de ejecutar `terraform apply`"): convertian una dependencia dura del harness en una advertencia pasiva al usuario.
- El `terraform output` de un greenfield salia **vacio** porque nadie generaba el esqueleto del entorno con sus `outputs.tf`.
- El modulo `service-plan` que se escribio a mano en campo **incumplia el contrato de ADR-0020**: solo aceptaba `name`, `resource_group_name`, `location`, `sku_name`, `tags`, mientras el scaffolder le pasa ademas `os_type`, `worker_count` y `always_on`. Sin esos inputs, el `terraform validate` del Paso 4 falla.

## Decision

**El harness provee la infraestructura base mediante un agente generador (`infra-base-scaffolder`) que escribe el HCL inline con la tool `Write`, NO mediante un directorio de plantillas copiables.** El agente genera, en el consumidor:

1. Los **7 modulos base** bajo `infra/modules/`.
2. El **esqueleto del entorno** bajo `infra/environments/<env>/` (`main.tf`, `variables.tf`, `providers.tf`, `outputs.tf`), **sin** `backend.tf` (lo escribe `scripts/bootstrap-backend.sh`).

### Por que un agente y no un directorio de plantillas

1. **Es el unico patron de scaffold que el harness ya usa.** El `domain-scaffolder` no copia archivos de un `templates/`: emite el contenido inline desde su prompt (HCL del Paso 4, YAML del Paso 5). El harness no tiene directorio `templates/` ni mecanismo de copia. Crear uno seria inventar un mecanismo sin precedente (coherente con la separacion publicado/interno de ADR-0019: los agentes operan sobre el consumidor emitiendo contenido, no copiando blobs del plugin).
2. **El contenido no es estatico.** El `service-plan` debe cumplir ADR-0020 (que la plantilla de campo incumplia), la region de PostgreSQL depende del consumidor (algunas regiones restringen Flexible Server) y los nombres globales pueden necesitar un sufijo de unicidad. Un agente aplica reglas y lee `harness.config.json`/`CLAUDE.md` para parametrizar; un archivo copiado las congela.
3. **Encaja en el flujo greenfield existente.** `infra-bootstrap` ya orquesta "bootstrap del tfstate -> primer `/infra`". El esqueleto base es el eslabon que faltaba entre ambos: `bootstrap-backend.sh` crea el backend del `tfstate`; `infra-base-scaffolder` crea los modulos y el entorno; `/infra` aplica.

### Los 7 modulos base y su contrato

| Modulo | Recursos | Inputs principales | Outputs | `prevent_destroy` |
|---|---|---|---|---|
| `resource-group` | `azurerm_resource_group` | `name`, `location`, `tags` | `name`, `location`, `id` | no |
| `monitoring` | Log Analytics + Application Insights + action group + 2 alertas de costo | `name`, `resource_group_name`, `location`, `alert_action_group_email` (requerido), `daily_data_cap_in_gb`, `daily_cap_warning_percent`, `tags` | `connection_string` (sensitive), `instrumentation_key` (sensitive) | no |
| `postgresql` | `azurerm_postgresql_flexible_server` (v17, `B_Standard_B1ms`) + database + firewall `allow-azure-services` | `name`, `resource_group_name`, `location`, `administrator_login`, `administrator_password` (sensitive), `database_name`, `zone`, `tags` | `server_fqdn`, `database_name`, `administrator_login` | **si** |
| `service-bus` | `azurerm_servicebus_namespace` + topics/subscriptions parametrizables | `name`, `resource_group_name`, `location`, `sku`, `topics_config`, `tags` | `id`, `name`, `default_primary_connection_string` (sensitive), `topic_ids` | **si** |
| `service-plan` | `azurerm_service_plan` Linux | `name`, `resource_group_name`, `location`, `os_type`, `sku_name`, `worker_count`, `always_on`, `tags` | `id`, `always_on` | no |
| `storage` | `azurerm_storage_account` Standard LRS | `name`, `resource_group_name`, `location`, `tags` | `id`, `name`, `primary_connection_string` (sensitive), `primary_access_key` (sensitive) | **si** |
| `function-app` | `azurerm_linux_function_app` (.NET 10 isolated, SystemAssigned identity) | `name`, `resource_group_name`, `location`, `service_plan_id`, `storage_account_name`, `storage_account_connection_string`, `storage_account_access_key`, `app_insights_connection_string`, `app_settings`, `tags` | `id`, `name`, `principal_id` | no |

### El modulo `service-plan` cumple el contrato de ADR-0020 (resuelve la divergencia de campo)

El modulo base que genera el agente acepta los cuatro inputs de hosting del contrato de ADR-0020 (`os_type`, `sku_name`, `worker_count`, `always_on`), de modo que la llamada `module service_plan_<dominio>` que emite el `domain-scaffolder` en el Paso 4 valida sin la advertencia pasiva que antes se le pedia al usuario.

Nota sobre `always_on`: `azurerm_service_plan` no tiene un argumento `always_on` (esa propiedad vive en `site_config` de la Function App). El modulo `service-plan` **acepta** `always_on` por el contrato de ADR-0020 (centraliza los parametros de hosting por dominio) y lo **expone como output** (`always_on`) para que la Function App lo consuma en su `site_config`. Asi el contrato de inputs se honra literalmente y el valor no se pierde.

### El sufijo de unicidad vive en el ENTORNO, no en los modulos

Los nombres globalmente unicos (Storage Account; eventualmente PostgreSQL y Service Bus) se resuelven en `infra/environments/<env>/`, no dentro de los `main.tf` de los modulos. En campo, `module.postgresql` recibe `name = "psql-${local.prefix_func}"` y `module.service_bus` recibe `name = "sb-${local.prefix}"` (hardcodeados en el entorno); solo las Storage llevan `random_string`, tambien en el entorno (lo agrega el `domain-scaffolder` por dominio). Por eso el provider `random` se declara en el `providers.tf` del esqueleto. Esto deja la puerta abierta a que un issue posterior aplique el sufijo de unicidad en el esqueleto del entorno sin tocar los modulos.

### El esqueleto del entorno y sus outputs

El `infra/environments/<env>/main.tf` generado instancia **solo** los modulos compartidos (`resource_group`, `monitoring`, `postgresql`, `service_bus`); las instancias por dominio (`storage`, `service-plan`, `function-app`) las agrega el `domain-scaffolder` al crear cada dominio. El `outputs.tf` expone a nivel raiz, como minimo, `resource_group_name`, `service_bus_name` y `postgresql_fqdn`, de modo que `terraform output` no salga vacio tras el primer apply. El `providers.tf` declara `azurerm` y `random` y el bloque `provider "azurerm"`, pero **no** incluye `backend "azurerm"`: el backend lo materializa `scripts/bootstrap-backend.sh` en `backend.tf`, y duplicarlo haria fallar a Terraform por doble definicion de backend.

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
- **`terraform output` deja de salir vacio**: el esqueleto expone outputs raiz.
- **Idempotente**: re-ejecutable sin pisar personalizaciones.

### Negativas

- **El HCL base vive como prosa en el prompt del agente** (no como archivos `.tf` versionados del plugin), igual que el HCL del Paso 4 del `domain-scaffolder`. Mantenerlo exige editar el agente, no un archivo Terraform. Es el costo consciente del patron "agente emisor" del harness (ADR-0019) y se acepta por consistencia.
- **Deriva potencial entre el HCL del agente y el del Paso 4 del scaffolder**: ambos deben mantenerse coherentes (mismos nombres de modulo, mismos locals `prefix`/`prefix_func`). Se mitiga documentando el contrato en este ADR.

## Referencias

- ADR-0001 (Service Bus, topic por evento): el modulo `service-bus` con `topics_config` parametrizable lo respeta.
- ADR-0003 (stack ES: Marten + Wolverine + Postgres): el modulo `postgresql`.
- ADR-0013 (smoke tests contra entorno dev): el modulo `service-bus` admite subscriptions de smoke-tests via `topics_config`.
- ADR-0019 (skills publicados vs internos): el `infra-base-scaffolder` es del lado publicado, opera solo sobre el consumidor y lleva guard "cwd != Mefisto"; sin equivalente interno (Mefisto no tiene infraestructura propia).
- ADR-0020 (un App Service Plan por dominio): contrato de inputs del modulo `service-plan`.
- Origen: issue #93 (primer greenfield real `Bitakora.ControlAsistencia`). Bloquea a #94 (sufijo de unicidad en `postgresql`/`service-bus`, que se aplica en el esqueleto del entorno generado aqui); relacionado con #99 (region de PostgreSQL).
- Fuente de referencia de campo: `Bitakora.ControlAsistencia/infra/modules/*` y `infra/environments/dev/*` (de donde se generalizaron los tokens hardcodeados).
