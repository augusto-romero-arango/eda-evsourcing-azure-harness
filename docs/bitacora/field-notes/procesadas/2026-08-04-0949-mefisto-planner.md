---
fecha: 2026-08-04
hora: 09:49
sesion: mefisto-planner
tema: refinamiento de #439 (lista canonica de resource providers de Azure) y particion en #488
---

## Contexto

Se pidio refinar el draft #439, abierto el 2026-07-28 como spin-off estructural de #433. #433 resolvio el caso urgente (registrar `Microsoft.App` para el worker de proyecciones) y dejo a la vista el problema de fondo: el marco depende de que el provider `azurerm` auto-registre por su cuenta los resource providers de Azure que su infraestructura necesita, sin que ninguno este declarado en el repo del consumidor.

El draft se auto-declaraba no-listo por falta de un trabajo de descubrimiento que no admite criterio como sustituto: enumerar los namespaces exactos que consumen los 8 modulos base mas los 3 opt-in, y cruzarlos contra los cinco sets de auto-registro del provider. Ese trabajo se hizo en esta sesion.

## Descubrimientos

**El default de v4 es `legacy`, no `core` -- el draft lo tenia mal, y el dato lo explica todo.** En `internal/provider/provider.go` de la tag `v4.81.0`, el schema declara default `none` (linea 349) pero la linea 385 lo sobrescribe a `ProviderRegistrationsLegacy` dentro de `if !providerfeatures.FivePointOh()`. El set `legacy` (61 namespaces) cubre 12 de los 13 que el marco necesita; el unico ausente es `Microsoft.App`. Eso es exactamente el sintoma de #433: no era una laguna aleatoria, era la unica laguna posible.

**`azurerm` v5.0.1 ya esta publicada** (2026-07-30, registry API). En v5 `features.FivePointOh()` retorna `true` incondicionalmente -- su propio comentario dice que las rutas bajo `!FivePointOh()` son codigo muerto --, asi que el override muere y el default efectivo pasa a `none`: cero namespaces auto-registrados. El issue dejo de ser preventivo-teorico y paso a tener una fecha real detras, aunque nada este roto hoy (el pin `~> 4.0` resuelve a 4.x).

**La lista son 13 namespaces.** Derivada de los recursos que emiten `infra-base-scaffolder`, `domain-scaffolder` y `apim-gateway-scaffolder`, con el tipo ARM de cada recurso verificado contra `az provider list` en una suscripcion real y cada namespace cruzado contra `required.go` (tag `v5.0.1`). Once son incondicionales; dos corresponden a features opt-in (`Microsoft.App` para proyecciones, `Microsoft.ApiManagement` para el gateway).

