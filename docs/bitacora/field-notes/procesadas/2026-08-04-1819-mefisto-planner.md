---
fecha: 2026-08-04
hora: 18:19
sesion: mefisto-planner
tema: Refinamiento del draft #483 (siete hallazgos del primer read-side real) y desglose en 6 issues + 1 draft
---

## Contexto

El draft #483 llego del consumidor `Bitakora.ControlAsistencia` con siete hallazgos "verificados por
ejecucion" sobre la doctrina de proyecciones (MEF-ADR-0034/0035 y el Agent Skill `projections`),
descubiertos al planear su primera proyeccion real. Uno de ellos se reporto como falla silenciosa.

En vez de repartir los hallazgos tal como venian, se re-verificaron todos por ejecucion propia
(Marten `9.12.0`, SDK .NET 10.0.201, sin Postgres, en dos proyectos desechables bajo `/tmp/mef483/`).
Esa decision cambio el contenido de tres hallazgos y destapo dos que el draft no traia.

## Descubrimientos

### La lista de argumentos de un metodo convencional es cerrada, y `TId` nunca estuvo en ella

La doc oficial de Marten (`events/projections/conventions.html`) enumera lo que `Create` admite: el
tipo del evento, `IEvent<T>`, `IEvent`, `IQuerySession`. `Create(TEvento, TId)` **no es una firma que
Marten descarte**: es una que no existe. Reencuadre importante -- deja de ser "bug de Marten" y pasa a
ser "expectativa razonable del desarrollador que el marco debe desactivar".

### El dano real del hallazgo 1 es otro del reportado

Leyendo los dispatchers emitidos (`-p:EmitCompilerGeneratedFiles=true`): el `Apply` sobre
`RuntimeHelpers.GetUninitializedObject(...)` que el draft senalaba como el dano es el patron **normal**
para cualquier evento con `Apply` y sin `Create` -- aparece igual en el caso correcto. El dano es que
el evento creador **desaparece de `EventTypes`**, el filtro de tipos con que el daemon decide que
eventos alimentan la proyeccion.

Leccion de metodo: el draft dedujo el dano de leer el dispatcher de la variante mala **sin comparar
contra el de la variante buena**. La comparacion era el experimento, no la lectura.

### `Create(IEvent<TEvento>)` es el camino principal en este marco, no un caso de borde

Se honra en N1 y N2, y expone `StreamKey`/`StreamId`. Y como el marco fija `StreamIdentity.AsString`,
la identidad del read model N1 **es** el stream key -- que no viaja en el payload del evento. Asi que
la firma con `IEvent<T>` no es un lujo para metadata: es la unica via para construir la identidad en
el caso normal.

Corolario: "una proyeccion no puede saber que identidad esta construyendo" es **falso en N1** y
**cierto en N2 con fan-out** (ahi la identidad del slice la calcula el slicer y nunca llega al metodo;
`StreamKey` da el stream de origen, no el documento agregado). El corolario del draft sobre
`IEventSlicer`/N3 para el fan-out se sostiene, por una razon mas fina que la que dio.

### Hallazgo que el draft no traia: los ejemplos canonicos no arrancan

`SingleStreamProjection<TurnoView, Guid>` + `record TurnoView(Guid Id, ...)` contra un store con
`StreamIdentity.AsString` da `InvalidProjectionException: Id type mismatch`. Esta en MEF-ADR-0035
seccion 2 (lineas 49/53/86/88), en `skills/projections/modelos-marten.md` (22/26/50/52) y -- lo peor --
en `agents/projection-test-writer.md` linea 89, que no lo muestra sino que lo **emite** como stub.

Aparecio por preguntarse *por que* el implementador escribiria `Create(e, id)` en primer lugar. La
pregunta "que problema tenia encima el que escribio esto" rindio mas que revisar el codigo del draft.

### Segundo hallazgo nuevo: el formato de la conversion Guid -> string no esta fijado

