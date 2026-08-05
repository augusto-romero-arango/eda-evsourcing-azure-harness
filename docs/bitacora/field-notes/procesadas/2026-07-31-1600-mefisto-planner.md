---
fecha: 2026-07-31
hora: 16:00
sesion: mefisto-planner
tema: Refinamiento de #474 (identidad del evento persistido) y corte en tres issues
---

## Contexto

El draft #474 llegaba rico pero con cinco preguntas abiertas y un alcance de ADR + 4 agentes.
Origen: un consumidor (`Bitakora.ControlAsistencia`) movio sus 5 eventos persistidos a
ensamblados nuevos y quedo con un defecto desplegado -- los streams ya escritos ilegibles --,
mitigado a pulso con una purga que nunca se ejecuto mientras el codigo si se desplego.

El giro de la sesion fue revisar el **PR #280 del consumidor**, la implementacion de campo de esa
correccion. Ese PR resolvio tres de las cinco preguntas abiertas y refuto la recomendacion que
este planner venia defendiendo.

## Descubrimientos

**Verificados contra el codigo y los assemblies, no contra memoria:**

- `Cosmos.EventSourcing.CritterStack` 2.1.0 no registra ningun tipo de evento: cero ocurrencias de
  `AddEventType`, `MapEventType`, `AllEventTypes`, `EventGraph` en `lib/net10.0`. El hueco es del
  harness, no del paquete.
- `Marten.dll` 9.12.0 expone `AddEventType`, `AddEventTypes`, `MapEventType`, `EventMappingFor`;
  `AddEventType` viene del transitivo `JasperFx.Events` 2.18.1 (confirmado en `marten.nuspec`).
- **El scaffold no emite ningun punto de acceso a `StoreOptions`.** El write-side llega a Marten via
  `AgregarWolverineParaComandosServerless` + `AgregarMartenEventStore` y ninguno lo expone. El unico
  acceso documentado es `MEF-ADR-0012:296-310`, que apunta a `Program.cs` -- **desalineado con
  MEF-ADR-0029**. En la practica el bloque `ConfigureMarten` nace ad-hoc (`implementer.md:786`).
- **El paquete del marco fija `EventNamingStyle` y el marco no lo declara en ninguna parte.**
  `set_EventNamingStyle` esta presente en el DLL de `Cosmos.EventSourcing.CritterStack` **2.1.0 y
  2.3.1** (verificado en esta sesion por inspeccion de simbolos); el valor `SmarterTypeName` y el
  metodo (`Commands.MartenEventStoreExtensions.AgregarConfiguracionMartenComandos`) vienen de la
  decompilacion registrada en #447. Tres consecuencias que corrigieron la doctrina ya redactada:
  (a) el alias del marco **no** sale del default de Marten (`ClassicTypeName`) sino de
  `SmarterTypeName` -- identicos para tipos top-level no genericos, divergentes para genericos o
  anidados; (b) la proscripcion "no alterar `EventNamingStyle`" estaba mal redactada: el consumidor
  **no lo controla**, asi que se redacta como "no cambiarlo respecto de lo que fija el paquete";
  (c) aparece un modo de falla que ningun ADR nombra -- **subir la version del paquete es un cambio
  potencial de identidad de todo lo ya persistido** --, que es la razon de fondo del gate de #447 CA-1.
- **El marco no tiene marker de evento persistido.** Los unicos markers son `IEvent`,
  `IPrivateEvent`, `IPublicEvent`, todos de bus (`Cosmos.EventDriven.Abstractions`). Un evento de
  event sourcing puro -- la "tercera fila" de `implementer.md:788` -- no implementa nada.

**Del PR #280 del consumidor (evidencia de campo):**

- El predicado que hace innecesario el marker: **los tipos que son parametro de un
  `public void Apply(TEvento)` de un `AggregateRoot` del assembly** -- la firma con la que Marten
  rehidrata. Los eventos de bus quedan fuera *por construccion* (llegan por endpoint, no por
  `Apply`). Sirve como oraculo de test auto-mantenido, sin reflexion en el arranque de produccion.
