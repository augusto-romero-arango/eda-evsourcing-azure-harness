# MEF-ADR-0048: Testing de servidores MCP -- extension de MEF-ADR-0013

- **Fecha**: 2026-08-30
- **Estado**: aceptado
- **Aplica a**: doctrina general del marco para probar todo servidor MCP (Model Context Protocol) que un Bounded Context expone bajo MEF-ADR-0047 -- la piramide de niveles de test, las verificaciones canonicas del nivel e2e, los endpoints de gate propios de una app MCP y la obtencion de su credencial en CI. Aplicable a cualquier Bounded Context de cualquier consumidor del marco; el cuerpo normativo no referencia ningun proyecto, archivo ni issue de un consumidor concreto (ver seccion "Alcance"). Extiende MEF-ADR-0013 (smoke tests contra dev) y MEF-ADR-0022 (autenticacion de CI por OIDC) al dominio de servidores MCP; cita MEF-ADR-0016 (naming de metodos de test) y MEF-ADR-0018 (Rule of Three) como doctrina ya vigente que este ADR no reabre.

## Contexto

MEF-ADR-0047 fija la doctrina general de un servidor MCP del marco (ruta tecnica, granularidad, aislamiento frente al BC, diseno de tools, custodia de la key `mcp_extension`) pero deja fuera, deliberadamente, como probarlo y con que credencial en CI -- ese ADR remite ese alcance a este.

Un servidor MCP tiene tres particularidades que MEF-ADR-0013 no contempla porque nunca las tuvo que resolver para un Function App de dominio:

- **El registro vivo de tools es inalcanzable en unit tests.** `tools/list` lo sirve el registro de tools de la extension, que vive en el paquete del **host** de Azure Functions, no en el ensamblado del worker que un unit test carga en memoria. Ningun unit test puede invocar `tools/list` contra el registro real; verificar el contrato publicado exige un cliente MCP real hablando con el runtime desplegado.
- **La credencial viaja por header, no por query string de un comando de dominio.** El endpoint MCP exige la system key `mcp_extension` (MEF-ADR-0047 decision 5) en el header `x-functions-key`; un smoke test de servidor MCP autentica de forma distinta a un smoke test de comando de dominio (que tipicamente no necesita key alguna en dev).
- **El ready no sondea event store.** Un servidor MCP es cliente HTTP puro sin persistencia propia (MEF-ADR-0047 decision 3): no tiene write-path de Marten que calentar, asi que su endpoint de salud no puede copiar la sonda de datos que un dominio si necesita.

Sin doctrina escrita, cada consumidor que adoptara MEF-ADR-0047 resolveria estas tres particularidades por su cuenta -- el mismo riesgo de reinvencion reactiva que motivo MEF-ADR-0047.

### Alcance

Este ADR fija **doctrina general del marco**, aplicable a cualquier Bounded Context de cualquier consumidor: el cuerpo normativo usa vocabulario neutro (`<RootNamespace>.Mcp.{Proposito}`, "el BC", "el consumidor") y no nombra ningun proyecto, archivo ni issue de un consumidor concreto. La doctrina se valido empiricamente en un piloto completo -- suite e2e verde 8/8 contra un entorno dev real, a la primera corrida --, pero esa evidencia (que consumidor, que issues y PRs, que resultado de smoke) queda registrada fuera de este ADR, en el issue de este repo que lo origina (seccion "Origen").

### Que queda fuera de este ADR

- **El agente scaffolder que materializa esta doctrina en codigo** (proyecto de smoke tests, reusable de CI, endpoints de gate generados desde el dia uno): alcance de `/scaffold-mcp`, issue bloqueado por MEF-ADR-0047.
- **Naming de metodos de test.** MEF-ADR-0016 ya fija una convencion unica aplicable a **todos** los tests del proyecto, sin distincion de capa; los tests de un servidor MCP no necesitan una convencion propia y siguen la vigente sin cambio.
- **Cuando extraer codigo duplicado entre servidores MCP del mismo BC.** MEF-ADR-0018 (Rule of Three) ya fija el criterio general; este ADR solo señala, en la seccion 4, un caso concreto donde ese criterio aplica sin fijar una regla nueva.

## Decision

### 1. Piramide de tres niveles (CA-1)

Un servidor MCP se prueba en tres niveles, cada uno cubriendo lo que el nivel anterior no puede alcanzar:

| Nivel | Que verifica | Como |
|---|---|---|
| **1. Unit tests del remodelado** | La forma de cada tool -- el remodelado de la respuesta de la Function App del BC al contrato token-eficiente que MEF-ADR-0047 decision 4 exige (`camelCase`, omision de `null`, truncado con senal, filtros de relevancia) | Handler falso (fake del `HttpClient` tipado hacia el BC, sin red real) + fixtures JSON reales capturadas de una respuesta autentica del BC bajo prueba |
| **2. Composicion del worker por reflexion** | Que el ensamblado del worker declara exactamente las tools, parametros `required` y `_meta`/hints que el diseno espera -- un test de composicion, no de comportamiento en runtime | Reflexion sobre los tipos/atributos del ensamblado compilado del worker (`[McpServerTool]`, `[Description]`, metadata de propiedades), pinneando nombres, `required` y hints declarados |
| **3. Smoke e2e con el SDK oficial de cliente** | Que el servidor desplegado responde de verdad -- handshake, catalogo de tools servido en runtime, una tool call real, un error path real, la frontera de seguridad | Cliente MCP real contra el entorno dev desplegado (seccion 2) |

**Limite estructural que fija el nivel 2 en composicion, nunca en runtime.** El registro que sirve `tools/list` en runtime (`DefaultToolRegistry` de la extension MCP de Azure Functions) vive en el paquete del **host**, no en el ensamblado del **worker** que un test de composicion carga y refleja -- un unit test no puede instanciarlo ni invocarlo. Por eso el nivel 2 verifica la **declaracion** (los atributos y metadata que el worker compilado expone), no la **respuesta servida**; verificar la respuesta sevida en runtime es exclusivamente el trabajo del nivel 3.

**Nivel 3, SDK oficial, cliente puro.** El nivel 3 usa el SDK de cliente oficial de MCP (paquete `ModelContextProtocol.Core`, que contiene el cliente y los transportes; el paquete sombrilla del ecosistema oficial solo agrega servidor + DI, y un test de cliente no lo necesita). No se implementa un cliente HTTP/JSON-RPC ad-hoc: el SDK oficial ya encapsula el framing y el ciclo de vida del protocolo que un cliente a mano tendria que reinventar y podria implementar mal.

### 2. Cinco verificaciones canonicas del nivel 3 (CA-2)

Todo smoke e2e de un servidor MCP cubre, como minimo, estas cinco verificaciones:

1. **Handshake.** El `serverInfo.name` que devuelve la inicializacion del protocolo coincide con el `serverName` declarado en la seccion `extensions.mcp` del `host.json` del servidor bajo prueba. Prueba que el runtime desplegado cargo el `host.json` correcto -- no el de otro servidor MCP del mismo BC ni una configuracion residual de un deploy anterior.
2. **`tools/list` vivo como contrato pinneado.** El catalogo exacto de tools que el servidor publica en runtime, el `required` de cada `inputSchema`, y el `readOnlyHint` (u otro `ToolAnnotations`) presente en `_meta` -- pinneados contra el diseño esperado, no solo verificados como "no vacio". Es la unica verificacion posible del contrato realmente servido (ver el limite estructural de la seccion 1): si el nivel 2 pinnea la declaracion y este nivel no pinnea la respuesta servida, un desalineamiento entre lo que el worker declara y lo que el host efectivamente publica pasa inadvertido.
3. **Una tool call de lectura contra datos reales.** Invoca una tool real con argumentos que produzcan una respuesta con datos genuinos del BC -- recorre la cadena completa cliente -> host -> worker -> `HttpClient` tipado -> Function App del BC -> dato real, no un stub.
4. **Un error path que afirma el texto exacto del mensaje `.resx`.** Un input que el worker rechaza en su propia logica (no en la Function App del BC) debe devolver el mensaje exacto que el `.resx` co-localizado declara (MEF-ADR-0047 decision 4, MEF-ADR-0009). Esta verificacion prueba, de paso, que los recursos embebidos viajaron correctamente en el artefacto publicado -- un `.resx` que no se embebio o no se localizo en runtime produce un mensaje distinto (vacio, generico o la clave literal en vez del texto), asi que un mismatch aqui es senal de un defecto de empaquetado, no solo de logica.
5. **El negativo de seguridad.** Una invocacion sin la credencial `mcp_extension` (ninguna key en `x-functions-key`) contra el endpoint del protocolo devuelve `401 Unauthorized`. La particion Consultas/Comandos por servidor y credencial (MEF-ADR-0047 decision 2) es la unica frontera de acceso real -- este assert confirma que esa frontera esta activa en el desplegado bajo prueba, sin depender de que un cliente respete un `readOnlyHint`, que la especificacion de MCP declara explicitamente no confiable.

