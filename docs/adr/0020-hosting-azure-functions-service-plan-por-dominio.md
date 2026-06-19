# ADR-0020: Hosting de Azure Functions - un App Service Plan por Function App (dominio)

- **Fecha**: 2026-06-18
- **Estado**: aceptado
- **Aplica a**: infraestructura del proyecto consumidor (Terraform), scaffolding de dominios, investigacion de bugs del entorno desplegado.

## Contexto

El marco despliega **una Function App por dominio** (ver ADR-0006). Cada Function App corre sobre Marten + Wolverine + PostgreSQL en modo serverless (ver ADR-0003) y publica sus eventos a Service Bus a traves del outbox transaccional de Wolverine (ver ADR-0001).

Hasta ahora el harness no tenia una directiva canonica de hosting: `domain-scaffolder.md` y `bug-investigator.md` apuntaban vagamente "al ADR de hosting del proyecto consumidor", y la guia informal permitia que varias Function Apps **compartieran un mismo App Service Plan** en dev para ahorrar costo. El scaffolder generaba todos los `module.function_app_*` apuntando a un unico `module.service_plan.id`.

### Sintoma observado (origen: issue #43)

En `Bitakora.ControlAsistencia`, dos Function Apps (`control-horas` y `programacion`) compartian un plan **B1 (1 core)**. Las smoke tests (ADR-0013) fallaban de forma intermitente: timeouts, health checks que tardaban hasta 148 s, fallos esporadicos. Azure Monitor mostro la CPU del plan **saturada en reposo**: con 0 requests HTTP y 0 mensajes de Service Bus en cola, la CPU promediaba ~60 % con picos de 96-100 %.

### Causa raiz

Wolverine corre en `DurabilityMode.Solo`. En ese modo, **cada worker** levanta el agente de durabilidad (la maquinaria del outbox/inbox transaccional) que **poll-ea PostgreSQL en background de forma continua** para recuperar y reenviar mensajes pendientes. Ese agente es *always-on*: trabaja aunque no haya trafico de entrada.

Con dos Function Apps en un solo core, hay **dos agentes de durabilidad always-on compitiendo por el mismo nucleo**: un problema de *noisy neighbor* mutuo. Ninguna app tiene un nucleo dedicado, el poll de una ahoga al de la otra, y el resultado son los timeouts y fallos de health observados. Azure documenta explicitamente este modo de falla: las apps que comparten plan tienen aislamiento de rendimiento "bajo a medio, potencialmente sujeto a problemas de noisy neighbor" [3], y comparten las mismas VM/recursos de computo del plan [4].

### Por que no se puede "simplemente escalar out"

La salida natural a un plan saturado seria escalar horizontalmente (mas instancias). **Aqui esta prohibido**: `DurabilityMode.Solo` le indica a Wolverine que es el **unico nodo** del sistema, por lo que omite la eleccion de lider y la asignacion de agentes entre nodos, y ejecuta toda la durabilidad localmente. Si se escalara a N instancias, cada una se creeria "sola" y procesaria el mismo outbox/inbox -> doble procesamiento de eventos, perdida de la garantia de entrega-una-vez. El modo `Solo` y el escalado horizontal son **mutuamente excluyentes**.

Conclusion: con `Solo`, el unico eje de crecimiento disponible es el **vertical** (mas core / mas SKU), y la unica forma de garantizar un nucleo no contendido por dominio es **aislar cada Function App en su propio plan**.

## Decision

**Cada Function App (cada dominio) corre en su propio App Service Plan dedicado. Los planes no se comparten entre dominios.**

Esto alinea el harness con la guia oficial de Azure:

- App Service recomienda aislar una app en un plan nuevo cuando "la app es intensiva en recursos" o cuando "quieres escalar la app independientemente de las otras apps del plan" [1]. Ambas condiciones se cumplen: el agente de durabilidad always-on hace a cada app intensiva en CPU aun en reposo, y cada dominio evoluciona su carga por separado.
- La guia de organizacion de funciones de Azure Functions indica que funciones con **perfiles de carga distintos** deben desplegarse en function apps separadas "para que obtengan sus propios conjuntos de recursos y escalen independientemente" [2]. Dos dominios distintos son, por definicion, dos perfiles de carga distintos.

