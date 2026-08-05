# MEF-ADR-0037: Identidad del stream y su representacion string canonica

- **Fecha**: 2026-08-04
- **Estado**: aceptado
- **Aplica a**: doctrina de conversion de toda identidad de stream que el marco maneja como clave de Marten (`StartStream`/`ExistsAsync`/`GetAggregateRootAsync`), como `GroupId`/`SessionId` de bus (MEF-ADR-0026) y como parametro de lectura del read-side (`session.LoadAsync<TView>(id)`, MEF-ADR-0034/MEF-ADR-0035). Par simetrico de MEF-ADR-0036 (identidad del **tipo de evento persistido**; sujeto distinto -- ver seccion 3 de la Decision) y vecino, no solapado, de MEF-ADR-0012 (frontera de serializacion de objetos ricos; ver seccion 3). Bloquea #501 (doctrina write-side en `agents/implementer.md`), #502 (doctrina read-side en la skill `projections`/`projection-implementer`) y #503 (chequeos del reviewer) -- ninguno de los tres puede implementarse antes de que este ADR exista.

## Contexto

`Cosmos.EventSourcing.CritterStack` 2.3.1 fija `Events.StreamIdentity = StreamIdentity.AsString` del lado write -- verificado por decompilacion propia (MEF-ADR-0034 referencia [19], `JasperFx.Events` 2.18.1: `StreamIdentity.AsGuid`=0, `AsString`=1). Esa decision del paquete, no del consumidor, es la que habilita el patron de stream ID compuesto que `agents/implementer.md` ya documenta (`EmpleadoId:Fecha` via `MiAggregate.ComputarStreamId(...)`): Marten guarda la clave del stream como texto, nunca como `uuid`, asi que cualquier forma de identidad -- un Guid simple o una clave natural con varios componentes -- converge en el mismo tipo de columna.

**Consecuencia no escrita en ninguna parte hasta ahora**: cuando la identidad nace como `Guid` (el caso comun -- un `TurnoId`, un `EmpleadoId`), el sistema entero opera sobre su representacion `string`, y **el formato exacto de esa conversion es parte del contrato de datos**, no un detalle de estilo. `agents/implementer.md` ya escribe ese patron por todas partes (`Id = e.TurnoId.ToString();`, `comando.TurnoId.ToString()`, `turnoId.ToString()`) y `agents/test-writer.md` ya fija, para el caso compuesto, `$"{empleadoId}:{fecha:yyyy-MM-dd}"` -- pero en los dos casos es **costumbre observada en el codigo de ejemplo**, nunca una regla declarada. Nada impide que un llamador distinto escriba `ToString("N")` (sin guiones), aplique `.ToUpper()`, o invierta el orden de los componentes de una clave compuesta: cualquiera de esas variantes compila, pasa los tests que solo ejercitan ese sitio de forma aislada, y produce en silencio un stream "nuevo" donde debia haber uno existente, o una fila de read model que el GET nunca encuentra.

El riesgo cruza tres superficies del marco:

1. **Store** (`agents/implementer.md`): `StartStream`/`ExistsAsync`/`GetAggregateRootAsync` deben recibir siempre el mismo string para el mismo aggregate -- una diferencia de formato entre la llamada que crea el stream y la que lo busca despues es indistinguible de "el stream no existe".
2. **Bus** (MEF-ADR-0026): `PublishOptions.GroupId` debe coincidir textualmente con la clave del aggregate destino (`SessionId` a nivel de protocolo). MEF-ADR-0026 seccion 2 ya fija esto como invariante dura para el caso session-enabled; una divergencia de formato tiene el mismo efecto observable que un mensaje sin `GroupId`: dead-letter silencioso en la entidad fuente.
3. **Read-side** (MEF-ADR-0034/MEF-ADR-0035): `session.LoadAsync<TView>(id)` (MEF-ADR-0035 seccion 4) compara el `id` recibido contra la columna de texto del documento que el worker materializo -- una comparacion exacta en Postgres, sensible a mayusculas por defecto (ver CA-4 mas abajo).

