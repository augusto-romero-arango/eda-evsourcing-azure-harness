---
name: projections
description: Doctrina de proyecciones Marten y de Functions de query read-only del marco (naming, recetas, read APIs, paginacion y filtros, config-test). Usar cuando se proponga o implemente una proyeccion (SingleStreamProjection/MultiStreamProjection/EventProjection), un read model, o un endpoint HTTP de lectura sobre QuerySession -- GET o QUERY/RFC 10008 (Obtener{X}/Listar{X}s), incluyendo su paginacion (keyset/cursor u offset) y sus filtros combinados.
---

# Proyecciones y query read-side

Fuente unica de la doctrina read-side del marco -- MEF-ADR-0035 (estilo de codigo y superficie de consulta), MEF-ADR-0034 (worker de proyecciones y config-test), MEF-ADR-0006 (naming), MEF-ADR-0041 (forma propia de la vista, `ReadModels` como cuarta isla) y MEF-ADR-0042 (frontera GET vs QUERY, paginacion y filtros multiples). El `planner` la usa para proponer un issue `tipo:projection`; los subagentes read-side `projection-test-writer`/`projection-implementer` (issue #365) la precargan via `skills:` para generar codigo -- el par adversarial delgado que escribe tests (roja) e implementa (verde) sin duplicar esta doctrina en su cuerpo. `reviewer` y `smoke-test-writer` (issue #374) tambien la precargan via `skills:` para reconocer los patrones read-side al revisar un PR `tipo:projection` y para generar smoke tests de Functions GET de consulta, sin que un PR puramente write-side pague ningun hallazgo nuevo. El `projections-scaffolder` que crea el scaffold inicial del worker, de `.ReadModels` y de `.Projections.Tests` (issues #367/#375) ya existe, pero **no** escribe ninguna proyeccion ni read model concreto: eso es alcance de los dos subagentes read-side. **No duplicar este contenido en los agentes generalistas write-side** (`implementer`/`test-writer`): si el issue no toca proyecciones, este Skill no se dispara y su costo es cero (MEF-ADR-0033).

**Stack verificado**: Marten `9.12.0` pinneado (MEF-ADR-0003). Toda receta de este Skill debe re-verificarse por compilacion antes de asumir que el ejemplo compila tal cual -- varios detalles de abajo (el `partial`, la superficie de `StoreOptions`) tienen caveats de verificacion documentados en las fuentes citadas.

## 1. Donde corre cada cosa

- El **worker de proyecciones** (`<RootNamespace>.Projections`, un unico proceso por Bounded Context) hostea el daemon asincronico de Marten que materializa proyecciones `Async`. Fija **donde** corre esto MEF-ADR-0034; este Skill no repite esa doctrina de infraestructura.
- Los **read models** (records planos, sin Marten ni transitivamente) viven en `<RootNamespace>.ReadModels`, biblioteca separada referenciada por el worker. `ReadModels` es la **cuarta isla** del criterio de cero `ProjectReference` que MEF-ADR-0039 decision 2 (enmendada por MEF-ADR-0041) fija para los ensamblados de evento: no referencia ningun `{Dominio}.DomainEvents`, ni `PublicEvents`/`PrivateEvents`, ni ningun otro proyecto del repo -- sus records solo declaran campos primitivos. Las **clases de proyeccion** (companion `partial`) viven en el **worker** (`<RootNamespace>.Projections`), el ensamblado que si referencia Marten (MEF-ADR-0034 seccion 5).
- El **endpoint HTTP de lectura** (GET o QUERY, MEF-ADR-0042) vive en el Function App del **write-side** del dominio (el worker no tiene ingress) y abre su `QuerySession` desde el `IDocumentStore` ya configurado ahi (MEF-ADR-0035 seccion 4).
- Los **tipos de evento** que tipan `Create`/`Apply` de esas clases de proyeccion viven en `<RootNamespace>.{Dominio}.DomainEvents` -- el worker los alcanza via su `ProjectReference` a ese ensamblado, el mismo que ya referencia el write-side del dominio, **nunca** via una referencia al `.csproj` de un Function App (MEF-ADR-0039 decisiones 2 y 4).

## 2. Elegir la receta: arbol de 3 niveles

De las recetas de proyeccion de Marten, el marco adopta 3 niveles -- ver **[modelos-marten.md](modelos-marten.md)** para el arbol de decision completo, el estilo canonico (record de read model plano + clase de proyeccion companion con los `Create`/`Apply`/`ShouldDelete` estaticos), el requisito `partial` (source generator) y los ejemplos N1/N2:

| Nivel | Receta | Cuando | Auto-generada |
|---|---|---|---|
| N1 | `SingleStreamProjection<T, TId>` (companion class `partial`, `Add<T>()`) | Un solo stream, mismo `AggregateId` | Si (default del scaffolder) |
| N2 | `MultiStreamProjection<T, TId>` (companion class `partial`, `Add<T>()`) | Correlaciona varios streams | Si, cuando el arbol lo indica |
| N3 | `EventProjection`/`IProjection` custom | Ninguna de las anteriores alcanza | No -- exige justificacion (Rule of Three, MEF-ADR-0018) |

N1 y N2 comparten un unico estilo: record de read model plano (sin `partial`) en `ReadModels` + clase de proyeccion companion `partial` en el worker. Ambos niveles registran su ciclo de vida en el named store del **worker** (`opts.Projections.Add<T>(ProjectionLifecycle.Async)`) -- nunca en el write-side. `Inline` es una excepcion opt-in que vive en el write-side (MEF-ADR-0034 seccion 3), no en este worker.

El record de `ReadModels` **nunca** importa un tipo de `{Dominio}.DomainEvents` -- ni el evento completo ni un tipo anidado suyo. Su forma -- que campos, que nombres, que cardinalidad -- no se copia del evento que la alimenta ni del aggregate que el dominio ya mantiene: se deriva del *handoff* del issue `tipo:projection`, producto del knowledge crunching del planner sobre la necesidad de lectura concreta y el vocabulario de quien consume la vista (MEF-ADR-0041 decision 1, MEF-ADR-0008). La clase de proyeccion companion (`{TerminoVista}Projection`) es el unico punto de mapeo `evento -> vista`: sus `Create`/`Apply` **traducen** forma y nombres desde el evento hacia el record -- nunca copian el tipo del evento ni replican el nombramiento del write-side (MEF-ADR-0041 decision 2).

## 3. Consultar el resultado: tres vias, todas sobre `QuerySession`

Ver **[read-apis.md](read-apis.md)** para la tabla completa de read APIs, el patron de seguridad tenant-scoped (mitigacion BOLA/IDOR), la firma tipada del `id` de ruta (MEF-ADR-0037) y el caveat de `FetchLatest`. Resumen:

- **(a) Proyeccion materializada**: `session.LoadAsync<TView>(id)` / `session.Query<TView>()` -- la via mas barata, por defecto.
- **(b1) Aggregate en vivo** (`Live`, sin persistir nada): `session.Events.AggregateStreamAsync<T>(id)` -- mismo mecanismo que ya usa el write-side (MEF-ADR-0015).
- **(b2) Eventos crudos**: `session.Events.FetchStreamAsync(id)` -- para auditoria/debugging.
- `FetchLatest<T>(id)` es **opt-in, no default** -- exige `IDocumentSession` (sesion de escritura), no `IQuerySession`.

**Dos condiciones no negociables para que el write-side resuelva `TView`** (par de compatibilidad 2, MEF-ADR-0034 seccion 6): misma politica de tenancy documental en ambos lados, y `opts.Schema.For<TView>().UseNumericRevisions(true)` en el `ComposicionServicios{Dominio}.cs` del Function App **por cada** documento consultado -- Marten impone `mt_version bigint` al documento que el worker materializa, y sin esa linea la primera query dispara un `ALTER COLUMN` que Postgres rechaza (`42804`) y tumba toda la sesion del store. Se escribe en el **mismo issue** que agrega la superficie de consulta, junto con su par de config-tests espejo ([config-test.md](config-test.md)). Receta y evidencia en [read-apis.md](read-apis.md).

**Regla de seguridad no negociable**: toda `QuerySession` se abre acotada al tenant que resolvio `ITenantResolver` (MEF-ADR-0028) -- `store.QuerySession(tenantResolver.TenantId)` -- **nunca** a un tenant id que llegue en la ruta/query string/body. El id de recurso (`turnoId`) si viene de la ruta; el tenant, nunca.

**Regla de identidad no negociable (MEF-ADR-0037)**: el `id` de ruta se parsea tipado una sola vez antes de tocar cualquier read API -- `Guid.TryParse` si la identidad nacio `Guid`, el parser y el `ToString()` del propio tipo si es un VO unico no-`Guid`, o componentes tipados + `ComputarStreamId(...)` si es clave compuesta -- con `400` explicito (`BadRequestObjectResult` con mensaje) si el parseo falla. **Proscrito**: que el segmento de ruta viaje sin parsear hasta `LoadAsync`/`AggregateStreamAsync`/`FetchStreamAsync`, y que una clave de **varios** componentes viaje ya concatenada en un unico segmento -- esa segunda proscripcion no alcanza a una identidad de un solo componente. El `ToString()` posterior al parseo aplica solo cuando el id **es** un stream key (N1, `TId = string`); un read model N2 con `TId` del slicer se parsea tipado igual, pero se pasa el valor tipado (frontera en [read-apis.md](read-apis.md)).

**GET o QUERY (MEF-ADR-0042)**: `Obtener{X}` por id es siempre GET; `Listar{X}s` va sobre **GET** cuando sus filtros son pares planos de igualdad en query string, y sobre **QUERY** (RFC 10008) cuando lleva filtros estructurados (AND/OR, rangos, listas de valores) o paginacion por cursor. Cruzar esa frontera no cambia el nombre de la Function ni su `Route` -- solo el verbo. Paginacion: **keyset/cursor por default**, offset como excepcion documentada (Rule of Three). Filtro: **DTO tipado** del body, `Content-Type: application/json` obligatorio, AND por defecto, codigos `400`/`415`/`422` siempre con mensaje. Mecanica y ejemplo canonico en [read-apis.md](read-apis.md).

Time-travel (`version`/`timestamp` en `AggregateStreamAsync`) queda diferido -- Rule of Three, MEF-ADR-0018.

## 4. Naming: Functions de query y artefactos de proyeccion

Ver **[naming.md](naming.md)** para el patron completo (verbo + cardinalidad, ruta REST, organizacion vertical, tabla de convenciones C#). Resumen:

| Concepto | Patron | Ejemplo |
|---|---|---|
| Query por id | `Obtener{X}` | `ObtenerTurno` |
| Query por filtro/lista | `Listar{X}s` (plural real del espanol; GET o QUERY segun MEF-ADR-0042, mismo nombre y ruta) | `ListarTurnos` |
| Read model | Termino del glosario, sin sufijo de implementacion (MEF-ADR-0041) | `ResumenAsistenciaDiaria` |
| Clase de proyeccion (N1/N2) | `{TerminoVista}Projection` (`partial`, mismo stem que la vista) | `ResumenAsistenciaDiariaProjection` |
| Marker del named store | `I{Dominio}ProjectionStore` | `IVentasProjectionStore` |
| Seam de composicion | `ConfiguracionMartenProjections{Dominio}.Configurar{Dominio}()` | `ConfiguracionMartenProjectionsVentas.ConfigurarVentas()` |

El read model **pierde el sufijo `View`**: su nombre es un termino del lenguaje ubicuo derivado de la necesidad de lectura, nunca un calco del evento o del aggregate (MEF-ADR-0041 decision 3, detalle en [naming.md](naming.md)).

**Nunca** `XQueriesEndpoint` agrupando todas las queries de un dominio -- una carpeta por query, sin sufijo `Function` (ese sufijo es solo para comandos, por la colision con el record).

## 5. Config-test del worker

Ver **[config-test.md](config-test.md)** para la plantilla completa (PR 134 del consumidor de referencia). El worker de proyecciones necesita un config-test hermano de MEF-ADR-0029 que, sin Postgres real, verifique: (1) la guarda del `partial` (cada `I{Dominio}ProjectionStore` resuelve del contenedor), (2) que ninguna proyeccion del worker quedo con lifecycle `Inline`, y (3) una guarda barata de que la configuracion de metadata (`CorrelationIdEnabled`/`CausationIdEnabled`/`HeadersEnabled`) coincide con la del write-side de ese dominio -- subconjunto de la compatibilidad Marten completa (diez atributos del paquete, mas el par read models/query-side), que verifica el reviewer bajo gate (MEF-ADR-0034 seccion 6, issue #447).

El mismo documento fija el **par de config-tests espejo de `mt_version`** (issue #718): un test por lado -- `ComposicionServicios{Dominio}Tests` del dominio y `ConfiguracionMartenProjectionsTests` del worker --, cada uno sobre su **propio** store, afirmando los mismos tres oraculos literales via `Options.FindOrResolveDocumentType(typeof(TView))`. Es la guarda **siempre-activa** de la receta `UseNumericRevisions(true)` de [read-apis.md](read-apis.md): corre en cada `dotnet test`, sin depender de que un diff dispare el gate del reviewer.

## 6. Que NO fija este Skill

- El agente `projections-scaffolder` / skill `/scaffold-projections` que genera este codigo (issue #367).
- La receta del `planner` para `tipo:projection` y su Definition of Ready (issues #366/#373).
- El carve-out de coverage del endpoint GET (issue #371).

## Recursos

- **[modelos-marten.md](modelos-marten.md)** -- arbol de decision N1/N2/N3, estilo canonico, requisito `partial`.
- **[read-apis.md](read-apis.md)** -- tabla de read APIs sobre `QuerySession`, patron de seguridad tenant-scoped.
- **[naming.md](naming.md)** -- naming de Functions de query y artefactos de proyeccion, organizacion vertical.
- **[config-test.md](config-test.md)** -- plantilla del config-test del worker (PR 134).