### Proscripciones (que NO usar)

- **No usar el plan Consumption `Y1`** con .NET 10+ / isolated worker para estos dominios. El modelo de escalado dinamico del Consumption es incompatible con un proceso que mantiene un agente de durabilidad always-on con estado de leadership: el host puede apagar la instancia entre invocaciones, matando el poll del outbox. El piso es un plan dedicado (Basic o superior).
- **No usar Wolverine `DurabilityMode.Serverless`**. Ese modo **desactiva el outbox/inbox durable transaccional**: rompe la garantia de que un evento persistido en Marten se publica a Service Bus de forma confiable (ver ADR-0001 y ADR-0003). El marco depende del outbox durable; `Serverless` lo elimina. El modo correcto sigue siendo `Solo`.

### Defaults del plan

| Parametro | Default | Notas |
|---|---|---|
| `sku_name` | `B1` | Basic, 1 core dedicado por dominio. Piso valido del marco. |
| `worker_count` | `1` | **No escalar out.** `Solo` exige un unico nodo (ver restriccion dura arriba). |
| `os_type` | `Linux` | Coherente con el publish `-r linux-x64 --self-contained false` del marco. |
| `always_on` | `false` en dev / **evaluar `true` en prod** | En dev se acepta OFF para ahorrar; en prod evaluar ON para evitar que el host descargue el worker e interrumpa el poll del outbox. |

**Trade-off de costo**: dos planes B1 cuestan aproximadamente lo mismo que un B2 (`2x B1 ~= 1x B2`). A igualdad de gasto, dos B1 separados dan a cada dominio un **core dedicado** y **aislamiento de fallos** (un dominio saturado no tumba al otro), mientras que un B2 compartido vuelve a poner a los dos agentes de durabilidad a competir por los mismos dos cores. El aislamiento se prioriza sobre la densidad.

### Contrato del modulo `modules/service-plan` del consumidor

El proyecto consumidor expone un modulo Terraform `modules/service-plan` que el scaffolder instancia **una vez por dominio**. Contrato esperado de inputs:

| Input | Tipo | Default sugerido |
|---|---|---|
| `sku_name` | `string` | `"B1"` |
| `worker_count` | `number` | `1` |
| `os_type` | `string` | `"Linux"` |
| `always_on` | `bool` | `false` (dev) |

El `id` del plan se inyecta en el `module.function_app_<dominio>` correspondiente (campo `service_plan_id`). Cada `module.service_plan_<dominio>` es independiente; no hay un plan compartido `module.service_plan` global.

### Alcance de la decision

- **Aplica a dominios nuevos**: el scaffolder genera un plan dedicado por dominio desde su creacion.
- **Aplica a la proxima reprovision** (p. ej. al provisionar `prod`): se aprovisiona un plan por dominio.
- **NO fuerza una migracion inmediata del `dev` existente**. El dev de `Bitakora.ControlAsistencia` puede seguir con plan compartido hasta su proxima reprovision; la directiva no obliga a tocar infraestructura ya desplegada y estable. Cuando los fallos de noisy neighbor sean dolorosos, la salida es separar los planes (no agrandar el plan compartido).

## Alternativas consideradas

### Alt 1: plan compartido + subir de SKU (B1 -> B2/B3)

Mantener un plan unico y escalar verticalmente para dar mas cores al conjunto.

**Descartado**: no resuelve el aislamiento de fallos. Un B2 da dos cores pero los dos agentes de durabilidad siguen compartiendolos; un dominio que ademas reciba carga real vuelve a ahogar al vecino. Y a igualdad de costo (`2x B1 ~= 1x B2`) la opcion compartida da estrictamente menos aislamiento.

### Alt 2: una sola Function App con todos los dominios

Colapsar los dominios en una unica app para tener un solo agente de durabilidad.

**Descartado**: viola ADR-0006 (una Function App por dominio) y el principio de que cada dominio es duenno de su deploy, su escalado y su ciclo de vida. Acopla deploys y reintroduce el riesgo de que un dominio tumbe a los demas dentro del mismo proceso.

### Alt 3: migrar a `DurabilityMode.Balanced` + escalado horizontal