Si la identidad nace como Guid y vive como string, el formato (`"D"` vs `"N"` vs `"B"`) es contrato de
datos. Hoy todos los ejemplos usan `ToString()` por **costumbre, no por regla**, y el borde HTTP del
GET pasa texto crudo de la ruta a `LoadAsync<TView>(id)` -- comparacion de texto, presumiblemente
sensible a mayusculas (no verificado contra Postgres). Vecino: el `GroupId`/`SessionId` de
MEF-ADR-0026 usa la misma clave.

### `StreamIdentity.AsString` es una decision habilitante, no una herencia del paquete

El marco **necesita** identidades que no son Guid: el stream ID compuesto (`EmpleadoId:Fecha` via
`ComputarStreamId`) de `agents/implementer.md`. Con `AsGuid` ese patron seria imposible. Explica el
precio que paga todo el sistema, incluidos los aggregates cuya key si es Guid.

### La convergencia write/read del hallazgo 2 depende de la politica de tenancy

El reporte midio `TenancyStyle = Conjoined` en ambos lados; una sonda desnuda mide `Single` en ambos.
La diferencia es `Policies.AllDocumentsAreMultiTenanted()`, que el paquete aplica del lado write --
o sea el **par de compatibilidad 2** que MEF-ADR-0034 seccion 6 ya nombro. Cerrar el punto abierto sin
esa condicion habria sido peor que dejarlo abierto.

### Puntos abiertos del marco que se pueden cerrar de paso

- `config-test.md` guarda 2 pedia "reverificar la superficie exacta de `StoreOptions.Projections`":
  `store.Options.Events.Projections()` expone `.Name` y `.Lifecycle`. Cerrado.
- `.Name` es el nombre de la **vista**, no de la clase de proyeccion (`Name='TurnoView'` para
  `ProyeccionOk`). Una guarda por nombre de clase fallaria siempre.
- La `InvalidProjectionException` llega **envuelta en `TargetInvocationException`** al resolver del
  contenedor: el assert debe desenvolver `InnerException`.
- `Event<T>` es instanciable en un unit test con `StreamKey`/`Version`/`Timestamp`/`TenantId`
  settables, y vive en el assembly **`JasperFx.Events`** (no `Marten.Events`) -- otra instancia de la
  regla de namespaces de MEF-ADR-0034 seccion 6.
- `IReadOnlyStoreOptions` no expone `AutoCreateSchemaObjects` (`CS1061`); requiere cast a
  `StoreOptions`.

### Modo de falla silencioso sin issue propio todavia

Registrar proyecciones `Async` sin `AddAsyncDaemon` solo emite un `Warning:` por consola. Un dominio
cuyo seam olvide `AddAsyncDaemon(DaemonMode.HotCold)` pasa todos los tests en verde y su daemon nunca
corre. Anotado en #496 como candidato a guarda 4, deliberadamente fuera de su alcance.

## Decisiones

- **Firmas admitidas**: `TEvento` (default) + `IEvent<TEvento>` (cuando la identidad o la metadata se
  necesitan). `Create/Apply(TEvento, TId)` proscrita. `IQuerySession` como **opt-in justificado en el
  issue**, no prohibido -- usando la categoria que MEF-ADR-0035 ya tiene para `FetchLatest`. Razon:
  una prohibicion absoluta es la clase de regla que un agente rompe cuando se topa con el caso real y
  no tiene salida documentada.
- **Regla de procedencia en vez de lista de campos**: un metodo de proyeccion puede leer lo que sale
  del evento persistido; no lo que sale de estado externo (consulta, reloj, config). Misma forma
  regla-no-lista que MEF-ADR-0034 seccion 6 adopto para el corte write/read. Explica *por que*
  `IQuerySession` queda afuera (determinismo del rebuild) sin necesidad de mantener una tabla.
- **Identidad del read model: `string` desnudo.** El strong-typed sobre string **funciona** (probado),
  pero no se adopta: el read model viaja como JSON al cliente por el GET y un id envuelto serializa
  como `{"Id":{"Value":"..."}}`; MEF-ADR-0012 ya lo clasifica como record plano sin invariantes. Se
  registra como alternativa considerada, no se cruza.