Cualquier verificacion adicional (mas tool calls, mas error paths) es bienvenida; estas cinco son el minimo que hace a una suite de nivel 3 completa.

### 3. Endpoints de gate propios de una app MCP (CA-3)

Todo servidor MCP expone los mismos dos endpoints de gate que MEF-ADR-0031 fija para el resto del marco, con una semantica adaptada a que el servidor no tiene event store propio:

- **`GET /api/version`**: identico en mecanica al de cualquier Function App del marco (MEF-ADR-0031 seccion 1-2) -- copiable con **cero dependencias** de dominio, resuelto a partir de `SourceRevisionId` horneado en el build (`-p:SourceRevisionId=<sha>`). Convive sin friccion con los triggers MCP en el mismo worker: version y protocolo MCP son superficies HTTP independientes del mismo host.
- **`GET /api/ready`**: **trivial, `200` incondicional**, porque el servidor MCP es cliente HTTP puro sin write-path propio que calentar (MEF-ADR-0047 decision 3) -- no hay tablas de Marten, migraciones ni conexion a base de datos cuya disponibilidad sondear. Esta semantica -- "el worker esta arriba y puede recibir invocaciones", no "la capa de datos respondio" -- se documenta explicitamente en el propio archivo del endpoint. **Prohibido copiar la sonda de datos que MEF-ADR-0031 seccion 6 fija para un dominio** (esa sonda existe para detectar un write-path de Marten no calentado; un servidor MCP nunca tiene uno).

### 4. Credencial `mcp_extension` en CI: runtime, nunca persistida (CA-4)

La key `mcp_extension` (MEF-ADR-0047 decision 5) llega a la suite de CI por el mismo mecanismo de identidad federada que ya autentica cualquier deploy del marco (MEF-ADR-0022), nunca como un secreto nuevo:

- El job de smoke obtiene la key **en runtime**, tras autenticarse por OIDC con los secrets `AZURE_*` que MEF-ADR-0022 ya fija (`AZURE_CLIENT_ID`/`AZURE_TENANT_ID`/`AZURE_SUBSCRIPTION_ID`, sin password): `az functionapp keys list --query systemKeys.mcp_extension` contra el Function App del servidor MCP bajo prueba.
- El valor se enmascara con `::add-mask::` en la salida del step **antes** de exportarlo a cualquier variable de entorno o variable del job -- nunca despues. Enmascarar despues de exportar deja una ventana en la que el valor crudo ya paso por un log potencialmente sin mascara.
- `permissions: id-token: write` se declara **tanto en el workflow reusable que ejecuta el paso de OIDC + listkeys como en el workflow caller que lo invoca** -- un workflow llamado (`workflow_call`) nunca excede los permisos que el invocador le concede; declararlo solo en el reusable no basta.
- El Service Principal de CI (MEF-ADR-0022) ya alcanza para esta operacion sin rol adicional: `Contributor` a nivel de suscripcion incluye la accion `Microsoft.Web/sites/host/listkeys/action` que `az functionapp keys list` requiere.
- **Proscrito**: `mcp_extension` como GitHub secret. Copiar la key a un secret del repo introduce exactamente lo que el mecanismo runtime evita -- una copia persistida que exige rotacion manual coordinada si la key del host cambia, y una superficie de fuga adicional (el secret sobrevive mas alla de la ejecucion del job que lo necesito).

### 5. Criterio de concurrencia: cuando una suite MCP entra al grupo compartido (CA-5)

MEF-ADR-0013 corre los smoke tests de cada dominio secuencialmente y comparte la suscripcion `smoke-tests` de Service Bus entre ellos; la razon de ese grupo de concurrencia es evitar que la purga o el `CompleteMessageAsync` de una suite robe el mensaje que otra suite esta esperando.

- **Una suite MCP de solo lectura (piramide de la seccion 1-2 sin ninguna tool de escritura) no entra al grupo de concurrencia compartido `smoke-tests-dev`.** La razon de ser de ese grupo -- el robo de mensajes de Service Bus entre suites -- no aplica: un servidor MCP de solo lectura no publica ni consume del bus, asi que no compite por la suscripcion compartida con ninguna otra suite.
- **Una suite MCP que gana una fase de comandos/siembra con efectos secundarios reales (Service Bus, persistencia) si entra al grupo**, exactamente por el mismo motivo que cualquier smoke test de dominio: en cuanto una tool produce un efecto secundario compartido, el riesgo de robo de mensaje que motiva el grupo vuelve a aplicar.