Usar el modo balanceado de Wolverine (con eleccion de lider y reparto de agentes entre nodos) para permitir escalar out.

**Descartado para esta decision**: es un cambio de arquitectura de runtime mayor (requiere validar leadership, reparto de agentes y reentrancia bajo Azure Functions isolated), fuera del alcance de fijar la directiva de hosting. Queda como evolucion futura si un dominio necesita genuinamente escalar horizontal; mientras tanto, `Solo` + plan dedicado es la combinacion soportada.

## Consecuencias

### Positivas

- **Core dedicado por dominio**: el agente de durabilidad always-on de cada dominio ya no compite con el de otro. Desaparece el noisy neighbor en reposo que originaba los fallos de smoke.
- **Aislamiento de fallos**: un dominio saturado (deploy, pico de mensajes, bug de CPU) no degrada a los demas. El blast radius queda contenido al dominio.
- **Escalado vertical independiente**: cada dominio sube de SKU segun su propia carga sin arrastrar a los vecinos.
- **Alineado con la guia oficial de Azure** [1][2] y con el modelo de aislamiento de rendimiento alto [3].
- **Directiva canonica unica**: el scaffolder y el bug-investigator dejan de apuntar a "el ADR del consumidor" y anclan a este ADR del marco.

### Negativas

- **Mas planes que gestionar**: N dominios -> N planes en Terraform. Mitigado por el modulo `modules/service-plan` reutilizable y la generacion automatica del scaffolder.
- **Costo nominal mayor en numero de planes** (aunque neutral en computo: `2x B1 ~= 1x B2`). En dev se mitiga con `always_on = false`.
- **Techo de escalado por `Solo`**: ningun dominio puede escalar horizontal mientras use `DurabilityMode.Solo`. Si un dominio rebasa la capacidad vertical de su plan, requerira el cambio de runtime de la Alt 3 (futuro).
- **Deuda en dev existente**: el dev compartido de `Bitakora.ControlAsistencia` queda fuera de la nueva directiva hasta su proxima reprovision; convive temporalmente con el patron viejo.

## Referencias

- **[1]** "What are Azure App Service plans? - Decision to use a new plan or an existing plan for an app" -- aislar la app en un plan nuevo cuando es intensiva en recursos o escala independiente. https://learn.microsoft.com/azure/app-service/overview-hosting-plans#decision-to-use-a-new-plan-or-an-existing-plan-for-an-app
- **[2]** "Improve the performance and reliability of Azure Functions - Function organization best practices" -- funciones con perfiles de carga distintos van en function apps separadas con sus propios recursos. https://learn.microsoft.com/azure/azure-functions/performance-reliability#function-organization-best-practices
- **[3]** "Azure App Service and Azure Functions considerations for multitenancy - Isolation models" -- apps con plan compartido: aislamiento de rendimiento bajo-medio, sujeto a noisy neighbor; un plan por inquilino: aislamiento alto. https://learn.microsoft.com/azure/architecture/guide/multitenant/service/app-service#isolation-models
- **[4]** "What are Azure App Service plans? - Considerations for running and scaling an app" -- las apps de un mismo plan comparten las mismas VM/recursos de computo. https://learn.microsoft.com/azure/app-service/overview-hosting-plans#considerations-for-running-and-scaling-an-app
- **[5]** "Best practices for reliable Azure Functions - Choose the correct hosting plan" -- planes de hosting disponibles (Flex Consumption, Premium, Dedicated, Consumption). https://learn.microsoft.com/azure/azure-functions/functions-best-practices
- Origen: issue #43, investigacion de fallos intermitentes de smoke en `Bitakora.ControlAsistencia` (CPU del plan B1 compartido saturada en reposo).
- ADR-0001 (Service Bus, topic por evento): el outbox durable de Wolverine publica a estos topics; por eso no se admite `DurabilityMode.Serverless`.
- ADR-0003 (stack ES: Marten + Wolverine + Postgres): define el modo serverless de Wolverine y el outbox transaccional.
- ADR-0006 (convenciones de nombramiento de funciones Azure): una Function App por dominio, base de "un plan por dominio".
- ADR-0013 (smoke tests contra entorno dev): suite cuyos fallos intermitentes destaparon el problema.