**Por que no lo cubre ninguna sede existente.** MEF-ADR-0036 fija la identidad del **tipo de evento persistido** -- la columna `type`/alias de `mt_events`, resuelta por `EventNamingStyle` -- un eje ortogonal: un evento puede resolver su tipo CLR correctamente y, aun asi, pertenecer a un stream localizado bajo la clave equivocada, sin que MEF-ADR-0036 diga nada al respecto. MEF-ADR-0012 fija la "frontera de serializacion" -- como un objeto con campos privados se (de)serializa a traves del event store de Marten y del bus -- una pregunta sobre la **forma** de un tipo rico; la clave de stream, en cambio, nunca es un tipo rico en ninguna de las tres superficies de arriba: siempre llega y sale como `string` o `Guid` primitivo, asi que MEF-ADR-0012 no tiene nada que decir sobre su formato.

## Decision

### 1. Dos clases de identidad y el principio del punto unico de conversion (CA-1)

**Identidad nacida `Guid`** (el caso comun): la conversion a string es `guid.ToString()` sin argumentos -- el formato canonico "D", siempre en minusculas. Verificado contra la documentacion oficial de .NET: *"The value of this Guid, formatted by using the 'D' format specifier ... represented as a series of lowercase hexadecimal digits in groups of 8, 4, 4, 4, and 12 digits and separated by hyphens. An example of a return value is '382c74c3-721d-4f34-80e5-57657b6cbc27'"* [1]. Es exactamente el formato que `agents/implementer.md` ya usa por costumbre (`e.TurnoId.ToString()`); este ADR lo eleva de costumbre a regla.

**Clave natural compuesta**: el metodo estatico `MiAggregate.ComputarStreamId(...)` del propio aggregate es el **unico** punto de conversion. Dentro de el, todo componente `Guid` se formatea con `ToString()` sin argumentos (mismo canonico "D") y todo componente fecha/hora usa un formato fijo que el propio metodo elige explicitamente -- precedente ya vigente en `agents/test-writer.md`: `$"{empleadoId}:{fecha:yyyy-MM-dd}"` (interpolar un `Guid` sin especificador invoca implicitamente `ToString()` sin argumentos -- el mismo canonico, no un atajo distinto).

**Principio unificador**: la representacion string de una identidad de stream se produce en un **unico punto por aggregate**. Ningun otro codigo del dominio -- CommandHandler, EventHandler, endpoint HTTP, proyeccion -- concatena ni formatea la clave por su cuenta; todo consumidor usa el valor que ya produjo ese punto unico (la propiedad `Id` del aggregate tras `Apply()`, o el retorno de `ComputarStreamId(...)`).

Para la clave compuesta, la coherencia entre escritura y lectura es **por construccion** (todo llamador invoca el mismo `ComputarStreamId(...)`), no una regla de formato que alguien deba memorizar y aplicar igual en cada sitio -- eso tolera cualquier estructura de clave natural futura (mas o menos componentes, otro separador) sin que este ADR necesite enmendarse.

### 2. Borde HTTP: normalizacion por tipado, nunca la clave ya armada como string (CA-2)

**Identidad `Guid`**: parametro de ruta tipado `Guid` (constraint/binder de ruta). El model binding acepta las variantes de mayusculas y de formato que igualmente representan el mismo valor, y el `400` queda reservado para texto que ni siquiera parsea como `Guid`. Una vez enlazado, la unica conversion a string en toda la request es la del punto unico de la seccion 1 (`id.ToString()`) -- el texto crudo de la ruta nunca llega al dominio.

**Clave compuesta**: componentes tipados por separado en la ruta (p. ej. un segmento `Guid` y un segmento fecha, cada uno con su propio binder), reconstruidos con `ComputarStreamId(...)` antes de tocar el store.