## Alternativas consideradas

### Alt 1: verificar `tools/list` solo por reflexion (nivel 2), sin nivel 3 dedicado

Descartada: la reflexion sobre el ensamblado del worker pinnea la **declaracion**, pero el registro que sirve `tools/list` en runtime vive en el paquete del host (seccion 1) -- inalcanzable desde un test que carga el worker en memoria. Sin un nivel 3 contra el desplegado real, un desalineamiento entre lo declarado y lo efectivamente publicado por el host pasaria inadvertido indefinidamente.

### Alt 2: `DelegatingHandler` para inyectar la credencial en el cliente de smoke

Considerada como plan B para pasar `mcp_extension` en el cliente de nivel 3, ante la duda inicial de si el SDK oficial exponia un mecanismo directo de headers. Descartada por innecesaria: el SDK de cliente (`ModelContextProtocol.Core`) ya expone `AdditionalHeaders` en las opciones de su transporte HTTP, verificado empiricamente contra la version GA del paquete -- un `DelegatingHandler` a medida solo agregaria una capa de indireccion sobre algo que el SDK ya resuelve.

### Alt 3: `mcp_extension` como GitHub secret, copiado una vez desde el portal

Descartada en la seccion 4: introduce custodia manual (rotacion coordinada si el host regenera la key) que el mecanismo runtime por OIDC evita por completo, replicando el mismo riesgo que MEF-ADR-0022 ya elimino para las credenciales de deploy.

### Alt 4: incluir toda suite MCP en el grupo de concurrencia `smoke-tests-dev` por defecto

Descartada en la seccion 5: forzaria una ejecucion secuencial innecesaria para una suite que no toca ningun recurso compartido, alargando el tiempo total del pipeline de smoke tests sin reducir ningun riesgo real.

## Consecuencias

### Positivas

- **Cierra el unico hueco que MEF-ADR-0047 dejo abierto a proposito**: un consumidor que adopta esa doctrina hoy tiene, desde este ADR, un criterio completo de como probar el servidor que construye y con que credencial en CI.
- **Cero secretos nuevos**: la key de un servidor MCP se obtiene por el mismo mecanismo de identidad federada que ya autentica cualquier deploy del marco (MEF-ADR-0022) -- ningun secreto adicional que rotar ni custodiar.
- **El limite estructural del registro de tools queda documentado antes de que alguien lo descubra por sorpresa**: sin esta doctrina, un equipo que intenta unit-testear `tools/list` directamente perderia tiempo antes de notar que el registro vive fuera del ensamblado que esta probando.
- **Cinco verificaciones canonicas evitan smoke tests parciales**: fijar el minimo (handshake, catalogo pinneado, tool call real, error path con `.resx`, negativo de seguridad) evita que cada consumidor decida por su cuenta que tan completa debe ser su suite de nivel 3.
- **El criterio de concurrencia evita ejecucion secuencial innecesaria**: una suite de solo lectura corre en paralelo con el resto sin arriesgar el robo de mensajes que el grupo compartido existe para evitar.

### Negativas

- **Tres niveles de test por servidor MCP, no uno**: mas superficie de mantenimiento que un unico nivel de smoke tests, con la responsabilidad de que los tres se mantengan alineados (un cambio de contrato de una tool toca potencialmente los tres niveles).
- **El nivel 3 depende del entorno dev desplegado**, con las mismas negativas que MEF-ADR-0013 ya acepta para cualquier smoke test (dependencia de disponibilidad del entorno, latencia de red).
- **La obtencion de la key en runtime agrega un paso de CI por suite MCP** (`az functionapp keys list`) frente a la alternativa, mas simple de escribir pero peor de custodiar, de un secreto ya copiado.
- **El criterio de concurrencia exige que alguien lo evalue por servidor**: a diferencia de un default incondicional (todo entra al grupo, o nada entra), este ADR pide decidir, al escribir la suite, si el servidor tiene o no efectos secundarios compartidos -- trabajo de analisis que un default unico no exigiria.

## Referencias