- **Un guardrail de alias sobre `new StoreOptions()` standalone es decorativo.** Verificado por
  mutacion: inyectar `MapEventType<T>("nombre.viejo")` en el wiring deja verdes los tests
  standalone y solo pone rojo el que resuelve el `IDocumentStore` del contenedor real.
- API real: `IReadOnlyEventStoreOptions.AllKnownEventTypes()` -> `IReadOnlyList<IEventType>` con
  `.EventType`/`.Alias`. `EventGraph.AllEvents()` es **`internal`**; `IEventType` no tiene
  `DocumentType`. Calculo en memoria, sin Postgres.
- `AwesomeAssertions.Contain(IEnumerable<T>)` lanza `ArgumentException` con `expected` vacio --
  relevante porque un dominio recien scaffoldeado tiene la lista vacia.

## Decisiones

1. **Sede: MEF-ADR-0036 nuevo**, no enmienda a MEF-ADR-0005. Razon: el sujeto entero de 0005 es el
   contrato de **bus** (naming, topics, Published Language, V2, envelope) y la identidad en el store
   es otro sujeto con otra audiencia. 0005 solo gana una referencia cruzada.
2. **Default: convencion (`AddEventTypes`), no alias explicito (`MapEventType`).** Refutada la
   recomendacion previa del planner. El argumento que faltaba y que el ADR del campo si tiene: hay
   una **tercera proscripcion** -- no registrar el nombre calificado antiguo -- porque eso
   *invertiria* la tolerancia de Marten y deserializaria las filas viejas al tipo viejo. `MapEventType`
   abre la puerta a ese error.
3. **Forma canonica hibrida**: produccion enumera (lista explicita, sin reflexion en arranque), el
   test deriva por reflexion (auto-mantenido).
4. **Mejora sobre el campo**: una sola guarda que compara los eventos aplicados contra los tipos
   registrados **en el store del contenedor** (no contra la lista de produccion) cubre dos defectos
   con una asercion: el evento ausente de la lista y el `ConfigureMarten` que no aplica. Importa
   porque con lista vacia `AddEventTypes([])` es no-op y el cableado quedaria sin verificar.
5. **Reparto write-side / ciclo de vida forzado por una restriccion**: un dominio recien scaffoldeado
   no tiene eventos, asi que ninguno de los dos guardrails es escribible tal cual en el scaffold (el
   de alias no tiene alias; el derivado con `NotBeEmpty()` quedaria rojo contra
   `domain-scaffolder.md:2748`). El scaffold emite estructura + guarda auto-mantenida; el flujo TDD
   emite el congelamiento de alias.
6. **Corregido en la misma sesion, tras leer #447 reescrito** (el usuario aviso del cambio de tesis).
   La version anterior de esta nota decia "esta doctrina va antes de #447" porque #447 iba a crear la
   biblioteca de dominio compartida. **Ya no**: tras su reescritura solo encarga al reviewer verificar
   la compatibilidad write/read bajo gate, y **descarta explicitamente** abstraer la configuracion.
   No hay refactor prescrito por el marco que MEF-ADR-0036 deba preceder; ninguno bloquea al otro.
   Lo que si hay es **solape con frontera de autoridad**: dos filas de la tabla de #447 CA-2
   (`Events.EventNamingStyle` y los tipos via `AddEventTypes`) y su gate de CA-1 (que ya nombra
   `IdentidadEventos{Dominio}.cs`). MEF-ADR-0036 es la autoridad de la identidad; #447 lo cita.