**Proscrito**: un parametro de ruta `string` que reciba la clave ya concatenada. Ese atajo reintroduce el riesgo completo de la seccion "Contexto" -- el cliente (o un test, o un futuro agente) puede enviar cualquier formato, orden o mayuscula que igual compile como `string`, sin que el binding tenga oportunidad de normalizar nada.

**Regla unica: normalizacion, no rechazo.** El `400` existe solo para texto que no parsea como el tipo declarado (un `Guid` invalido, una fecha invalida) -- nunca para una variante de formato que si parsea pero no coincide byte a byte con el canonico. Esas las normaliza el binding tipado, no el llamador.

### 3. Tres superficies con cross-referencias; deslinde de MEF-ADR-0036 y MEF-ADR-0012 (CA-3)

- **Store** (`agents/implementer.md`): `StartStream`/`ExistsAsync`/`GetAggregateRootAsync` reciben siempre el string que produjo el punto unico de la seccion 1 -- nunca una reconstruccion paralela dentro del handler.
- **Bus** (MEF-ADR-0026 seccion 2): `PublishOptions.GroupId` = `SessionId` = la clave del aggregate destino, la misma usada en `StartStream`/`GetAggregateRootAsync`. MEF-ADR-0026 ya fija esta correspondencia como invariante dura para el caso session-enabled (fan-in); este ADR es la razon de fondo de por que el valor debe coincidir textualmente, no solo semanticamente.
- **Read-side** (MEF-ADR-0034 seccion 6 / MEF-ADR-0035 seccion 4): `session.LoadAsync<TView>(id)` compara el `id` recibido contra la columna del documento materializado por el worker -- comparacion de texto en Postgres (CA-4). El `id` que la proyeccion write-side asigna a la vista sale de `IEvent<TEvento>.StreamKey` (MEF-ADR-0035, enmienda del issue #493: `Create(IEvent<TurnoCreado> e) => new(e.StreamKey!, ...)`) -- el stream key que Marten ya resolvio, no una reconstruccion propia del payload. Por eso la unica forma en que write-side y read-side pueden divergir es que el punto unico de la seccion 1 no exista o no se respete en algun sitio del write-side: el read-side no tiene un segundo lugar donde el formato pueda torcerse.
- **Deslinde con MEF-ADR-0036**: su sujeto es la identidad del **tipo de evento persistido** -- la columna `type`/alias de `mt_events`, resuelta por `EventNamingStyle`. Son preguntas independientes: "¿que tipo CLR es esta fila de evento?" (MEF-ADR-0036) vs. "¿que stream/documento es este id?" (este ADR). Un evento puede resolver su alias correctamente y, aun asi, el comando que lo genero puede haber operado sobre el stream equivocado si este ADR no se respeta -- y viceversa.
- **Deslinde con MEF-ADR-0012**: su "frontera de serializacion" gobierna la forma de un objeto rico con campos privados al cruzar el event store o un bus -- una cuestion de **construccion** de objetos. La clave de stream, en las tres superficies de arriba, nunca es un tipo rico: siempre es un `string` o un `Guid` primitivo, asi que no hay nada que `ConfigurarSerializacion` necesite resolver aqui.

### 4. Sensibilidad a mayusculas: verificada contra la documentacion oficial de PostgreSQL (CA-4)

El formato "D" de `Guid.ToString()` es siempre minusculas por definicion del propio .NET (seccion 1) -- dentro de una misma ejecucion, dos llamadas sobre el mismo valor producen siempre el mismo texto. El riesgo no es que .NET sea inconsistente: es que nada impide que un llamador se salte el punto unico y el string termine con un casing distinto (un `.ToUpper()` accidental, un id recibido sin normalizar desde el borde HTTP, seccion 2).

Verificado contra la documentacion oficial de PostgreSQL: la comparacion de texto por defecto es sensible a mayusculas, y la unica via insensible es una extension propia del motor, no el comportamiento base -- *"The key word ILIKE can be used instead of LIKE to make the match case-insensitive according to the active locale [...] This is not in the SQL standard but is a PostgreSQL extension"* [2]. El marco no usa `ILIKE` para comparar identidad -- `LoadAsync`/`ExistsAsync`/`GetAggregateRootAsync` comparan por igualdad exacta (`=`), que no ofrece ninguna variante insensible equivalente. Una divergencia de casing entre dos escrituras del mismo id no arroja ninguna excepcion: Postgres las trata simplemente como dos valores distintos, y el sintoma es un stream "nuevo" donde debia existir uno, o un read model que el GET nunca encuentra.

**Queda declarado *no verificado*** el comportamiento de Marten especificamente ante una collation no-deterministica o case-insensitive configurada a nivel de columna/base de datos -- el marco no configura ninguna hoy, y no hay evidencia decompilada de que `Cosmos.EventSourcing.CritterStack` fije una (a diferencia de `StreamIdentity`/`TenancyStyle`/`EventNamingStyle`, que si decompilo MEF-ADR-0034 referencia [19]). La doctrina de este ADR asume el comportamiento por defecto de PostgreSQL.

### 5. Sin helper de runtime; el guardrail real es doctrina + reviewer (CA-5)

Se descarta explicitamente un helper de runtime del harness que envuelva `ToString()` (p. ej. una extension `IdentidadStream.Canonizar(Guid)`). Razon: MEF-ADR-0018 (Rule of Three) -- hoy existe un unico punto de conversion por aggregate, no varios sitios divergentes que reclamen una abstraccion compartida; y aunque existieran, el sitio natural de esa abstraccion seria el paquete `Cosmos.EventSourcing.CritterStack` (que ya modela `StreamIdentity`), no este harness -- Mefisto no distribuye codigo de runtime del consumidor, solo doctrina y scaffolding. `ComputarStreamId` ya es el helper de la clase compuesta (seccion 1); no hace falta un segundo helper por encima de el.

El guardrail real, entonces, no es un tipo que impida compilar el error: es **doctrina + revision**, el mismo reparto que MEF-ADR-0036 ya aplica a sus propios guardrails.

- **Doctrina** (issues #501 y #502): este ADR es la autoridad; #501 propaga la regla al write-side (`agents/implementer.md`) y #502 al read-side (skill `projections`/`projection-implementer`).
- **Reviewer** (issue #503): chequeo que verifique, en cada PR que toque un stream ID, que existe un unico punto de conversion por aggregate y que el borde HTTP no recibe la clave armada como string suelto (seccion 2).

Sin (a) y (b) aterrizados, este ADR fija la doctrina pero no la hace cumplir automaticamente -- el riesgo de "Contexto" sigue latente en la practica hasta que los tres issues cierren la cadena.

## Alternativas consideradas

### Alt 1: helper de runtime en el harness (`IdentidadStream.Canonizar(Guid)` o similar)

**Descartada.** Un wrapper de una linea (`guid.ToString()`) no pasa la Rule of Three de MEF-ADR-0018 -- no hay hoy ni siquiera dos sitios divergentes que reclamen una abstraccion comun, y ese mismo ADR pide no extraer antes del tercer caso real. Ademas, un helper de runtime cae fuera del alcance de este harness (que no distribuye codigo ejecutable del consumidor, solo doctrina/scaffolding); el sitio natural seria el paquete `Cosmos.EventSourcing.CritterStack`, decision que no le corresponde a Mefisto tomar unilateralmente.

### Alt 2: formato canonico distinto de "D" (p. ej. "N", sin guiones)

**Descartada.** "D" es el formato que ya produce `guid.ToString()` sin argumentos -- la forma que `agents/implementer.md` y `agents/test-writer.md` ya usan por costumbre. Fijar un formato distinto exigiria reescribir esos ejemplos y, mas grave, invalidaria cualquier stream o documento ya escrito con "D" en un consumidor que ya tenga datos -- el mismo tipo de riesgo de migracion silenciosa que MEF-ADR-0036 documenta para un evento movido de namespace. Ninguna ventaja tecnica de "N" u otro formato justifica ese costo.

### Alt 3: normalizar en cada punto de comparacion en vez de fijar un unico punto de conversion

**Descartada.** Envolver cada `ExistsAsync`/`GetAggregateRootAsync`/`LoadAsync` con una normalizacion defensiva (p. ej. `id.ToLowerInvariant()`) multiplica los sitios que deben recordar aplicar la regla -- exactamente el problema que la seccion 1 evita fijando un unico punto de conversion por aggregate. Si ese punto unico ya produce el canonico de forma consistente, normalizar en el consumo es innecesario; si no lo produce, normalizar en el consumo esconde el sintoma (dos ids "iguales" salvo mayusculas) sin corregir la causa real (un llamador que no pasa por el punto unico).

## Consecuencias

### Positivas

- El marco fija, por primera vez, que el **formato** de la conversion Guid->string de una identidad de stream es parte del contrato de datos, no un detalle de estilo -- cierra la laguna que hoy deja a `agents/implementer.md` escribiendo `ToString()` por costumbre, no por regla declarada.
- El principio de punto unico de conversion por aggregate cubre por igual identidad simple y clave compuesta sin necesitar una lista exhaustiva de formatos permitidos -- tolera cualquier estructura de clave natural futura.
- La politica del borde HTTP (normalizacion por tipado, nunca clave armada como string) cierra la superficie de entrada mas expuesta con el mismo mecanismo que el marco ya usa para validar (route constraints/model binding), sin inventar una capa nueva.
- La afirmacion de sensibilidad a mayusculas de PostgreSQL queda citada contra su documentacion oficial, no memorizada -- cualquier agente que necesite explicar por que un id con casing distinto "desaparece" en silencio tiene ahora una fuente que lo respalda.
- Deja nombrado, no asumido, el guardrail real (doctrina en #501/#502 + chequeo del reviewer en #503) -- evita que este ADR se lea como resuelto cuando la propagacion todavia esta pendiente.

### Negativas

- **Sin enforcement de tipo**: nada en el sistema de tipos de C# impide que un desarrollador o un futuro agente rompa el punto unico de conversion -- el guardrail depende integramente de doctrina y revision (#501/#502/#503), no de un compilador que rechace el error. Es el mismo trade-off que MEF-ADR-0018 acepta explicitamente al descartar la extraccion prematura.
- **Tres issues de propagacion pendientes** (#501, #502, #503): este ADR fija la doctrina, pero mientras esos tres no aterricen, ningun agente del marco la aplica automaticamente -- el riesgo de "Contexto" sigue latente hasta que la cadena se cierre.
- **El comportamiento de Marten bajo una collation case-insensitive queda no verificado** (seccion CA-4): si un consumidor futuro configura una collation no-deterministica a nivel de base, este ADR no cubre ese escenario y necesitaria revisarse.

## Referencias

- **[1]** "Guid.ToString Method" -- Microsoft Learn, .NET API docs: *"The value of this Guid, formatted by using the 'D' format specifier ... where the value of the GUID is represented as a series of lowercase hexadecimal digits in groups of 8, 4, 4, 4, and 12 digits and separated by hyphens. An example of a return value is '382c74c3-721d-4f34-80e5-57657b6cbc27'"*. Confirma que `ToString()` sin argumentos equivale a `ToString("D")`, siempre en minusculas. https://learn.microsoft.com/dotnet/api/system.guid.tostring
- **[2]** "Pattern Matching" -- PostgreSQL documentation, seccion `LIKE`/`ILIKE`: *"The key word ILIKE can be used instead of LIKE to make the match case-insensitive according to the active locale. [...] This is not in the SQL standard but is a PostgreSQL extension."* Confirma que la comparacion de texto por defecto (incluida la igualdad `=`, que no ofrece ninguna variante insensible equivalente a `ILIKE`) es sensible a mayusculas salvo que se use explicitamente `ILIKE` o una collation no-deterministica. https://www.postgresql.org/docs/current/functions-matching.html
- MEF-ADR-0012 (frontera de serializacion event store vs bus): vecino, no solapado -- gobierna la forma de objetos ricos con campos privados, no el formato de una clave primitiva que nunca es un tipo rico en las superficies de este ADR.
- MEF-ADR-0018 (heuristicas de evolucion y reuso -- Rule of Three): fundamenta el descarte del helper de runtime (Alt 1, CA-5).
- MEF-ADR-0026 (colas de Service Bus con sesion para fan-in): fija `GroupId` = `SessionId` = clave del aggregate destino como invariante dura del productor -- superficie de bus de la seccion 3.
- MEF-ADR-0030 (esquema de identificacion de ADRs): fija el numero `MEF-ADR-0037` (el ultimo existente antes de este ADR era `MEF-ADR-0036`).
- MEF-ADR-0034 (worker de proyecciones y read models), seccion 6 y referencia [19]: decompilacion propia que verifica `Events.StreamIdentity = StreamIdentity.AsString` como valor fijado por `Cosmos.EventSourcing.CritterStack` -- el hecho habilitante de este ADR.
- MEF-ADR-0035 (doctrina de proyeccion y query read-side), seccion 4 y enmienda del issue #493: `session.LoadAsync<TView>(id)` como via canonica de lectura; el ejemplo N1 corregido (`Create(IEvent<TurnoCreado> e) => new(e.StreamKey!, ...)`) confirma que el read-side consume el `StreamKey` ya resuelto por Marten, no una reconstruccion propia.
- MEF-ADR-0036 (identidad del evento persistido en el event store): par simetrico -- deslinde explicito en la seccion 3 de este ADR.
- `agents/implementer.md`: ejemplos vigentes de `ToString()` sin argumentos (`e.TurnoId.ToString()`, `comando.TurnoId.ToString()`) y del patron `ComputarStreamId` para stream ID compuesto, que este ADR eleva de costumbre a regla.
- `agents/test-writer.md`: ejemplo vigente de clave compuesta `$"{empleadoId}:{fecha:yyyy-MM-dd}"`, referenciado en la seccion 1 como precedente del principio de punto unico y formato fijo por componente.
- Issues #501 (doctrina write-side en `agents/implementer.md`), #502 (doctrina read-side en la skill `projections`/`projection-implementer`) y #503 (chequeos del reviewer): propagacion de este ADR, nombrados como el guardrail real en la seccion 5.

## Control de cambios

- 2026-08-04: creacion como `aceptado` (issue #499). Fija las dos clases de identidad de stream (nacida `Guid` / clave natural compuesta) y el principio de punto unico de conversion por aggregate, con el canonico "D" minusculas via `Guid.ToString()` sin argumentos (verificado contra la documentacion oficial de .NET); la politica de normalizacion por tipado en el borde HTTP (nunca recibir la clave armada como `string`); las tres superficies afectadas con sus cross-referencias (store: `StartStream`/`ExistsAsync`/`GetAggregateRootAsync`; bus: `PublishOptions.GroupId` = `SessionId`, MEF-ADR-0026; read-side: `LoadAsync<TView>(id)`, MEF-ADR-0034/MEF-ADR-0035) y el deslinde explicito frente a MEF-ADR-0036 (identidad del tipo de evento persistido, no del stream) y MEF-ADR-0012 (frontera de serializacion de objetos ricos, no de una clave primitiva); la afirmacion de sensibilidad a mayusculas de PostgreSQL verificada contra su documentacion oficial (`ILIKE` como unica via insensible, extension no estandar); y el descarte explicito de un helper de runtime (MEF-ADR-0018, Rule of Three) a favor del guardrail real -- doctrina en los agentes (#501/#502) mas chequeo del reviewer (#503).