- MEF-ADR-0047 (doctrina de servidores MCP serverless): ADR base que este documento extiende; fuente de la extension MCP de Azure Functions, la system key `mcp_extension`, la particion Consultas/Comandos y el vocabulario neutro que este ADR reusa.
- MEF-ADR-0013 (smoke tests contra entorno dev): ADR hermano que este documento extiende al dominio de servidores MCP; su control de cambios se enmienda con una linea que remite a este ADR (seccion 1, CA-7).
- MEF-ADR-0022 (autenticacion de CI por OIDC): fuente de los secrets `AZURE_*` y del Service Principal sin password que la seccion 4 reusa para obtener `mcp_extension` en runtime, sin secret nuevo.
- MEF-ADR-0031 (readiness gate por SHA): fuente del mecanismo de `/api/version` (`SourceRevisionId` horneado en el build) y de la distincion entre "el worker esta arriba" y "la capa de datos respondio" que la seccion 3 adapta a una app MCP sin event store.
- MEF-ADR-0016 (convencion de nombres para metodos de test): doctrina ya vigente, aplicable sin cambio a los tests de un servidor MCP (ver "Que queda fuera de este ADR").
- MEF-ADR-0018 (heuristicas de evolucion y reuso del codigo, Rule of Three): doctrina ya vigente que gobierna cuando extraer codigo compartido entre dos o mas servidores MCP del mismo BC (ver "Que queda fuera de este ADR").
- MEF-ADR-0009 (mensajes `.resx` por aggregate/handler): fuente del patron de mensaje runtime que la verificacion 4 de la seccion 2 exige afirmar textualmente.
- Model Context Protocol, especificacion 2025-06-18, "Server Features: Tools" -- fuente de que `ToolAnnotations`/`readOnlyHint` son metadatos no confiables, citada por MEF-ADR-0047 decision 2 y retomada aqui como fundamento del negativo de seguridad (verificacion 5 de la seccion 2). https://modelcontextprotocol.io/specification/2025-06-18/server/tools
- Microsoft Learn, "Model Context Protocol bindings for Azure Functions overview" (C#) -- fuente de la extension `Microsoft.Azure.Functions.Worker.Extensions.Mcp`, el endpoint del protocolo y la system key `mcp_extension`, ya citada como fuente principal en MEF-ADR-0047. https://learn.microsoft.com/azure/azure-functions/functions-bindings-mcp
- Microsoft Learn, "MCP tool trigger for Azure Functions" (C#) -- fuente del esquema `ToolProperty` (`isRequired`, `propertyType`) que la verificacion 2 de la seccion 2 pinnea contra el `inputSchema` publicado. https://learn.microsoft.com/azure/azure-functions/functions-bindings-mcp-tool-trigger
- Hecho verificado empiricamente durante el piloto que origina este ADR, sin documentacion oficial dedicada: el registro que sirve `tools/list` en runtime (`DefaultToolRegistry`) vive en el paquete del host de la extension MCP, no en el ensamblado del worker -- fuente del limite estructural que la seccion 1 fija para el nivel 2. Verificado contra la extension MCP de Azure Functions en su version GA de 2026.
- Hecho verificado empiricamente durante el mismo piloto, sin documentacion oficial dedicada: el SDK de cliente `ModelContextProtocol.Core` expone la credencial de header via `AdditionalHeaders` de las opciones de su transporte HTTP -- fuente de que la Alt 2 (un `DelegatingHandler` a medida) resulto innecesaria. Verificado contra la version GA del paquete.
- Issue de este repo que origina este ADR (seccion "Origen"): registra la evidencia empirica del piloto -- que consumidor, que issues y PRs, que resultado de smoke -- deliberadamente fuera del cuerpo de este ADR (ver "Alcance").

## Control de cambios

- 2026-08-30: creacion como `aceptado` (extension de MEF-ADR-0013 y MEF-ADR-0022 al dominio de servidores MCP de MEF-ADR-0047). Fija la piramide de tres niveles de test -- unit tests del remodelado, composicion del worker por reflexion, smoke e2e con el SDK oficial de cliente -- con el limite estructural de que el registro de `tools/list` vive en el paquete del host, inalcanzable desde el worker (seccion 1); las cinco verificaciones canonicas del nivel e2e -- handshake, catalogo pinneado, tool call real, error path con `.resx`, negativo de seguridad -- (seccion 2); los endpoints de gate `/api/version` (identico al resto del marco) y `/api/ready` (trivial `200`, sin sonda de datos) propios de una app MCP sin event store (seccion 3); la obtencion en runtime de la credencial `mcp_extension` en CI por el mismo mecanismo OIDC del resto del marco, sin secret nuevo (seccion 4); y el criterio de cuando una suite MCP entra al grupo de concurrencia compartido de smoke tests (seccion 5).
