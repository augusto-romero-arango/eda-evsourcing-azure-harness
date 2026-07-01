# ADR-0024: Modelo de eventos de bus (privado por defecto, publico opt-in) y custodia de ASB externos

- **Fecha**: 2026-07-01
- **Estado**: propuesta
- **Aplica a**: doctrina de mensajeria del marco; gobierno de los agentes `implementer`, `domain-scaffolder`, `infra-base-scaffolder` e `infra-writer`; contrato `harness.config.json`. Enmienda ADR-0021, ADR-0023 (decisiones #2 y #5) y ADR-0003.

## Contexto

ADR-0023 fijo dos piezas de la topologia de mensajeria: (a) cada Bounded Context provisiona **dos** namespaces de Azure Service Bus siempre (interno + integracion) y (b) el flujo de integracion inter-BC sigue Open Host Service (OHS): el productor publica en **su** namespace de integracion y los BCs externos se suscriben conectandose a el.

La operacion real de los proyectos que usan el harness no encaja con ese modelo:

- **Lo normal es que el evento se quede en el BC.** Un evento que lo consume otro dominio del mismo BC (o el mismo dominio) es el caso por defecto, no la excepcion.
- **El evento publico comun se publica a un ASB externo/compartido.** Existe un ASB (backbone de mensajeria del producto, u otra aplicacion) que el BC no posee pero al que tiene acceso porque se lo compartieron. El BC publica ahi; el acceso se gestiona de forma administrativa, fuera del ciclo de implementacion. Este es el caso frecuente de "evento publico".
- **Hostear un namespace de integracion propio (el modelo OHS de ADR-0023 #5) tiene cero casos hoy.** Que un BC exponga su propio namespace de integracion, sea dueno del topic y cree la subscription del consumidor externo es una posibilidad real pero excepcional.

Ademas, dos precisiones de comportamiento que ADR-0023 no fijaba:

- **Todo evento de bus cruza fisicamente el ASB**, aun cuando productor y consumidor viven en el mismo Function App. No hay entrega en memoria de Wolverine entre handlers del mismo proceso. Esto aplica a los eventos con marker de bus (`IPrivateEvent` / `IPublicEvent`).
- **Los comandos no cambian**: se siguen mediando en proceso por Wolverine (`ICommandRouter`); no cruzan el ASB por esta regla.
- **Los eventos de event sourcing** (los del aggregate) viven en el event store de Marten con modelo rico y **no cruzan ASB**; quedan fuera del alcance de este ADR (frontera de ADR-0012 intacta).

Provisionar siempre un namespace de integracion que casi nunca se usa es costo y superficie de administracion de Terraform innecesarios, y desalinea el lenguaje del harness respecto de como se opera de verdad.

## Decision

### 1. Tres categorias de evento

| Categoria | Marker | Destino | Forma | Cruza ASB |
|---|---|---|---|---|
| Event sourcing (aggregate) | ninguno | event store de Marten | modelo rico | No |
| Privado | `IPrivateEvent` | ASB propio del BC | plano y portable | Si, siempre |
| Publico | `IPublicEvent` | ASB externo (P1) o namespace de integracion propio (P2) | plano y portable | Si |

El criterio semantico publico/privado es el de la frontera de Bounded Context (ADR-0023 decision #4, materializado en el criterio del `implementer`): un evento es **publico** si lo consume un dominio de **otro** BC; es **privado** si lo consume un dominio del **mismo** BC, aunque sea un dominio distinto al productor. Este ADR no cambia ese criterio; cambia el **transporte** de cada categoria.

### 2. Privado por defecto

El ASB propio del BC es el unico namespace que se provisiona por defecto (always-on). Todo evento privado se publica a ese ASB y se consume via `[ServiceBusTrigger]`, **aun si el consumidor esta en el mismo Function App que el productor**: no hay atajo en memoria. Los comandos se siguen mediando en proceso por Wolverine, sin cambio.

### 3. Publico caso P1 (comun): publicar a un ASB externo/compartido

Un evento publico se publica a un ASB que el BC **no posee** (backbone del producto u otra aplicacion). Consecuencias:

- El harness **no provisiona** ese ASB ni sus topics/subscriptions; son propiedad de quien administra ese ASB.
- El acceso (RBAC, credenciales) se solicita como **accion administrativa**, fuera del ciclo de implementacion. No es responsabilidad de los agentes del harness.
- Un BC puede integrarse con **varios** ASB externos a la vez. El wiring soporta **N brokers nombrados**, uno por ASB externo, cada uno con su propia cadena de conexion.

### 4. Publico caso P2 (excepcion): hostear un namespace de integracion propio

Un BC puede exponer su propio namespace de integracion (ser el "host" OHS de ADR-0023 #5: dueno del topic, creador de la subscription del consumidor externo). Este caso es **excepcional**:

- **Default-off duro**: el `infra-base-scaffolder` y el pipeline IaC **no** provisionan el namespace de integracion a menos que exista un opt-in explicito.
- El opt-in es un **flag explicito en `harness.config.json`**. No requiere un ADR de justificacion; la justificacion es el acto deliberado de declararlo. (El detalle fino del opt-in por-evento y la provision del topic + subscription del consumidor externo se disena cuando exista el primer caso real; ver "Trabajo diferido".)

### 5. Custodia de cadenas de conexion a ASB externos

Las cadenas de conexion a ASB externos (P1 y consumo externo) se custodian en **Azure Key Vault** y se referencian desde los app settings de la Function App con `@Microsoft.KeyVault(...)`. La cadena **nunca** queda en texto plano en `harness.config.json`, en app settings literales ni en el estado de Terraform.

### 6. Wiring

- El broker del ASB propio del BC se registra siempre (broker default).
- Cada ASB externo (P1) y, si aplica, el namespace de integracion propio (P2) se registran como **brokers nombrados opt-in**, uno por ASB, cada uno leyendo su cadena de conexion custodiada.

## Alternativas consideradas

### Alt 1: mantener "dos namespaces por BC, always-on" (ADR-0023 #2)

**Descartada**: provisiona una superficie (el namespace de integracion) que la operacion real casi nunca usa; el evento publico comun no vive en un namespace de integracion propio sino en un ASB externo/compartido. El costo de administracion de un recurso ocioso no se justifica.

### Alt 2: entrega en memoria de eventos intra-proceso (Wolverine local)

**Descartada**: permitir que un evento se entregue en memoria a un handler del mismo proceso rompe la uniformidad y la trazabilidad. Se prefiere que todo evento cruce fisicamente el ASB, con el mismo mecanismo de publicacion y consumo independientemente de la coubicacion de productor y consumidor.

### Alt 3: exigir un ADR de justificacion para habilitar P2

**Descartada**: demasiada ceremonia para un caso con cero ocurrencias. Un flag `default-off` en `harness.config.json` es suficiente friccion: nada se expone sin una declaracion explicita y deliberada.

## Consecuencias

### Positivas

- **Menos infraestructura por defecto**: un namespace por BC en vez de dos; el de integracion solo cuando se sustenta.
- **Modelo alineado a la operacion real**: el publico comun (P1) se modela como lo que es —publicacion a un ASB ajeno con cadena custodiada— y no como un host propio.
- **Custodia explicita de secretos**: Key Vault como unico lugar de las cadenas externas.
- **Autonomia**: el harness no asume propiedad ni administracion de ASB que no le pertenecen.

### Negativas

- **Trabajo derivado de enmienda** a varios ADRs y agentes (ver abajo).
- **Mayor trafico en el ASB propio**: al no haber entrega en memoria, todo evento privado round-trip por el bus, aun intra-Function App. Es una decision consciente a favor de la uniformidad y la trazabilidad.

### Enmiendas que este ADR ordena

Al implementar estas enmiendas, el contenido superado se **elimina del cuerpo** del ADR afectado; no se marca como "obsoleto" ni se deja lenguaje ambiguo en el cuerpo. El registro del cambio vive solo en la seccion de control de cambios del ADR correspondiente. (Convencion del proyecto: evitar que se lean por error decisiones superadas.)

- **ADR-0021** (infraestructura base): eliminar del cuerpo la provision always-on del namespace de integracion. El `infra-base-scaffolder` genera un namespace (el propio del BC); el de integracion pasa a opt-in.
- **ADR-0023 decision #2**: eliminar "cada BC provisiona exactamente dos namespaces". Queda uno por defecto (el propio) + integracion excepcional (P2).
- **ADR-0023 decision #5** (OHS): reencuadrar como el caso **P2** (excepcion), no el default. Anadir el caso P1 (publicar a ASB externo).
- **ADR-0003** (wiring): eliminar el wiring fijo de dos brokers (`HabilitarAzureServiceBusParaServerLess` interno + `AgregarAzureServiceBusNombradoServerless("integracion", ...)` siempre). Queda broker propio por defecto + N brokers externos nombrados opt-in.
- **`agents/implementer.md`**: realinear la guia de enrutamiento de infraestructura — el publico comun (P1) va a un ASB externo por cadena de conexion custodiada, no a `module "service_bus_integracion"`. El criterio semantico publico/privado (issue #156) queda intacto.

### Trabajo diferido

- **Diseno fino de P2**: la declaracion por-evento del canal publico, la provision del topic y la creacion de la subscription del consumidor externo se disenan cuando exista el primer caso real que lo sustente.
- **Context Map con "alcance" de ASB**: el registro en `harness.config.json` de que ASB alcanza el BC y con que rol (propio / externo-compartido / externo-ajeno) es el vehiculo para el consumo inter-BC (issue #158) y para el wiring de N brokers externos. Su materializacion se descompone a partir de este ADR una vez aceptado.

## Referencias

- ADR-0023 (Bounded Context, topologia de dos namespaces ASB y OHS): este ADR enmienda sus decisiones #2 y #5 y reafirma su decision #4 (criterio publico/privado por frontera de BC).
- ADR-0021 (infraestructura base): este ADR enmienda la provision de namespaces del `infra-base-scaffolder`.
- ADR-0003 (stack ES: Marten + Wolverine + Postgres): este ADR enmienda el wiring de brokers de Azure Service Bus.
- ADR-0012 (encapsulamiento y frontera de serializacion event store vs bus): frontera intacta; los eventos de event sourcing no cruzan el bus.
- ADR-0022 (autenticacion de CI hacia Azure por OIDC): el acceso runtime a ASB externos se gestiona administrativamente y queda fuera del ciclo de implementacion; ADR-0022 cubre el eje CI/deploy.
- issue #156 (criterio publico/privado BC-aware en `implementer.md`): el criterio semantico que este ADR reafirma.
- issue #158 (consumo de eventos publicos de otro BC): se reencuadra sobre el modelo de este ADR.
- "Use Key Vault references for App Service and Azure Functions" — referencias `@Microsoft.KeyVault(...)` en app settings. https://learn.microsoft.com/azure/app-service/app-service-key-vault-references

## Control de cambios

- 2026-07-01: creacion como `propuesta`.