**El modo y la lista se mergean, no compiten.** `internal/provider/provider.go` lineas 501-513: el provider resuelve el set del modo y luego hace `requiredResourceProviders.Merge(additionalProvidersToRegister)`. Consecuencia de diseno: una lista explicita es un **piso**, nunca un techo -- lo que permite que el chequeo del revisor (#488) sea indiferente al modo sin perder correccion, y que el scaffolder no tenga que pisar un modo que el consumidor haya puesto a proposito.

**Un namespace mal escrito no revienta ruidosamente.** `EnhancedValidate` (`validation.go`) es best-effort: sin cache de RPs poblada solo valida cadena no vacia. Y `requiring_registration.go` degrada a `log.Printf("[WARN] ...")` cuando Azure no devuelve el namespace pedido, en vez de fallar. Un typo atraviesa el `plan` y vuelve como `409` en el `apply`. Por eso el casing literal (`microsoft.insights` en minusculas, como lo escribe `required.go` y lo devuelve la API) es un CA y no un detalle de estilo.

## Decisiones

**1. Modo `none` + lista completa explicita** (forma A), descartando fijar un modo y declarar solo el delta. Razon: el delta dejaria la lista real partida entre un set invisible dentro del binario del provider y unas lineas en el repo -- ilegible sin leer el codigo fuente de HashiCorp. Y `legacy`, el candidato natural para "usa tu lista de siempre", viene anotado en `required.go` como *"will be removed in a future major release"*.

**2. Lista fija y completa, no condicionada a tokens.** Los dos namespaces de features opt-in se declaran siempre. Lo que se compra: la desaparicion del Paso 2.1b del scaffolder -- un gate por token con tres casos de idempotencia cuyo propio texto advierte que si la variable no se re-deriva el registro se omite **en silencio**. Cada feature futura habria vuelto a pagar ese peaje. Lo que se paga: dos interruptores encendidos que un proyecto puede no usar, y encender un RP no crea recursos ni se factura.

**3. El pin del provider queda fuera.** Sigue en `~> 4.0`. El argumento tiene nombre y semantica identicos en v4.81.0 y v5.0.1, asi que la lista funciona hoy y queda lista para el upgrade. Subir de major arrastra la matriz completa de cambios rompientes de v5 sobre Postgres, Function Apps y Key Vault: investigacion aparte que se apoyara en este issue en vez de cargarlo.

**4. Particion en dos issues, replicando el par #433/#437** (emisor primero, revisor despues, que ya funciono hace una semana): #439 se queda con `infra-base-scaffolder` + los dos ADRs; #488 generaliza el chequeo de `infra-reviewer`, con `Depende de #439` y label `bloqueado`. Un solo issue habria dejado ~8 CAs sobre dos agentes y dos ADRs, con el agravante de que el revisor tendria que juzgar el chequeo nuevo contra un texto que cambia en el mismo PR.

**5. MEF-ADR-0021 pasa a ser la fuente de verdad de la lista** (es donde vive el contrato del esqueleto del entorno, y `providers.tf` es parte de ese esqueleto). MEF-ADR-0034 seccion 8 deja de ser normativo sobre la lista y remite alli, conservando su diagnostico del `409` y su descarte del recurso `azurerm_resource_provider_registration`.

**6. La exclusion se documenta igual que la inclusion.** `Microsoft.Network` y `Microsoft.Compute` quedan fuera aunque estan en `core`: el marco no crea VNets, subnets, private endpoints ni VMs (Postgres usa acceso publico con firewall rules, el managed environment no recibe `infrastructure_subnet_id`, las Function Apps no usan VNet integration). Dejarlo escrito convierte la ausencia en decision auditable en vez de olvido sospechoso, y fija el criterio de inclusion: **un namespace entra cuando algun recurso que el marco emite pertenece a el.**

## Descartado

- **Fijar `resource_provider_registrations = "legacy"` o `"core"` + delta.** Ver decision 1.
- **Condicionar la lista a los tokens** `projections.enabled` / instalacion de APIM. Ver decision 2.
- **Subir el pin a `~> 5.0` en el mismo issue.** Ver decision 3.
- **Un solo issue para scaffolder + reviewer.** Ver decision 4.
- **El recurso `azurerm_resource_provider_registration`** sigue descartado por la doctrina que ya fijo #433 (su `destroy` desregistra el namespace y falla con recursos vivos; su state es de suscripcion, no de entorno). No se reabrio.

## Preguntas abiertas

- **El upgrade a `azurerm ~> 5.0` no tiene issue todavia.** Queda como idea pendiente, no como draft: exige investigar la matriz de cambios rompientes de v5 sobre cada recurso del catalogo del marco antes de poder enunciar CAs.
- **Riesgo residual de la decision 1**: pasar de 61 namespaces implicitos a 13 explicitos significa que un olvido ya no se salva por auto-registro. Se acota -- encender un RP es permanente por suscripcion, asi que los consumidores ya desplegados no se ven afectados y el riesgo vive solo en un greenfield sobre suscripcion virgen, donde el `409` nombra el namespace exacto. Por eso el CA-4 obliga a que el ADR documente el modo de falla, no solo la lista.

## Referencias

Issues creados: #488 (Generalizar en infra-reviewer el chequeo de resource providers a la lista canonica del marco -- `estado:listo`, `bloqueado`, depende de #439)

Issues refinados: #439 (de `estado:borrador` a `estado:listo`; titulo ajustado a "Declarar en el provider del entorno la lista canonica de resource providers que la infraestructura del marco necesita", que ya no insinua que el issue suba el pin)

Antecedentes: #433 (emisor, caso `Microsoft.App`, mergeado en PR #442), #437 (chequeo del revisor, mergeado en PR #444)
