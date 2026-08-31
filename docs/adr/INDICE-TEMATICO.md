# Índice temático de ADRs

Migrado desde `CLAUDE.md` (issue de /doctor, limpieza de contexto siempre-cargado): esta tabla
no necesita estar residente en cada sesión, solo cuando se busca en qué ADR vive una doctrina.

> Esta tabla NO se edita a mano por-PR (issue #380): un issue que añade o enmienda un ADR anota su fila como fragmento en `changelog.d/<issue>.adr-index.md` (ver `changelog.d/README.md`), y `/mefisto-release` la consolida aquí en su propia rama de release.

| Tema | ADR |
|---|---|
| Topics de Service Bus por evento | MEF-ADR-0001 |
| Estrategia de testing con event sourcing (Given/When/Then) | MEF-ADR-0002 |
| Stack ES: Marten + Wolverine + Postgres | MEF-ADR-0003 |
| Manejo de errores en ES (eventos de fallo vs excepciones) | MEF-ADR-0004 |
| Naming y versionado de eventos | MEF-ADR-0005 |
| Convenciones de nombramiento de funciones Azure (comando, ServiceBus, fan-in, query GET) y de artefactos de proyeccion | MEF-ADR-0006 |
| Gestión de proyecto con GitHub Issues | MEF-ADR-0007 |
| Knowledge Crunching como propósito del planner | MEF-ADR-0008 |
| Mensajes en `.resx` por aggregate/handler | MEF-ADR-0009 |
| Pipeline de conocimiento del dominio | MEF-ADR-0010 |
| Definition of Ready por tipo de issue | MEF-ADR-0011 |
| Encapsulamiento, Tell-don't-Ask, value objects, frontera de serialización (event store Marten vs bus) | MEF-ADR-0012 |
| Smoke tests contra entorno dev | MEF-ADR-0013 |
| Coverage gate en pipeline TDD | MEF-ADR-0014 |
| Snapshots de Marten como excepción | MEF-ADR-0015 |
| Convención de naming para métodos de test | MEF-ADR-0016 |
| Archivo señal de refactor puro vive fuera de `.claude/` | MEF-ADR-0017 |
| Heurísticas de evolución y reuso del código (Rule of Three, etc.) | MEF-ADR-0018 |
| Separación física de skills publicados vs internos | MEF-ADR-0019 |
| Hosting de Azure Functions (un App Service Plan por dominio) | MEF-ADR-0020 |
| Infraestructura base (8 módulos + entorno) generada por agente | MEF-ADR-0021 |
| Autenticación de CI hacia Azure por OIDC (Workload Identity Federation) | MEF-ADR-0022 |
| Bounded Context, namespace interno de ASB y frontera publico/privado | MEF-ADR-0023 |
| Modelo de eventos de bus (privado propio, publico via backbone compartido, externo diferido) | MEF-ADR-0024 |
| Custodia de secretos (ningun secreto/key en texto plano; Key Vault o identidad administrada) | MEF-ADR-0025 |
| Colas de Service Bus con sesion para fan-in y serializacion por clave de aggregate | MEF-ADR-0026 |
| Enrutamiento multi-destinatario de un evento por correlation filter de igualdad | MEF-ADR-0027 |
| Estrategia de tenancy (mono-tenant transitorio en greenfield + resolver real basado en TenantContext) | MEF-ADR-0028 |
| Test de composicion del contenedor DI del host generado por el scaffold | MEF-ADR-0029 |
| Esquema de identificación de ADRs con prefijo por proyecto (adopción opcional para consumidores) | MEF-ADR-0030 |
| Readiness gate por SHA (endpoint `/api/version` + gate deploy->smoke) | MEF-ADR-0031 |
| Identidad y autenticación en el borde: WorkOS AuthKit + Azure API Management | MEF-ADR-0032 |
| Adopción de Agent Skills (progressive disclosure) para doctrina pesada del marco | MEF-ADR-0033 |
| Worker de proyecciones y read models por Bounded Context (Container App sin ingress, named store por dominio, config-test) | MEF-ADR-0034 |
| Doctrina de proyección y query read-side (recetas en 3 niveles, estilo record inmutable, superficie de consulta sobre QuerySession tenant-scoped) | MEF-ADR-0035 |
| Lista canonica de resource providers de Azure que el provider `azurerm` del entorno debe registrar | MEF-ADR-0021 |
| Compatibilidad de configuracion Marten entre write-side y read-side (los dos pares, criterio de corte, verificacion bajo gate del reviewer) | MEF-ADR-0034 |
| Doctrina de etiquetado del worker de proyecciones (`tipo:projection` para issues de configuracion del read-side, razonamiento continente/contenido de `dom:X`) | MEF-ADR-0011 |
| Observabilidad del worker de proyecciones (`service.name` obligatorio, fuentes de traza read-side, punto de extension del sampler) | MEF-ADR-0034 |
| Extension del readiness gate por SHA al read-side (`service.version` del worker de proyecciones, sin ingress) | MEF-ADR-0031 |
| Control de volumen de telemetria (sampler efectivo, filtros de ruido en origen, ratio del consumidor) | MEF-ADR-0038 |
| Wiring base de OpenTelemetry del write-side (paquetes, composicion en `Program.cs`, `telemetryMode` de `host.json`): doctrina mudada a MEF-ADR-0038 | MEF-ADR-0003 |
| Costo de ingesta de telemetria del daemon 24/7 y sampler read-side instalado por defecto con filtro del polling (doctrina en MEF-ADR-0038) | MEF-ADR-0034 |
| Identidad del evento persistido en el event store (alias vs `mt_dotnet_type`, proscripciones de registro, guardrails, protocolo de refactor) | MEF-ADR-0036 |
| Firmas admitidas de Create/Apply, tipo de identidad de N1 (StreamIdentity.AsString) y límite de fan-out en N2 | MEF-ADR-0035 |
| Origen del analizador de Marten (paquete, no `PackageReference` adicional) y namespaces de las clases base de proyección | MEF-ADR-0035 |
| Doble cobertura de la guarda 1 del config-test del worker (metodo `partial` del seam y clase de proyeccion sin `partial`) y superficie verificada de la guarda 2 | MEF-ADR-0034 |
| Resolución de `TView` en el `DocumentStore` del write-side sin registro adicional, y condición de política de tenancy documental compartida con el worker | MEF-ADR-0035 |
| Auto-creacion de tablas de read model por el worker de proyecciones (`AutoCreateSchemaObjects`, sin migracion de despliegue) | MEF-ADR-0034 |
| Identidad del stream y su representacion string canonica (Guid/clave compuesta, borde HTTP, store/bus/read-side) | MEF-ADR-0037 |
| Composicion canonica de ensamblados por rol del evento (particion PublicEvents/PrivateEvents/{Dominio}.DomainEvents; Contracts fuera del canon) | MEF-ADR-0039 |
| Acceso del worker de proyecciones a los tipos de evento persistidos via `{Dominio}.DomainEvents`, sin referenciar el `.csproj` de ningun Function App | MEF-ADR-0034 |
| Envelope de eventos referencia el ensamblado de eventos de bus que corresponda, no "el proyecto Contracts" | MEF-ADR-0005 |
| Csproj de smoke tests referencia PublicEvents/PrivateEvents en vez de Contracts | MEF-ADR-0013 |
| Referencia al shared kernel de Contracts reemplazada por la particion canonica de ensamblados de evento por rol | MEF-ADR-0010 |
| Mencion de Contracts en la fila `dom:X` del DoR actualizada a la particion de ensamblados de evento por rol | MEF-ADR-0011 |
| Referencia a un ADR de Contracts del consumidor reemplazada por la particion canonica de ensamblados de evento por rol | MEF-ADR-0012 |
| Regla simetrica de referencia unica en los proyectos de tests de eventos de bus (`PublicEvents.Tests`/`PrivateEvents.Tests`, cada uno referencia solo su propio ensamblado) | MEF-ADR-0039 |
| Cero referencias entre ensamblados de eventos (tres islas), payload por rol y enforcement por tests de arquitectura | MEF-ADR-0039 |
| Fuentes de conocimiento del dominio vigentes tras el retiro de la capa de modelado EDA (codigo por rol, glosario custodiado por el planner, field notes/bitacora, ADRs del consumidor) | MEF-ADR-0040 |
| Pipeline de conocimiento del dominio en tres fases (event-stormer/eda-modeler/planner): superseded por MEF-ADR-0040 | MEF-ADR-0010 |
| Forma propia de la vista read-side derivada de la necesidad de lectura; `ReadModels` como cuarta isla (cero `ProjectReference`) y naming sin sufijo `View` | MEF-ADR-0041 |
| Presentacion de los archivos "sin clasificar" del coverage gate (marcador de atencion y nota propios, distintos de una exclusion deliberada) | MEF-ADR-0014 |
| Patron de logica del coverage gate cubre el EventHandler directo (`*EventHandler.cs`, patron 2.1.0) | MEF-ADR-0014 |
| Frontera GET vs QUERY, paginacion y filtros multiples de las read APIs (RFC 10008) | MEF-ADR-0042 |
| `Listar{X}s` conserva nombre y ruta cuando su verbo es QUERY (solo cambia el verbo del `HttpTriggerAttribute`) | MEF-ADR-0006 |
| Enmienda a MEF-ADR-0031: el fallback a "solo 200" no es seguro con un deploy concurrente tocando el FA bajo prueba; tercera clase de invocador (deploy de un componente que prueba un FA ajeno) | MEF-ADR-0031 |
| Consecuencias del verbo QUERY en el borde APIM: `<allowed-methods>` por enumeracion explicita con `QUERY` (B3), operacion wildcard del verbo (B11) y gate empirico end-to-end | MEF-ADR-0032 |
| Trampa B11 de APIM: sin operaciones declaradas el gateway responde 404 a todo el trafico; fix con operacion wildcard por verbo, trade-off documentado frente a OWASP API5:2023 | MEF-ADR-0032 |
| Doctrina HTTP de comandos: test de precedencia (POST coleccion/PUT/DELETE/`POST {recurso}:{verbo}`), ids URL-safe, casing kebab-case y simetria CQRS | MEF-ADR-0043 |
| Casing kebab-case minusculo de las rutas HTTP y remision a MEF-ADR-0043 para el verbo y forma de ruta de comandos | MEF-ADR-0006 |
| Contrato HTTP de comandos (verbo + ruta + precedencia aplicada) como campo Critico del Definition of Ready | MEF-ADR-0011 |
| Politica de aceptacion de ids/codigos de negocio en segmentos de URI (charset RFC 3986 unreserved, criterio rechazar-vs-normalizar por propiedad del dato, momento de la invariante en issue previo dedicado) | MEF-ADR-0043 |
| Doctrina de comentarios de código mínimos (jerarquía código/comentario/documentación, umbral doble Context Delta + Decision Delta, proscripción de provenance `// HU-XX`, regla de precedencia de citas a ADR, alcance por lenguaje y frontera de limpieza del reviewer) | MEF-ADR-0044 |
| Default `always_on = true` unico del marco (sin distincion dev/prod) y su fundamento de costo real en tiers dedicados | MEF-ADR-0020 |
| Wiring de `always_on` desde el output del modulo `service-plan` hasta `site_config.always_on`, via el input nuevo del modulo `function-app` | MEF-ADR-0021 |
| Enmienda a MEF-ADR-0031: cobertura de la capa de datos con el endpoint dedicado `/api/ready` (defensa en profundidad, probe sin cache del positivo, `ApplyAllDatabaseChangesOnStartup` diferida) | MEF-ADR-0031 |
| Alerta dedicada de spike de excepciones del worker de proyecciones (umbral calibrado empiricamente, gate de deteccion parcial) | MEF-ADR-0034 |
| Desacople de logs de error del sampler de trazas en el read-side (EnableTraceBasedLogsSampler, LogFilteringProcessor) | MEF-ADR-0038 |
| Camino de resolucion de la connection string del worker bajo el overload de opciones del exporter (IConfiguration poblada por el host) | MEF-ADR-0034 |
| Correccion en MEF-ADR-0043 seccion 1.1: lectura por alcances del charset de segmentos de ruta frente a la identidad de stream de MEF-ADR-0037 (Guid por construccion, componente tipado no-Guid sujeto a 1.2/1.3, clave compuesta fuera del sujeto porque nunca viaja entera en un segmento) | MEF-ADR-0043 |
| Precision de MEF-ADR-0037 seccion 2: la unidad del borde HTTP es el componente tipado, no la clave (identidad de un componente vs. de varios) | MEF-ADR-0037 |
| Extension del desacople de logs de error del sampler de trazas al write-side (supresion ratio-dependiente, sin el filtro estructural del worker) | MEF-ADR-0038 |
| Cierre del gap de `mt_version` en la doctrina read-side (receta `UseNumericRevisions` + par de config-tests espejo write-side/read-side, segunda instancia del par de compatibilidad 2) | MEF-ADR-0034 |
| Estándar de nombramiento de recursos Azure (patrón CAF + región + secuencia) | MEF-ADR-0045 |
| Remision del naming de infraestructura base al estandar CAF + region + secuencia (MEF-ADR-0045) | MEF-ADR-0021 |
| Correccion en la nota del issue #245 de MEF-ADR-0006: el nombre del recurso Azure citado pasa a `func-{kebab}-{prefix_func}` (el dominio es el `{uso}` del patron CAF) | MEF-ADR-0006 |
| Generalizacion del par de config-tests espejo a plantilla del par 2 (tabla/tenancy/id como tercera instancia; guarda siempre-activa de la tenancy documental) | MEF-ADR-0034 |
| Enmienda a MEF-ADR-0036: el skill `/purge-store` como mecanismo canonico de ejecucion de la purga deliberada en dev (regla del mismo despliegue intacta) | MEF-ADR-0036 |
| Enriquecimiento coreografiado por el dueño del dato (Content Enricher preferido sobre réplica local) | MEF-ADR-0046 |
| Doctrina de servidores MCP serverless (ruta tecnica, granularidad por BC/proposito, aislamiento, diseno de tools, custodia de la key) | MEF-ADR-0047 |
| Testing de servidores MCP (piramide de tres niveles, verificaciones canonicas del smoke e2e, endpoints de gate propios y credencial de CI en runtime) | MEF-ADR-0048 |
| Enmienda a MEF-ADR-0013: MEF-ADR-0048 extiende la doctrina de smoke tests a servidores MCP | MEF-ADR-0013 |
| Doctrina de exportacion de metricas OTel (descarte total en Function Apps por wildcard, solo familia GC en el worker de proyecciones via vista func-based, fallback de connection string y guardrail de composicion) | MEF-ADR-0038 |
| Clasificacion de los archivos de un servidor MCP en el coverage gate (`*Tool.cs` logica, `*Api.cs` de `Infraestructura/` excluido, records DTO multi-tipo excluidos) | MEF-ADR-0014 |
| Extension obligatoria de la suite smoke MCP ante tool nueva o modificada (pin catalogo, pin `inputSchema.required`, tool call real) | MEF-ADR-0048 |
