# MEF-ADR-0011: Definition of Ready por tipo de issue

**Fecha**: 2026-04-04  
**Estado**: Aceptado

---

## Contexto

El pipeline TDD (`/implement`) lanza tres agentes autonomos (test-writer, implementer, reviewer) que consumen el body del issue como unica especificacion. Si el issue llega incompleto — sin modelo de eventos, sin criterios de aceptacion, sin label de dominio — los agentes trabajan a ciegas: el test-writer inventa nombres de comandos y eventos, el reviewer no puede validar cobertura, y el pipeline puede fallar si el dominio ni siquiera tiene proyecto .NET.

Ademas, el planner tiene multiples modos de creacion de issues (explorar, desglosar, refinar, draft) sin un contrato unificado de completitud. Esto permite que issues mal formados lleguen a desarrollo.

---

## Decision

Establecer un **Definition of Ready (DoR)** que define los criterios minimos que un issue debe cumplir antes de poder ser implementado. El DoR se aplica en dos puntos:

1. **Planner** (fuente): el modo `refinar` verifica el checklist antes de cambiar a `estado:listo`. El modo `explorar` solo crea como `estado:listo` si cumple el DoR. El modo `desglosar` crea sub-issues como `estado:borrador` que deben refinarse individualmente.

2. **`/implement`** (defensa en profundidad): valida un subconjunto verificable programaticamente (labels + presencia de secciones en el body) antes de lanzar el pipeline.

### Tabla DoR por tipo de issue

| Seccion | `feature` | `refactor` | `infra` | `tooling` | `projection` |
|---|---|---|---|---|---|
| Titulo: `[verbo infinitivo] [que cosa]` | Obligatorio | Obligatorio | Obligatorio | Obligatorio | Obligatorio |
| Label `tipo:X` | Obligatorio | Obligatorio | Obligatorio | Obligatorio | Obligatorio |
| Label `dom:X` | Obligatorio | Obligatorio | Opcional | Opcional | Obligatorio |
| Label `estado:listo` | Obligatorio | Obligatorio | Obligatorio | Obligatorio | Obligatorio |
| `## Contexto` | Obligatorio | Obligatorio | Obligatorio | Obligatorio | Obligatorio |
| `## Dependencias` | Obligatorio | Obligatorio | Obligatorio | Obligatorio | Obligatorio |
| `## Modelo de eventos` | **Critico** | No aplica | No aplica | No aplica | No aplica |
| `## Contrato HTTP (comando)` | Condicional | Condicional | No aplica | No aplica | No aplica |
| `## Necesidad de lectura` | No aplica | No aplica | No aplica | No aplica | **Critico** |
| `## Endpoints / rutas` | No aplica | No aplica | No aplica | No aplica | **Critico** |
| `## Criterios de aceptacion` | **Critico** | **Critico** | **Critico** | **Critico** | **Critico** |
| `## Notas tecnicas` | Recomendado | Recomendado | Recomendado | Recomendado | Recomendado |
| `## Capas de test esperadas` | No aplica | No aplica | No aplica | No aplica | Obligatorio |
| `## Impacto en archivos` | Recomendado | Obligatorio | Obligatorio | Recomendado | Recomendado |
| `## Ambiente` | No aplica | No aplica | Obligatorio | No aplica | No aplica |

**Nota sobre bugs**: un issue con label `bug` siempre lleva un `tipo:` valido (`feature`, `refactor`, `tooling`, `infra` o `projection`). Los criterios DoR se aplican segun ese `tipo:`, no segun el label `bug`. Si el bug involucra comportamiento del aggregate, el `## Modelo de eventos` es obligatorio (esto aplica cuando el tipo es `feature`).

**Nota sobre `projection`**: este tipo cubre dos clases de issues del read-side, ambas enrutadas al mismo pipeline. (1) Issues de **feature de lectura** (proyecciones Marten y sus Functions GET) que el `planner` reconoce en la seccion "Necesidades de lectura y proyecciones" de `agents/planner.md` y emite con el "Template para issues de proyeccion" (bajo `## Crear issues` del mismo agente). (2) Issues de **configuracion del read-side**: el worker `<RootNamespace>.Projections` en si -- `Program.cs`, `.csproj`, Dockerfile, config-test base, telemetria del worker -- y demas artefactos del continente que MEF-ADR-0034 (seccion 1) fija como "un worker por Bounded Context, no por dominio". Ninguna de las dos clases reutiliza `## Modelo de eventos`: en (1) porque los eventos que consume una proyeccion **ya existen**, producidos por un issue `feature` previo; en (2) porque un issue de configuracion del worker no cambia el estado de ningun aggregate ni consume eventos todavia.

