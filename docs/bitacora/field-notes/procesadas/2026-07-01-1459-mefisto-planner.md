---
fecha: 2026-07-01
hora: 14:59
sesion: mefisto-planner
tema: Desglose de ADR-0025 (custodia de secretos) en issues de implementacion
---

## Contexto

ADR-0025 (aceptado, en main) generaliza la custodia de secretos mas alla de las
cadenas de ASB de ADR-0024. La auditoria post-ADR-0024 encontro tres secretos aun
en texto plano en app settings: password de Postgres (MartenConnectionString),
connection string de App Insights (instrumentation key) y access key de Storage
(AzureWebJobsStorage). Se pidio desglosar en issues de Mefisto, resolviendo de una
vez la decision de coordinacion sobre nombres de secretos y roles.

## Descubrimientos

- El wiring de secretos toca dos agentes que deben coincidir en convencion:
  `infra-base-scaffolder` (CREA referencias/roles/locals) y `domain-scaffolder`
  (CONSUME al instanciar la Function App del dominio). Es el mismo riesgo de la
  leccion #146 (productor/consumidor deben citar exactamente el mismo nombre).
- Verificado que CLAUDE.md lineas 67 y 96 conservan prosa superada ("dos namespaces
  de Azure Service Bus (interno e integracion)") que el barrido #167 no cubrio
  (barrio ADRs/agentes, no la prosa de CLAUDE.md). El indice tematico (177-178) ya
  estaba correcto.
- La cadena del ASB interno YA esta custodiada (contrato serviceBus.internal + modulo
  Key Vault), pero el cuerpo de ADR-0024 #6 la omitia al nombrar solo "backbone y
  externo". Enmienda de texto, no de codigo.

## Decisiones

- **Corte por archivo** (evita paralelos sobre el mismo archivo, leccion oleada 3):
  - #182 -> `agents/infra-base-scaffolder.md` (issue ancla de convencion).
  - #183 -> `agents/domain-scaffolder.md` (depende de #182 por convencion + modulo function-app).
  - #184 -> docs (ADR-0024 #6 + ADR-0021 + CLAUDE.md 67/96), archivos disjuntos de los agentes.
  - #185 -> `agents/implementer.md` (doctrina de secretos nuevos), archivo propio disjunto.
- **Nombres de secretos KV = convencionales fijos, NO en harness.config.json.**
  Justificacion: Postgres y App Insights son EXACTAMENTE uno por BC (no un registro
  de N como serviceBus de #163); delegarlos al contrato no aporta flexibilidad, solo
  ceremonia y otra superficie de inconsistencia. Nombres: `marten-connection` y
  `app-insights-connection`, documentados en CLAUDE.md.
- **Claves de app setting NO cambian** (las fijan los frameworks): MartenConnectionString
  y APPLICATIONINSIGHTS_CONNECTION_STRING conservan su clave; solo el VALOR pasa a
  `@Microsoft.KeyVault(...)` versionless.
- **Roles de datos de Storage para la MI de la Function App** (AzureWebJobsStorage por
  identidad, doc oficial Azure Functions "Connect to host storage with an identity"):
  Storage Blob Data Owner + Storage Queue Data Contributor + Storage Table Data Contributor.
- Todo esto anclado en #182 (issue ancla); los demas lo referencian sin reinventarlo.
- Estados: #182, #184, #185 a `estado:listo` (sin dependencias abiertas). #183 a
  `estado:borrador` + `bloqueado` (depende de #182, que aun no cierra).

## Descartado

- Meter los nombres de secretos de Postgres/App Insights en el contrato
  harness.config.json (descartado: uno por BC, no un registro de N; convencion fija
  es menos ceremonia).
- Foldear el issue del implementer (#185) en otro: descartado porque corta por un
  archivo propio sin solape y permite paralelizarlo.
- Crear un issue epic/contenedor: no se hace en Mefisto; relacion solo via `## Dependencias`.

## Preguntas abiertas

- Confirmar al implementar el nombre EXACTO del atributo del provider azurerm para
  storage por identidad (`storage_uses_managed_identity` es el candidato; validar en
  la doc del provider al escribir el HCL). No bloquea el plan.

## Referencias

Issues creados:
- #182 Custodiar Postgres y App Insights por Key Vault y Storage por identidad en infra-base-scaffolder (ADR-0025) [ancla, listo]
- #183 Consumir referencias de Key Vault y storage por identidad en domain-scaffolder (ADR-0025) [borrador, bloqueado, depende de #182]
- #184 Enmendar doctrina de secretos en ADR-0024, ADR-0021 y CLAUDE.md (ADR-0025) [listo]
- #185 Fijar doctrina de secretos nuevos por Key Vault o identidad en implementer (ADR-0025) [listo]

Grafo de dependencias: #182 -> #183. #184 y #185 independientes.
Oleadas: [#182, #184, #185] en paralelo; [#183] tras cerrar #182.