7. **Read-side fuera de alcance y sin dueno.** El registro en `ConfiguracionMartenProjections{Dominio}`
   no es escribible mientras la lista viva en el assembly del Function App (MEF-ADR-0034 seccion 5), y
   **ningun issue del backlog lo habilita**: la fila "donde viven los tipos de evento que la proyeccion
   declara" era la tercera de la tabla "Que no se hereda" de la version anterior de #447 y
   **desaparecio al reescribirse**. El marco no tiene decidido donde viven esos eventos (`ReadModels`
   es para read models sin Marten; las clases de proyeccion viven en el worker). MEF-ADR-0036 CA-6
   **nombra el hueco** en vez de darlo por resuelto.
8. **Fusion de dos issues por decision del usuario**: los agentes del ciclo de vida
   (implementer/test-writer/reviewer) y el planner van en un solo issue, con eje homogeneo declarado.
9. **Ubicacion sin ambiguedad**: `IdentidadEventos{Dominio}` va en `Infraestructura/` y no en
   `Entities/` (es configuracion que consume su vecino `ComposicionServicios{Dominio}`; `Entities/`
   esta reservado a AggregateRoots y eventos).

## Descartado

- **`MapEventType` como default del marco** (ver decision 2).
- **Introducir un marker `IEventoPersistido`**: innecesario dado el predicado por `Apply`, y
  obligaria a un retrofit en todos los eventos persistidos de todos los consumidores.
- **Copiar literal la enmienda `CA-ADR-0029 decision #6` del consumidor**: depende de su particion
  por ensamblados (`{Dominio}.DomainEvents`), que el marco todavia no tiene. Sirve de borrador.
- **Deteccion automatica del rename** en el reviewer: comparar contra el arbol base no vale la
  fragilidad; el guardrail de alias es la red mecanica.
- **Retro-cablear dominios ya scaffoldeados**: candidato a issue propio de `/onboard`, no se abrio.
- **Un issue por agente** (cuatro issues de un parrafo, tres sin consumidor).
- **Citar #447 como si estuviera eliminando enumeraciones**: su tesis reescrita las **conserva** y
  agrega vigilancia. Se retiro esa frase de #474 tras el aviso del usuario.
- **Abrir un cuarto issue para el retro-cableado de dominios ya scaffoldeados**: el usuario decidio
  no abrirlo. Queda solo como pregunta abierta aqui.

## Preguntas abiertas

- Si la senal de "issue que mueve o renombra un tipo de evento persistido" merece una fila propia en
  MEF-ADR-0011 (DoR) o basta con la seccion nueva del planner. Declarado como "a revisar" en #476.
- Si `services.ConfigureMarten(...)` aplica efectivamente cuando Marten se agrega dentro de
  `AgregarWolverineParaComandosServerless(...)`. Declarado en #475 como riesgo a verificar por
  ejecucion, no por lectura; la guarda del CA-3 es su verificacion pero solo muerde con eventos.
- El retro-cableado de consumidores existentes (dominios ya scaffoldeados no reciben nada de #475).

## Referencias

Issues refinados: **#474** (era draft; ahora `estado:listo`, retitulado a "Crear MEF-ADR-0036 con la
doctrina de identidad del evento persistido en el event store").

Issues creados: **#475** (Emitir el registro de tipos de evento persistidos en el wiring write-side
del scaffold), **#476** (Cablear la doctrina de identidad del evento persistido en el flujo TDD y en
el refinamiento).

Orden de batch validado con `mefisto-validate-batch-deps.sh 474 475 476`: **OK**, el script retiro
el label `bloqueado` de #475 y #476 porque el orden del batch + sync verificado resuelve sus
dependencias.

Fuentes de campo: PR `augusto-romero-arango/Bitakora.ControlAsistencia#280`, issues #237, #268,
#277 del mismo consumidor, y su `docs/adr/ca-adr-0029-ensamblados-de-eventos-por-rol.md`.
Fuente oficial: `JasperFx/marten` `docs/events/versioning.md` (secciones "Namespace Migration" y el
caso de rename) y `src/Marten/Events/EventDocumentStorage.cs:329-352`.
