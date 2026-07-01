# ADR-0024: Modelo de eventos de bus del Bounded Context (privado propio, publico via backbone compartido, integracion externa diferida)

- **Fecha**: 2026-07-01
- **Estado**: aceptado
- **Aplica a**: doctrina de mensajeria del marco; gobierno de los agentes `implementer`, `domain-scaffolder`, `infra-base-scaffolder` e `infra-writer`; contrato `harness.config.json`. Enmienda ADR-0021, ADR-0023 (decisiones #2 y #5) y ADR-0003.

## Contexto

ADR-0023 fijo dos piezas de la topologia de mensajeria: (a) cada Bounded Context provisiona **dos** namespaces de Azure Service Bus siempre (interno + integracion) y (b) el flujo inter-BC sigue Open Host Service (OHS): el productor publica en **su** namespace de integracion y los externos se suscriben conectandose a el.

La operacion real de los proyectos que usan el harness no encaja con ese modelo. Clasificando los ASB que un BC toca por su **alcance** (quien tiene dominio sobre ellos):

- **Propio del BC**: el evento se queda dentro del BC. Es el caso normal y por defecto.
- **Compartido del producto**: existe un ASB provisionado por el equipo de **infra** para que todos los BC del producto intercambien mensajes. Ningun BC lo posee; el **productor** es dueno de sus topics y el **consumidor** crea sus subscriptions, con permisos baseline que otorga infra. Este es el caso **comun** de evento publico.
- **Verdaderamente externo**: integracion con una aplicacion ajena al producto. Tiene **dos direcciones** y **ninguna tiene casos hoy**:
  - que una app ajena consuma de nosotros (nosotros hostearíamos un namespace de integracion propio: topic + subscription para el externo);
  - que nosotros consumamos de un ASB de otra app que no conocemos ni controlamos (los accesos los administra la otra app).

Ambos extremos verdaderamente externos son simetricos y cero-caso: se tratan como **una misma excepcion diferida**.

Ademas, dos precisiones de comportamiento que ADR-0023 no fijaba:

- **Todo evento de bus cruza fisicamente el ASB**, aun cuando productor y consumidor viven en el mismo Function App: no hay entrega en memoria de Wolverine. Aplica a los eventos con marker de bus (`IPrivateEvent` / `IPublicEvent`).
- **Los comandos no cambian**: se siguen mediando en proceso por Wolverine (`ICommandRouter`); no cruzan el ASB por esta regla.
- **Los eventos de event sourcing** (los del aggregate) viven en el event store de Marten con modelo rico y **no cruzan ASB**; quedan fuera del alcance de este ADR (frontera de ADR-0012 intacta).

Provisionar siempre un namespace de integracion por BC que casi nunca se usa es costo y superficie de administracion de Terraform innecesarios, y desalinea el lenguaje del harness respecto de como se opera de verdad.

## Decision

### 1. Alcance de cada ASB

| Alcance | Quien lo administra | Topics | Subscriptions | Caso |
|---|---|---|---|---|
| **Propio del BC** (interno) | el BC | el BC | el BC | comun (eventos privados) |
| **Compartido del producto** | infra (permisos baseline) | los crea el **productor** | las crea el **consumidor** | comun (eventos publicos) |
| **Verdaderamente externo** | otra app | segun direccion | segun direccion | excepcion, cero casos, diferido |

### 2. Tres categorias de evento

| Categoria | Marker | Destino | Forma | Cruza ASB |
|---|---|---|---|---|
| Event sourcing (aggregate) | ninguno | event store de Marten | modelo rico | No |
| Privado | `IPrivateEvent` | ASB propio del BC | plano y portable | Si, siempre |
| Publico | `IPublicEvent` | backbone compartido (comun) o integracion externa (diferido) | plano y portable | Si |

El criterio semantico publico/privado es el de la frontera de Bounded Context (ADR-0023 decision #4, materializado en el `implementer` via issue #156): un evento es **publico** si lo consume un dominio de **otro** BC; es **privado** si lo consume un dominio del **mismo** BC, aunque sea un dominio distinto al productor. Este ADR no cambia ese criterio; cambia el **transporte** de cada categoria.

### 3. Privado por defecto: el ASB propio del BC

El BC tiene **un** namespace interno, **compartido por todos sus dominios** (Function Apps, ADR-0020), provisionado siempre (always-on). Es el unico ASB que el harness provisiona por defecto. Todo evento privado se publica a ese ASB y se consume via `[ServiceBusTrigger]`, **aun si el consumidor esta en el mismo Function App que el productor**: no hay atajo en memoria. Los comandos se siguen mediando en proceso por Wolverine, sin cambio.

### 4. Publico comun: el backbone compartido del producto

El evento publico comun se publica al ASB compartido del producto, provisionado por infra. Consecuencias:

- Infra es dueno del namespace; el **productor** crea sus topics y el **consumidor** crea sus subscriptions, con permisos baseline que otorga infra. La convencion de naming de subscriptions de ADR-0005 (`{consumidor}-escucha-{productor}`) aplica por igual en el backbone compartido.
- El acceso al backbone se hace por **cadena de conexion**, custodiada segun la decision #6.
- No es opt-in: es el camino publico normal del producto.

### 5. Integracion verdaderamente externa (diferida)

La integracion con una app ajena al producto, en cualquiera de sus dos direcciones (hostear un namespace de integracion propio para un consumidor externo, o consumir de un ASB ajeno que no controlamos), es una **excepcion sin casos hoy**:

- **Default-off duro**: nada se provisiona ni se wirea a menos que exista un opt-in explicito (flag en `harness.config.json`). No requiere un ADR de justificacion; la justificacion es el acto deliberado de declararlo.
- **Diseno fino diferido** hasta que exista el primer caso real (provision del namespace de integracion propio + subscription del consumidor externo en la direccion "nos consumen"; gestion administrativa de accesos + custodia de cadena en la direccion "consumimos de un ajeno").

### 6. Custodia de cadenas de conexion

Todas las cadenas de conexion de Azure Service Bus que el BC toca -- la del ASB **propio (interno)**, la del backbone compartido y la de cualquier ASB externo -- se custodian en **Azure Key Vault** y se referencian desde los app settings de la Function App con `@Microsoft.KeyVault(...)`. El **valor** del secreto lo coloca infra / un admin (el acceso se gestiona administrativamente); el harness provisiona (a) la **referencia** en app settings y (b) el **permiso de la managed identity** de la Function App para leer ese secreto de Key Vault. La cadena **nunca** queda en texto plano en `harness.config.json`, en app settings literales ni en el estado de Terraform. Esta custodia es una **instancia** del principio general de custodia de secretos (ADR-0025): Key Vault no es exclusivo de las cadenas de ASB, es el almacen general de secretos del BC; el mecanismo alterno para secretos que el runtime necesita antes de resolver referencias de Key Vault es la **identidad administrada** (ADR-0025 decision #3).

### 7. Wiring

- El broker del ASB propio del BC se registra siempre (broker default).
- El backbone compartido y, si aplica, cada ASB externo se registran como **brokers nombrados**, uno por ASB, leyendo su cadena de conexion custodiada.
- El wiring se mantiene **por cadena de conexion**, coherente con el paquete `Cosmos.EventDriven.CritterStack.AzureServiceBus` actual. El acceso por managed identity queda fuera de alcance de este ADR (ver Alt 4).

## Alternativas consideradas

### Alt 1: mantener "dos namespaces por BC, always-on" (ADR-0023 #2)

**Descartada**: provisiona una superficie (el namespace de integracion por BC) que la operacion real casi nunca usa; el evento publico comun no vive en un namespace de integracion propio sino en el backbone compartido del producto.

### Alt 2: entrega en memoria de eventos intra-proceso (Wolverine local)

**Descartada**: permitir que un evento se entregue en memoria a un handler del mismo proceso rompe la uniformidad y la trazabilidad. Todo evento cruza fisicamente el ASB, independientemente de la coubicacion de productor y consumidor. (Aplica solo a eventos; los comandos se siguen mediando en proceso.)

### Alt 3: exigir un ADR de justificacion para la integracion externa

**Descartada**: demasiada ceremonia para un caso con cero ocurrencias. Un flag `default-off` en `harness.config.json` es suficiente friccion.

### Alt 4: acceso a Azure Service Bus por managed identity

**Diferida (norte, no ahora)**: es el best-practice de Azure (sin secretos SAS, RBAC least-privilege) y alinea con ADR-0022 (OIDC) y ADR-0023 #5 (Data Sender/Receiver). Pero el paquete `Cosmos.EventDriven.CritterStack.AzureServiceBus` (sobre `WolverineFx.AzureServiceBus` 6.1.0) solo expone wiring **por cadena de conexion**; no referencia `Azure.Identity` ni acepta `TokenCredential` / `fullyQualifiedNamespace`. El consumo via `[ServiceBusTrigger]` si soporta identidad de forma nativa, pero la publicacion (Wolverine) no, sin un overload nuevo en el paquete. Se decide **no tocar el paquete por ahora** y mantener cadenas de conexion. MI queda como direccion futura cuando se evolucione el paquete.

## Consecuencias

### Positivas

- **Menos infraestructura por defecto**: un namespace interno por BC; no se provisiona un namespace de integracion por BC.
- **Modelo alineado a la operacion real**: el publico comun se modela como publicacion al backbone compartido; la integracion verdaderamente externa (ambas direcciones) es la excepcion diferida que de verdad es.
- **Custodia explicita de secretos**: Key Vault como unico lugar de las cadenas de conexion.
- **Sin cambio de paquete**: el wiring por cadena de conexion es compatible con el paquete actual; cero trabajo cross-repo para este ADR.

### Negativas

- **La cadena de conexion sigue siendo un secreto**: se mantiene la superficie de rotacion/fuga (mitigada por Key Vault), en vez del ideal sin-secreto de managed identity. Deuda consciente (Alt 4).
- **Mayor trafico en el ASB propio**: al no haber entrega en memoria, todo evento privado round-trip por el bus, aun intra-Function App. Decision consciente a favor de uniformidad y trazabilidad.
- **Trabajo derivado de enmienda** a varios ADRs y agentes (ver abajo).

### Enmiendas que este ADR ordena

Al implementar estas enmiendas, el contenido superado se **elimina del cuerpo** del ADR afectado; no se marca como "obsoleto" ni se deja lenguaje ambiguo en el cuerpo. El registro del cambio vive solo en la seccion de control de cambios del ADR correspondiente. (Convencion del proyecto: evitar que se lean por error decisiones superadas.)

- **ADR-0021** (infraestructura base): eliminar del cuerpo la provision del namespace de integracion por BC. El `infra-base-scaffolder` genera un namespace interno por BC; no provisiona namespace de integracion.
- **ADR-0023 decision #2**: eliminar "cada BC provisiona exactamente dos namespaces". Queda un namespace interno por BC; lo publico viaja por el backbone compartido (comun) o por integracion externa (diferida).
- **ADR-0023 decision #5** (OHS): reencuadrar como el caso **diferido** de "nos consumen desde afuera" (hostear namespace de integracion propio), no como el default.
- **ADR-0003** (wiring): eliminar el wiring fijo de dos brokers por BC. Queda broker interno por defecto + N brokers nombrados (backbone compartido / externos) por cadena de conexion.
- **`agents/implementer.md`**: realinear la guia de enrutamiento de infraestructura — el publico comun va al backbone compartido por cadena de conexion custodiada, no a un `module "service_bus_integracion"` por BC. Revisar el nombre de app setting `SERVICE_BUS_CONNECTION_INTEGRACION` (que implicaba un namespace de integracion por BC) hacia una cadena del backbone compartido. El criterio semantico publico/privado (issue #156) queda intacto.

### Trabajo diferido

- **Diseno fino de la integracion verdaderamente externa** (ambas direcciones): cuando exista el primer caso real que lo sustente.
- **Context Map con "alcance" de ASB** (propio / compartido / externo) en `harness.config.json`: vehiculo para declarar el backbone compartido y, en su momento, las integraciones externas; base del wiring de N brokers y del reencuadre de issue #158. Se descompone a partir de este ADR una vez aceptado.
- **Migracion a managed identity** (Alt 4): cuando se evolucione el paquete para exponer wiring por identidad.

## Referencias

- ADR-0023 (Bounded Context, topologia de dos namespaces ASB y OHS): este ADR enmienda sus decisiones #2 y #5 y reafirma su decision #4 (criterio publico/privado por frontera de BC).
- ADR-0021 (infraestructura base): este ADR enmienda la provision de namespaces del `infra-base-scaffolder`.
- ADR-0003 (stack ES: Marten + Wolverine + Postgres): este ADR enmienda el wiring de brokers de Azure Service Bus (se mantiene por cadena de conexion).
- ADR-0012 (encapsulamiento y frontera de serializacion event store vs bus): frontera intacta; los eventos de event sourcing no cruzan el bus.
- ADR-0022 (autenticacion de CI hacia Azure por OIDC): el acceso runtime a ASB (propio/interno, backbone y externos) se gestiona administrativamente y por cadena de conexion custodiada; la migracion a identidad (Alt 4) se enmarcaria en el mismo espiritu identity-based cuando el paquete lo soporte.
- ADR-0025 (custodia de secretos): generaliza la decision #6 -- Key Vault no es exclusivo de las cadenas de ASB, es el almacen general de secretos del BC -- e incluye explicitamente la cadena del ASB propio/interno en la custodia.
- issue #156 (criterio publico/privado BC-aware en `implementer.md`): el criterio semantico que este ADR reafirma.
- issue #158 (consumo de eventos publicos de otro BC): se reencuadra sobre el modelo de este ADR (el caso comun es el backbone compartido).
- Paquete `Cosmos.EventDriven.CritterStack.AzureServiceBus` (`WolverineFx.AzureServiceBus` 6.1.0): el wiring solo acepta cadena de conexion; base de la decision de Alt 4.
- "Use Key Vault references for App Service and Azure Functions" — referencias `@Microsoft.KeyVault(...)` en app settings. https://learn.microsoft.com/azure/app-service/app-service-key-vault-references

## Control de cambios

- 2026-07-01: creacion como `propuesta` (incorpora la revision inicial con el equipo: simplificacion de la integracion externa a una unica excepcion diferida de dos direcciones; acceso por cadena de conexion sin cambio de paquete; managed identity como norte diferido).
- 2026-07-01: `aceptado` tras la revision con el equipo.
- 2026-07-01: enmendado (issue #184, mandato de ADR-0025) para generalizar la decision #6: la custodia en Key Vault deja de presentarse como exclusiva de las cadenas de ASB y remite a ADR-0025 como doctrina general; se incluye explicitamente la cadena del ASB propio/interno, que el cuerpo omitia.
