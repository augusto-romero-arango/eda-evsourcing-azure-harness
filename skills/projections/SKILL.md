---
name: projections
description: Doctrina de proyecciones Marten y de Functions de query read-only del marco (naming, recetas, read APIs, config-test). Usar cuando se proponga o implemente una proyeccion (SingleStreamProjection/MultiStreamProjection/EventProjection), un read model, o un endpoint HTTP GET de lectura (Obtener{X}/Listar{X}s) sobre QuerySession.
---

# Proyecciones y query read-side

Fuente unica de la doctrina read-side del marco -- MEF-ADR-0035 (estilo de codigo y superficie de consulta), MEF-ADR-0034 (worker de proyecciones y config-test) y MEF-ADR-0006 (naming). El `planner` la usa para proponer un issue `tipo:projection`; los subagentes read-side `projection-test-writer`/`projection-implementer` (issue #365) la precargan via `skills:` para generar codigo -- el par adversarial delgado que escribe tests (roja) e implementa (verde) sin duplicar esta doctrina en su cuerpo. `reviewer` y `smoke-test-writer` (issue #374) tambien la precargan via `skills:` para reconocer los patrones read-side al revisar un PR `tipo:projection` y para generar smoke tests de Functions GET de consulta, sin que un PR puramente write-side pague ningun hallazgo nuevo. El `projections-scaffolder` que crea el scaffold inicial del worker, de `.ReadModels` y de `.Projections.Tests` (issues #367/#375) ya existe, pero **no** escribe ninguna proyeccion ni read model concreto: eso es alcance de los dos subagentes read-side. **No duplicar este contenido en los agentes generalistas write-side** (`implementer`/`test-writer`): si el issue no toca proyecciones, este Skill no se dispara y su costo es cero (MEF-ADR-0033).

**Stack verificado**: Marten `9.12.0` pinneado (MEF-ADR-0003). Toda receta de este Skill debe re-verificarse por compilacion antes de asumir que el ejemplo compila tal cual -- varios detalles de abajo (el `partial`, la superficie de `StoreOptions`) tienen caveats de verificacion documentados en las fuentes citadas.

## 1. Donde corre cada cosa

- El **worker de proyecciones** (`<RootNamespace>.Projections`, un unico proceso por Bounded Context) hostea el daemon asincronico de Marten que materializa proyecciones `Async`. Fija **donde** corre esto MEF-ADR-0034; este Skill no repite esa doctrina de infraestructura.
- Los **read models** (records planos, sin Marten ni transitivamente) viven en `<RootNamespace>.ReadModels`, biblioteca separada referenciada por el worker. Las **clases de proyeccion** (companion `partial`) viven en el **worker** (`<RootNamespace>.Projections`), el ensamblado que si referencia Marten (MEF-ADR-0034 seccion 5).
- El **endpoint HTTP GET** de lectura vive en el Function App del **write-side** del dominio (el worker no tiene ingress) y abre su `QuerySession` desde el `IDocumentStore` ya configurado ahi (MEF-ADR-0035 seccion 4).
- Los **tipos de evento** que tipan `Create`/`Apply` de esas clases de proyeccion viven en `<RootNamespace>.{Dominio}.DomainEvents` -- el worker los alcanza via su `ProjectReference` a ese ensamblado, el mismo que ya referencia el write-side del dominio, **nunca** via una referencia al `.csproj` de un Function App (MEF-ADR-0039 decisiones 2 y 4).

## 2. Elegir la receta: arbol de 3 niveles

De las recetas de proyeccion de Marten, el marco adopta 3 niveles -- ver **[modelos-marten.md](modelos-marten.md)** para el arbol de decision completo, el estilo canonico (record de read model plano + clase de proyeccion companion con los `Create`/`Apply`/`ShouldDelete` estaticos), el requisito `partial` (source generator) y los ejemplos N1/N2:

| Nivel | Receta | Cuando | Auto-generada |
|---|---|---|---|
| N1 | `SingleStreamProjection<T, TId>` (companion class `partial`, `Add<T>()`) | Un solo stream, mismo `AggregateId` | Si (default del scaffolder) |
| N2 | `MultiStreamProjection<T, TId>` (companion class `partial`, `Add<T>()`) | Correlaciona varios streams | Si, cuando el arbol lo indica |
| N3 | `EventProjection`/`IProjection` custom | Ninguna de las anteriores alcanza | No -- exige justificacion (Rule of Three, MEF-ADR-0018) |

N1 y N2 comparten un unico estilo: record de read model plano (sin `partial`) en `ReadModels` + clase de proyeccion companion `partial` en el worker. Ambos niveles registran su ciclo de vida en el named store del **worker** (`opts.Projections.Add<T>(ProjectionLifecycle.Async)`) -- nunca en el write-side. `Inline` es una excepcion opt-in que vive en el write-side (MEF-ADR-0034 seccion 3), no en este worker.

## 3. Consultar el resultado: tres vias, todas sobre `QuerySession`

Ver **[read-apis.md](read-apis.md)** para la tabla completa de read APIs, el patron de seguridad tenant-scoped (mitigacion BOLA/IDOR), la firma tipada del `id` de ruta (MEF-ADR-0037) y el caveat de `FetchLatest`. Resumen:

- **(a) Proyeccion materializada**: `session.LoadAsync<TView>(id)` / `session.Query<TView>()` -- la via mas barata, por defecto.
- **(b1) Aggregate en vivo** (`Live`, sin persistir nada): `session.Events.AggregateStreamAsync<T>(id)` -- mismo mecanismo que ya usa el write-side (MEF-ADR-0015).
- **(b2) Eventos crudos**: `session.Events.FetchStreamAsync(id)` -- para auditoria/debugging.
- `FetchLatest<T>(id)` es **opt-in, no default** -- exige `IDocumentSession` (sesion de escritura), no `IQuerySession`.

**Regla de seguridad no negociable**: toda `QuerySession` se abre acotada al tenant que resolvio `ITenantResolver` (MEF-ADR-0028) -- `store.QuerySession(tenantResolver.TenantId)` -- **nunca** a un tenant id que llegue en la ruta/query string/body. El id de recurso (`turnoId`) si viene de la ruta; el tenant, nunca.

**Regla de identidad no negociable (MEF-ADR-0037)**: el `id` de ruta se parsea tipado una sola vez antes de tocar cualquier read API -- `Guid.TryParse` si la identidad nacio `Guid`, componentes tipados + `ComputarStreamId(...)` si es clave compuesta -- con `400` explicito (`BadRequestObjectResult` con mensaje) si el parseo falla. **Proscrito**: recibir la clave ya armada como `string` y pasarla cruda a `LoadAsync`/`AggregateStreamAsync`/`FetchStreamAsync`. El `ToString()` posterior al parseo aplica solo cuando el id **es** un stream key (N1, `TId = string`); un read model N2 con `TId` del slicer se parsea tipado igual, pero se pasa el valor tipado (frontera en [read-apis.md](read-apis.md)).

Time-travel (`version`/`timestamp` en `AggregateStreamAsync`) queda diferido -- Rule of Three, MEF-ADR-0018.

## 4. Naming: Functions de query y artefactos de proyeccion

Ver **[naming.md](naming.md)** para el patron completo (verbo + cardinalidad, ruta REST, organizacion vertical, tabla de convenciones C#). Resumen:

| Concepto | Patron | Ejemplo |
|---|---|---|
| Query por id | `Obtener{X}` | `ObtenerTurno` |
| Query por filtro/lista | `Listar{X}s` (plural real del espanol) | `ListarTurnos` |
| Read model | `{Concepto}View` | `TurnoView` |
| Clase de proyeccion (N1/N2) | `{Concepto}Projection` (`partial`) | `ResumenEquipoProjection` |
| Marker del named store | `I{Dominio}ProjectionStore` | `IVentasProjectionStore` |
| Seam de composicion | `ConfiguracionMartenProjections{Dominio}.Configurar{Dominio}()` | `ConfiguracionMartenProjectionsVentas.ConfigurarVentas()` |

**Nunca** `XQueriesEndpoint` agrupando todas las queries de un dominio -- una carpeta por query, sin sufijo `Function` (ese sufijo es solo para comandos, por la colision con el record).

## 5. Config-test del worker

Ver **[config-test.md](config-test.md)** para la plantilla completa (PR 134 del consumidor de referencia). El worker de proyecciones necesita un config-test hermano de MEF-ADR-0029 que, sin Postgres real, verifique: (1) la guarda del `partial` (cada `I{Dominio}ProjectionStore` resuelve del contenedor), (2) que ninguna proyeccion del worker quedo con lifecycle `Inline`, y (3) una guarda barata de que la configuracion de metadata (`CorrelationIdEnabled`/`CausationIdEnabled`/`HeadersEnabled`) coincide con la del write-side de ese dominio -- subconjunto de la compatibilidad Marten completa (diez atributos del paquete, mas el par read models/query-side), que verifica el reviewer bajo gate (MEF-ADR-0034 seccion 6, issue #447).

## 6. Que NO fija este Skill

- El agente `projections-scaffolder` / skill `/scaffold-projections` que genera este codigo (issue #367).
- La receta del `planner` para `tipo:projection` y su Definition of Ready (issues #366/#373).
- El carve-out de coverage del endpoint GET (issue #371).

## Recursos

- **[modelos-marten.md](modelos-marten.md)** -- arbol de decision N1/N2/N3, estilo canonico, requisito `partial`.
- **[read-apis.md](read-apis.md)** -- tabla de read APIs sobre `QuerySession`, patron de seguridad tenant-scoped.
- **[naming.md](naming.md)** -- naming de Functions de query y artefactos de proyeccion, organizacion vertical.
- **[config-test.md](config-test.md)** -- plantilla del config-test del worker (PR 134).
