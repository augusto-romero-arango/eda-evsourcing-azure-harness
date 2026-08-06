---
fecha: 2026-08-05
hora: 19:55
sesion: mefisto-planner
tema: composicion canonica de ensamblados por rol del evento + demolicion de la capa de modelado EDA
---

## Contexto

El usuario adopto en Bitakora.ControlAsistencia (CA-ADR-0029) una particion de ensamblados de eventos por rol -- `PublicEvents`/`PrivateEvents`/`{Dominio}.DomainEvents` -- tras un refactor fuerte forzado porque el worker de proyecciones no alcanzaba los tipos de evento persistidos. Pidio comparar contra Mefisto y planear la adopcion como composicion canonica. La sesion produjo 13 issues (4 de ellos implementados por el usuario en paralelo a la propia sesion) y, como derivada inesperada, la demolicion completa de la capa de modelado EDA del harness.

## Descubrimientos

- **El hueco estructural de MEF-ADR-0034**: fijaba que las clases de proyeccion viven en el worker y tipan `Create(TEvento)`, pero ningun agente publicado agregaba la `ProjectReference` que da visibilidad de esos tipos. CA-ADR-0028 del consumidor lo habia diagnosticado textualmente ("el ADR del marco asume implicitamente que el worker los alcanza, pero no dice como").
- **Mefisto ya habia absorbido la mecanica de identidad** (MEF-ADR-0036, `IdentidadEventos{Dominio}`, guardrails de alias) pero no la composicion fisica que la habilita limpiamente.
- **La capa de restore del Dockerfile del worker** copia solo 2 csproj antes del `dotnet restore`: la referencia nueva a `DomainEvents` la rompe en build (no staleness) -- y el Dockerfile nunca se reescribe, asi que el patron debe ser generico desde el nacimiento (#552).
- **`coverage_classify_file` clasifica por nombre de carpeta** (`/Eventos/`, `/Entities/`): el layout raiz de `DomainEvents` la dejaba ciega y el gate perdia el 95% de las factories en silencio (#553).
- **Los records planos de bus ya caian bien en la regla DTO** del clasificador (sin cambio de codigo; solo fixture de no-regresion).
- **El camino de backfill de `projection-test-writer`** (seam-stub para dominios pre-worker) tampoco agregaba la `ProjectReference` -- nada de lo que escribe compilaba (#559).
- **`eda-lint.sh` solo lo invocaba `eda-modeler`**; `/eraser-diagram` NO depende de `docs/eda/` (generador generico, sobrevive).
- **El planner escribia ademas de leer** `docs/eda/` (registraba eventos nuevos en catalog.yaml, l.44).
- Con tres islas, las violaciones de composicion son imposibles de compilar: lo que un PR puede hacer es **habilitarlas** tocando csproj -- ese es el angulo correcto de los checks del reviewer (#557).

## Decisiones

1. **Particion por rol incondicional desde el primer scaffold** (ReadModels/Projections siguen opt-in). Greenfield-only; la migracion de ControlPlane la hace el humano.
2. **Contracts muere**; el vocabulario compartido viaja plano dentro del evento; shared kernel = excepcion local Rule of Three.
3. **Tres islas (correccion sobre CA)**: cero referencias entre los tres ensamblados de eventos -- CA tiene `PrivateEvents -> PublicEvents` y `DomainEvents -> ambos` (evidencia: `TurnoDiarioAsignado` embebe `InformacionEmpleado`/`DetalleTurno`), y el marco **diverge documentadamente**: contratos con velocidades de evolucion distintas no se acoplan; payload por rol con duplicacion deliberada; todo mapeo en el Function App. Enforcement futuro por tests de arquitectura (MEF-ADR-0039 seccion 10).
4. **Los precedentes del consumidor que divergen del canon no se citan como plantilla**: las referencias canonicas (`SubFranja`, `TurnoDiarioAsignado`, tests de serializacion) se sustituyen por ejemplos sinteticos autocontenidos exactos a la doctrina (#554/#555/#557/#563).
5. **Demolicion de la capa de modelado EDA**: mueren `eda-modeler`, `event-stormer`, `/show-flow`, `eda-lint.sh` y todo `docs/eda/` derivado (catalog, flows, topics, projections, context-map, aggregates). Razon: documentacion derivada que puede mentir, con fuente de verdad ejecutable (el codigo por rol post-0039 ES el catalogo). MEF-ADR-0010 superseded por MEF-ADR-0040 (#561).
6. **El glosario de lenguaje ubicuo sobrevive** (unica pieza sin fuente ejecutable) bajo **custodia del planner** (chokepoint natural de vocabulario), mudado a **`docs/ddd/ubiquitous-language.yaml`** (es DDD, no EDA) con fallback de lectura a la ruta vieja (#563).
7. **Issue en vuelo no se enmienda**: cuando la decision de tres islas llego con #546 ya en pipeline, se revirtio su body al que el writer leyo y el delta se creo como issue posterior (#550).

## Descartado

- **Migracion asistida de consumidores legados** (ControlPlane): Rule of Three -- un solo migrado manual, un candidato.
- **Grafo encadenado de referencias entre ensamblados** (el de CA-ADR-0029): descartado como Alt 5 de MEF-ADR-0039 por acoplamiento de contratos.
- **Issue K (alinear eda-modeler)**: propuesto y descartado en la misma sesion -- el agente se elimina.
- **Flows como documentacion manual con `/show-flow` de renderizador**: descartado -- YAML decorativo sin dueno ni lint, la misma enfermedad del catalogo.

## Preguntas abiertas

- **Tests de arquitectura** (mandato de MEF-ADR-0039 seccion 10, via #549 CA-4): quien los genera y donde viven en el consumidor -- issue hermano pendiente de detallar.
- Deteccion de comandos existentes por el planner sin catalogo: la convencion `{Comando}Function/` es la fuente, pero el CA-1 de #563 deja al writer fijar el patron exacto.
- Si `docs/ddd/` acumulara mas artefactos DDD en el futuro (un context-map resucitado), habria que decidir su productor -- hoy no hay ninguno.

## Referencias

Issues creados: #543 (MEF-ADR-0039, cerrado), #544 (DomainEvents en scaffold, cerrado), #546 (PublicEvents/PrivateEvents + retiro Contracts, cerrado), #548 (Paso 3b acceso del worker), #549 (enmienda tres islas, cerrado), #550 (delta tres islas en scaffolder), #552 (projections-scaffolder: Dockerfile/workflow/refs), #553 (coverage_classify_file), #554 (implementer), #555 (test-writer + smoke-test-writer), #557 (reviewer), #559 (agentes de proyecciones + Skill), #561 (MEF-ADR-0040 demolicion), #562 (retiro fisico eda-modeler/event-stormer/show-flow/eda-lint), #563 (planner: re-anclaje + glosario).
Batch sugerido para lo abierto: `/mefisto-sequential 548 550 553 554 555 557 561 552 559 562 563`.

## Addendum (misma sesion, 20:15)

- **Drafts creados en el consumidor Bitakora.ControlAsistencia** (bajo instruccion explicita del usuario, excepcion al scope del mefisto-planner): #317 (enmendar CA-ADR-0029 a tres islas con regla de precedencia "gana el marco"), #318 (PrivateEvents sin ref a PublicEvents), #319 (DomainEvents sin refs a bus + inversion de ToDetalle + nota de seguridad de datos: el JSON de payloads anidados no persiste nombres CLR), #320 (tests de arquitectura -- piloto del enforcement de MEF-ADR-0039 seccion 10, referencia futura para generalizarlo en Mefisto).
- **Hallazgo doctrinal nuevo**: la guia de `ToDetalle()` en el VO (implementer l.825, MEF-ADR-0012) es incompatible con tres islas cuando el tipo destino es de bus -- comentario dejado en #554 para que su writer lo resuelva (el VO expone datos; la traduccion entre contratos vive en el Function App).