**El `tipo:` correcto para cualquier issue que toque el worker de proyecciones es siempre `tipo:projection`, nunca `tipo:tooling`.** La razon es operativa, no solo semantica: `tipo:projection` enruta a `tdd-pipeline.sh` (`_resolve_from_labels`, issues #371/#372), cuyo Stage 1 **si** puede escribir en `src/`. `tipo:tooling` enruta a `tooling-pipeline.sh`, cuyo prompt de Stage 1 declara una allowlist que excluye `src/` y lo prohibe explicitamente ("`src/` (eso es para /implement, no para /tooling)") -- un issue del worker etiquetado `tipo:tooling` choca contra su propia allowlist aunque sea perfectamente valido (issue #448).

**La columna `projection` de la tabla aplica igual a las dos clases**: la clase (2) no relaja ninguna fila, solo cambia el *contenido* de las secciones criticas. En un issue de configuracion del read-side, `## Necesidad de lectura` declara **que read-side configura** (que dominios, que named stores registra, que proyecciones va a hospedar el worker) en vez de una vista concreta, y `## Endpoints / rutas` declara explicitamente que no expone Functions de query cuando es el caso ("No aplica -- este issue no expone superficie de consulta"). Ambas secciones **siguen siendo obligatorias como encabezado**, porque la validacion programatica de `/implement` (criterio 5, abajo) verifica presencia de `## Necesidad de lectura` en todo `tipo:projection`: un issue del worker que omita el encabezado se bloquea en el gate del DoR, no en la allowlist del pipeline -- exactamente el fallo que esta enmienda evita.

Los agentes que consumen este tipo (`projection-test-writer`/`projection-implementer`) y la doctrina completa (arbol de decision N1/N2/N3, estilo canonico, read APIs) viven en el Skill `projections` (MEF-ADR-0035, MEF-ADR-0034, MEF-ADR-0006).

**Nota sobre el Contrato HTTP de comandos (MEF-ADR-0043)**: la fila `## Contrato HTTP (comando)` es *Condicional* -- pasa a **Critico** cuando el `## Modelo de eventos` del issue declara al menos un comando con trigger HTTP; es *No aplica* si el issue no expone ningun comando via HTTP (una reaccion pura a un evento de ServiceBus, por ejemplo). No exige un encabezado nuevo en el body: basta que, para cada comando HTTP, la descripcion dentro de `## Modelo de eventos` declare el verbo (`POST`/`PUT`/`DELETE`), la ruta REST completa (kebab-case minusculo, MEF-ADR-0043 seccion 3) y el paso del test de precedencia de MEF-ADR-0043 seccion 2 que justifica esa eleccion.

Los issues con label `bug` aplican los criterios de la columna correspondiente a su `tipo:`.

### Por que cada campo critico

- **Modelo de eventos**: input directo del `test-writer` para nombrar comandos, eventos y aggregates. Sin el, el agente inventa nombres que divergen del lenguaje ubicuo descubierto en el knowledge crunching.

- **Contrato HTTP de comandos** (MEF-ADR-0043): input directo del `test-writer`/`implementer` para fijar el verbo HTTP y la ruta REST del endpoint de comando -- sin el, el agente adivina entre POST/PUT/DELETE y el casing de la ruta, exactamente el drift que motivo MEF-ADR-0043 (casing mixto entre dominios, dos estilos de comando conviviendo sin criterio escrito). El reviewer usa el paso del test de precedencia declarado para verificar que el verbo elegido corresponde al comando (p. ej. que un comando que en realidad reemplaza un value object atomico no quedo expuesto como `POST` en vez de `PUT`).

- **Criterios de aceptacion**: el `test-writer` crea al menos un test por criterio. El `reviewer` valida cobertura con tabla `Criterio | Estado | Test(s)`. Sin CAs, ambos agentes trabajan a ciegas.

- **Label `dom:X`**: el skill `/implement` usa este label para detectar si el dominio necesita scaffold (proyecto .NET, tests, Terraform, GitHub Actions). Sin el, no puede verificar si el dominio existe. **Lee todos los labels `dom:` del issue, no solo el primero** (un issue puede declarar varios), y la oferta de scaffold la dispara el **alcance declarado** del issue -- la seccion de impacto en archivos mencionando `src/<Root>.{Dominio}/` -- y no la sola ausencia del directorio: un issue que solo toca el worker, `ReadModels`, los ensamblados de eventos por rol (`PublicEvents`/`PrivateEvents`/`{Dominio}.DomainEvents`, MEF-ADR-0039) o tests no necesita el Function App de ningun dominio. Como esa seccion es solo **Recomendada** en `feature`/`projection`, su ausencia se resuelve continuando sin scaffold (salida segura: si el proyecto hiciera falta, Stage 1 falla de forma ruidosa, preferible a provisionar infraestructura de Azure por una prediccion incierta). En `projection` el label es igual de obligatorio que en `feature`/`refactor`, pero con una distincion que MEF-ADR-0034 (seccion 1) fija y este ADR hereda -- **continente vs contenido**: los artefactos *por dominio* (`I{Dominio}ProjectionStore`, `ConfiguracionMartenProjections{Dominio}`, la Function GET) viven dentro de un dominio concreto y llevan su `dom:` propio (`agents/planner.md`, seccion "Necesidades de lectura y proyecciones"). El **worker que los hospeda** (`Program.cs`, `.csproj`, Dockerfile, config-test) no es de ningun dominio -- es del Bounded Context completo -- y un issue que lo configura se etiqueta con **todos los `dom:` reales** cuyo read-side toca, nunca con un pseudo-dominio inventado para el worker (`dom:read-side`, `dom:bc`, etc.). Esa alternativa se evaluo y se descarto (ver "Control de cambios"): reproduce el mismo bug de deteccion que motiva esta enmienda, porque `/implement` buscaria `src/<Root>.{PseudoDominio}/`, no lo encontraria, y ofreceria scaffoldear un dominio que no debe existir. Precedente que valida el enfoque de multiples `dom:` reales: issue `#253` del consumidor Bitakora.ControlAsistencia, etiquetado `dom:programacion` + `dom:control-horas` porque el issue configura el read-side de ambos.

- **Necesidad de lectura**: input directo de `projection-test-writer`/`projection-implementer` -- fija la via de consulta ((a) materializada, (b1) aggregate en vivo o (b2) eventos crudos), la vista a materializar (el termino acunado del glosario, sin sufijo `View`, MEF-ADR-0041) y sus campos, los eventos que la alimentan, la receta propuesta (N1/N2, con N3 como escape hatch justificado) y el **lifecycle** de la proyeccion (`Async` es el default -- materializada en el worker de proyecciones; `Inline` es una excepcion opt-in del write-side que el issue debe justificar explicitamente, MEF-ADR-0034). Sin ella, el pipeline read-side no puede nombrar el read model, elegir la receta de proyeccion ni saber donde se materializa (MEF-ADR-0035).

- **Endpoints / rutas**: fija que Functions GET expone la vista (`Obtener{Concepto}`/`Listar{Concepto}s`) y su ruta REST, con el naming de MEF-ADR-0006. Tambien es donde el issue debe declarar si verifico colision de nombres con Functions ya existentes en el dominio. Sin ella, el pipeline no sabe que Function componer ni si el nombre ya esta en uso.

- **Capas de test esperadas** (Obligatorio en `projection`): un issue read-side se cubre con tres categorias complementarias, no intercambiables -- unit tests de la proyeccion (`Create`/`Apply`/`ShouldDelete`), config-test del worker (guarda del `partial`, lifecycle `Async`, guarda barata de metadata -- MEF-ADR-0034 seccion 6; la compatibilidad completa write-side/read-side la verifica el reviewer bajo gate, issue #447) y test de composicion de la Function GET (hermano de MEF-ADR-0029). Declararlas en el issue evita que la fase roja cubra solo la proyeccion y deje el registro en el worker o la Function sin verificar.

### Niveles de obligatoriedad

- **Obligatorio**: debe estar presente para que el issue pase a `estado:listo`
- **Critico**: obligatorio + es input directo de un agente del pipeline — su ausencia degrada significativamente la calidad del output
- **Recomendado**: mejora el resultado pero el pipeline funciona sin el
- **Condicional**: obligatorio solo bajo la condicion indicada
- **No aplica**: no tiene sentido para ese tipo de issue

### Validacion en `/implement`

El skill valida programaticamente un subconjunto del DoR antes de lanzar el pipeline:

1. Label `estado:listo` presente
2. Label `tipo:X` presente
3. Label `dom:X` presente (si tipo es `feature`, `refactor` o `projection`)
4. Body contiene `## Criterios de aceptaci` (prefijo, tolera tildes)
5. Body contiene `## Modelo de eventos` (si tipo es `feature`) o `## Necesidad de lectura` (si tipo es `projection`)
6. Si `## Modelo de eventos` declara un comando con trigger HTTP, el body declara para ese comando el verbo HTTP, la ruta y el paso del test de precedencia de MEF-ADR-0043 aplicado (dentro de la propia descripcion del comando, sin encabezado nuevo)

Si falla cualquier criterio, muestra todos los que fallan y sugiere `planner refinar`.

**Nota sobre `projection` y el routing del pipeline**: esta validacion programatica verifica completitud de informacion, **no** disponibilidad del pipeline read-side. El enrutamiento por label ya conoce el tipo (issue #372): el resolver despacha `tipo:projection` a `tdd-pipeline.sh`, que a su vez detecta el label internamente y dispatcha `projection-test-writer`/`projection-implementer` en vez de `test-writer`/`implementer` (issue #371). Un issue `projection` que pasa el DoR y queda `estado:listo` puede lanzarse con `/implement` igual que cualquier otro tipo. La unica particularidad operativa es de paralelismo, no de routing: varios issues `projection` en un mismo lote se serializan siempre entre si porque comparten los archivos del worker de proyecciones del BC (`agents/planner.md`, seccion "oleadas", matriz de conflictos; MEF-ADR-0034).

---

## Consecuencias

### Positivas

- **Issues completos = pipeline exitoso**: los agentes reciben la informacion que necesitan en el primer intento
- **Fuente unica de verdad**: planner y implement referencian este ADR en vez de duplicar criterios
- **Flujo natural**: draft (captura rapida) → desglosar (borradores enriquecidos) → refinar (DoR completo) → implement (validacion + ejecucion)
- **Defensa en profundidad**: issues creados manualmente sin pasar por el planner son atrapados por `/implement`

### Negativas

- **Friccion adicional**: un issue borrador requiere refinamiento antes de poder implementarse
- **Mantenimiento**: si cambian las necesidades de los agentes, hay que actualizar este ADR

### Riesgos mitigados

- Issues sin modelo de eventos que causan naming incorrecto en el codigo
- Issues sin criterios de aceptacion donde el reviewer no puede validar cobertura
- Issues sin label `dom:X` que impiden la deteccion automatica de scaffold de dominio nuevo
- Issues `projection` sin via de consulta, vista o receta declaradas, que dejan a `projection-test-writer`/`projection-implementer` adivinando el read model o la correlacion de streams

## Control de cambios

- 2026-07-26: enmendado (issue #373) para sumar la variante de DoR de `tipo:projection` -- nueva columna en la tabla y las filas `## Necesidad de lectura` (via de consulta, vista a materializar, eventos que la alimentan, receta N1/N2) y `## Endpoints / rutas` como **Criticas**, `## Capas de test esperadas` como Obligatoria, `dom:X` Obligatorio (igual que `feature`/`refactor`, nunca opcional como en `infra`/`tooling`: todo artefacto read-side es por dominio) y `## Modelo de eventos` como No aplica (los eventos que consume una proyeccion ya existen, no los crea el issue). Extiende la validacion programatica de `/implement` (criterios 3 y 5) para cubrir el nuevo tipo, y deja constancia del estado real del routing: el resolver por label todavia no conoce `tipo:projection`, asi que `/implement` aborta el lanzamiento (`no-tipo`) en vez de enrutarlo -- ni a los agentes read-side ni a los write-side -- hasta que cierren los issues #371/#372. El label en si lo provisiona `scripts/setup-github-labels.sh` y lo diagnostica `/onboard` (eje **Tipo** de MEF-ADR-0007).
- 2026-07-26: enmendado (issue #372) para actualizar la nota sobre routing de `tipo:projection`: el resolver de `scripts/_pipeline-common.sh` ya despacha ese tipo a `tdd-pipeline.sh` (que aplica la rama read-side del issue #371), asi que `/implement` deja de abortar con `no-tipo`. `parallel-pipeline.sh` ademas serializa entre si cualquier par de issues `tipo:projection` de un mismo lote (comparten los archivos del worker de proyecciones del BC, MEF-ADR-0034), sin necesitar deteccion de Bounded Context (un repo = un BC, MEF-ADR-0023).
- 2026-07-29: enmendado (issue #448) para corregir dos sintomas de la doctrina de etiquetado del read-side. (1) Redefine la nota sobre `tipo:projection` para cubrir explicitamente, ademas de los issues de feature de lectura, los issues de **configuracion del read-side** (el worker `<RootNamespace>.Projections` en si -- `Program.cs`, `.csproj`, Dockerfile, config-test, telemetria), y deja escrito que el `tipo:` correcto para cualquier issue del worker es siempre `tipo:projection`, nunca `tipo:tooling` (razon operativa: `tipo:projection` enruta a `tdd-pipeline.sh`, que puede escribir en `src/`; `tipo:tooling` enruta a `tooling-pipeline.sh`, cuyo Stage 1 prohibe `src/` explicitamente). (2) Enmienda el razonamiento de la fila `dom:X` para distinguir **continente de contenido** (MEF-ADR-0034 seccion 1): los artefactos por dominio (`I{Dominio}ProjectionStore`, la Function GET) viven en un dominio y llevan su `dom:` propio, pero el worker que los hospeda pertenece al Bounded Context completo y se etiqueta con **todos los `dom:` reales** cuyo read-side configura -- nunca un pseudo-dominio nuevo (`dom:read-side`, `dom:bc`). Esa alternativa se evaluo y se descarto explicitamente: reproduce el mismo bug de deteccion que este issue corrige (buscaria `src/<Root>.{PseudoDominio}/`, no lo encontraria, y ofreceria un scaffold que no debe existir), y suma mantenimiento (`setup-github-labels.sh`, `domainLabels`, doctrina del planner, esta misma tabla) sin resolver ninguno de los tres sintomas originales. Precedente empirico: issue `#253` del consumidor Bitakora.ControlAsistencia, etiquetado `dom:programacion` + `dom:control-horas`, PR #254. Complementa la correccion de dos defectos de deteccion en `commands/implement.md`: lectura de **todos** los labels `dom:` (no solo el primero) y disparo de la oferta de scaffold desde el alcance declarado del issue en `## Impacto en archivos`, no desde la sola ausencia del directorio -- ninguno de los dos cambios (doctrina o codigo) resuelve el problema sin el otro. La enmienda **no relaja ninguna fila de la tabla**: la clase (2) usa la misma columna `projection` y conserva los mismos encabezados, adaptando solo su contenido (`## Necesidad de lectura` declara que read-side configura; `## Endpoints / rutas` declara "No aplica" cuando el issue no expone superficie de consulta), porque el criterio 5 de la validacion programatica verifica presencia de `## Necesidad de lectura` en todo `tipo:projection` y omitirlo bloquearia en el gate del DoR justo a los issues que esta enmienda habilita.
- 2026-08-05: enmendada la nota sobre la fila `dom:X` (issue #543, creacion de MEF-ADR-0039) para reemplazar la mencion de `Contracts` por los ensamblados de eventos por rol (`PublicEvents`/`PrivateEvents`/`{Dominio}.DomainEvents`) que fija esa particion canonica -- `Contracts` muere del canon del marco. Sin cambio en ninguna fila de la tabla DoR ni en el resto de la doctrina de este ADR.
- 2026-08-07: enmendada la fila "Necesidad de lectura" de "Por que cada campo critico" (issue #581, creacion de MEF-ADR-0041). Deja de citar `{Concepto}View`: pide el termino acunado del glosario a secas, sin sufijo `View` (retirado del naming canonico por MEF-ADR-0041). Sin cambio en ninguna fila de la tabla DoR ni en el resto de la doctrina de este ADR.
- 2026-08-14: enmendado (issue #621, creacion de MEF-ADR-0043). Suma la fila `## Contrato HTTP (comando)` a la tabla DoR (*Condicional* en `feature`/`refactor`, *No aplica* en `infra`/`tooling`/`projection`) con su nota: pasa a **Critico** cuando el `## Modelo de eventos` del issue declara al menos un comando con trigger HTTP, exigiendo verbo + ruta + el paso del test de precedencia de MEF-ADR-0043 que se aplico. Suma el bullet correspondiente en "Por que cada campo critico" y el criterio 6 de "Validacion en `/implement`". Como esa validacion vive dentro de este mismo ADR, la enmienda se autopropaga al gate de `/implement` sin tocar `commands/implement.md`.