- **Reparto en 6 issues + 1 draft**, siguiendo el precedente #412 (ADR) -> #413 (propagacion) para el
  hallazgo grave, y agrupando por tema los que solo anaden precision:
  - #493 (bug): MEF-ADR-0035 secciones 1-2 -- firmas + identidad. Sin dependencias.
  - #494 (bug, depende de #493): propagacion a Skill + `projection-implementer` +
    `projection-test-writer`.
  - #495 (depende de #494): analizador dentro del paquete Marten + namespaces de las clases base.
  - #496: guardas 1 y 2 del config-test (MEF-ADR-0034 seccion 6 + `config-test.md`).
  - #497: cierra el punto abierto de MEF-ADR-0035 seccion 4, con la condicion de tenancy.
  - #498: `AutoCreateSchemaObjects = CreateOrUpdate` en Production, como hecho operativo.
  - #499 (borrador): formato de conversion Guid -> string.
- **#499 queda en borrador a proposito**: su sede no esta decidida (MEF-ADR-0036 trata del alias del
  tipo de evento, no de la key del stream) y su alcance toca el write-side. Meterlo con los de
  proyecciones lo habria vuelto ambiguo.

## Descartado

- **Un issue por hallazgo** (7 issues mecanicos): los hallazgos 1 y 8 editan las mismas 4 lineas de
  ejemplo, y 3+6 / 4+5 son pares homogeneos. Se agruparon por tema.
- **Partir #495 en ADR + propagacion**: es una correccion de una frase mas los `using` de los
  ejemplos; dos PRs para eso es ceremonia sin beneficio. Solo el hallazgo grave paga la particion.
- **Convertir la condicion de tenancy de #497 en guarda del config-test**: MEF-ADR-0034 seccion 6
  (issue #447) ya decidio que la verificacion completa de compatibilidad es del **reviewer** bajo
  gate. No se reabre ese reparto.
- **Auditar los `.csproj` que emiten los scaffolders** buscando `ExcludeAssets`: verificado que hoy
  ninguno excluye assets, no hay defecto activo.
- **Endurecer la politica de schema del worker** (`AutoCreate.None` en produccion) a raiz de #498: ese
  issue **registra un hecho**; cambiar el default es otra conversacion con sus trade-offs.
- **Notas de oleadas/paralelismo en los bodies**: del lado interno solo existe `mefisto-sequential`, y
  el motor sincroniza main verificado entre eslabones. Compartir archivo (`modelos-marten.md` lo tocan
  #494 y #495) no impone restriccion; solo las dependencias declaradas ordenan el batch.

## Preguntas abiertas

- **#499**: sede (ADR nuevo `MEF-ADR-0037` vs seccion en MEF-ADR-0012), si el borde HTTP normaliza
  (`Guid.TryParse` + re-`ToString()`) o rechaza, y verificar la sensibilidad a mayusculas contra
  Postgres real.
- **A que tenant queda acotada la `IQuerySession`** que Marten inyecta en un metodo de proyeccion
  dentro del daemon. Anotado como no verificado en #493; es la incognita que sostiene el opt-in.
- **Guarda del daemon deshabilitado**: como afirmarla (inspeccionar `IHostedService` registrados, o
  alguna propiedad del store). Necesita issue propio.
- Todos los hechos de esta sesion estan ligados a Marten `9.12.0`; al subir la version hay que
  reverificar dispatchers, namespaces y la ruta del analizador.

## Referencias

- Issues creados: #493, #494, #495, #496, #497, #498, #499
- Issue cerrado: #483 (`completed`, con el reparto y las tres correcciones al reporte en el comentario)
- Draft de origen: consumidor `augusto-romero-arango/Bitakora.ControlAsistencia`, issues #289/#290 de
  ese repo, sesion de planner del 2026-07-31
- Fuente oficial: https://martendb.io/events/projections/conventions.html (lista cerrada de argumentos
  de `Create`/`Apply`/`ShouldDelete`)
- Sondas de verificacion: `/tmp/mef483/probe` (dispatchers generados) y `/tmp/mef483/di/probe2` (DI,
  mappings, `Id type mismatch`, `AutoCreateSchemaObjects`, `Event<T>`)
