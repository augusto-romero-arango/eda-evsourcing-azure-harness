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
| `## Necesidad de lectura` | No aplica | No aplica | No aplica | No aplica | **Critico** |
| `## Endpoints / rutas` | No aplica | No aplica | No aplica | No aplica | **Critico** |
| `## Criterios de aceptacion` | **Critico** | **Critico** | **Critico** | **Critico** | **Critico** |
| `## Notas tecnicas` | Recomendado | Recomendado | Recomendado | Recomendado | Recomendado |
| `## Capas de test esperadas` | No aplica | No aplica | No aplica | No aplica | Obligatorio |
| `## Impacto en archivos` | Recomendado | Obligatorio | Obligatorio | Recomendado | Recomendado |
| `## Ambiente` | No aplica | No aplica | Obligatorio | No aplica | No aplica |

**Nota sobre bugs**: un issue con label `bug` siempre lleva un `tipo:` valido (`feature`, `refactor`, `tooling`, `infra` o `projection`). Los criterios DoR se aplican segun ese `tipo:`, no segun el label `bug`. Si el bug involucra comportamiento del aggregate, el `## Modelo de eventos` es obligatorio (esto aplica cuando el tipo es `feature`).

**Nota sobre `projection`**: este tipo cubre issues de lectura/consulta (proyecciones Marten y sus Functions GET) que el `planner` reconoce en la seccion "Necesidades de lectura y proyecciones" de `agents/planner.md` y emite con el "Template para issues de proyeccion" (bajo `## Crear issues` del mismo agente). No reutiliza `## Modelo de eventos` porque un issue `projection` no cambia el estado de ningun aggregate: los eventos que consume **ya existen**, producidos por un issue `feature` previo. Los agentes que consumen este tipo (`projection-test-writer`/`projection-implementer`) y la doctrina completa (arbol de decision N1/N2/N3, estilo canonico, read APIs) viven en el Skill `projections` (MEF-ADR-0035, MEF-ADR-0034, MEF-ADR-0006).

Los issues con label `bug` aplican los criterios de la columna correspondiente a su `tipo:`.

### Por que cada campo critico

- **Modelo de eventos**: input directo del `test-writer` para nombrar comandos, eventos y aggregates. Sin el, el agente inventa nombres que divergen del lenguaje ubicuo descubierto en el knowledge crunching.

- **Criterios de aceptacion**: el `test-writer` crea al menos un test por criterio. El `reviewer` valida cobertura con tabla `Criterio | Estado | Test(s)`. Sin CAs, ambos agentes trabajan a ciegas.

- **Label `dom:X`**: el skill `/implement` usa este label para detectar si el dominio necesita scaffold (proyecto .NET, tests, Terraform, GitHub Actions). Sin el, no puede verificar si el dominio existe. En `projection` es igual de obligatorio que en `feature`/`refactor`: todo artefacto read-side (`I{Dominio}ProjectionStore`, `ConfiguracionMartenProjections{Dominio}`, la Function GET) vive dentro de un dominio concreto (`agents/planner.md`, seccion "Necesidades de lectura y proyecciones").

- **Necesidad de lectura**: input directo de `projection-test-writer`/`projection-implementer` -- fija la via de consulta ((a) materializada, (b1) aggregate en vivo o (b2) eventos crudos), la vista a materializar (`{Concepto}View`) y sus campos, los eventos que la alimentan, la receta propuesta (N1/N2, con N3 como escape hatch justificado) y el **lifecycle** de la proyeccion (`Async` es el default -- materializada en el worker de proyecciones; `Inline` es una excepcion opt-in del write-side que el issue debe justificar explicitamente, MEF-ADR-0034). Sin ella, el pipeline read-side no puede nombrar el read model, elegir la receta de proyeccion ni saber donde se materializa (MEF-ADR-0035).

- **Endpoints / rutas**: fija que Functions GET expone la vista (`Obtener{Concepto}`/`Listar{Concepto}s`) y su ruta REST, con el naming de MEF-ADR-0006. Tambien es donde el issue debe declarar si verifico colision de nombres con Functions ya existentes en el dominio. Sin ella, el pipeline no sabe que Function componer ni si el nombre ya esta en uso.

- **Capas de test esperadas** (Obligatorio en `projection`): un issue read-side se cubre con tres categorias complementarias, no intercambiables -- unit tests de la proyeccion (`Create`/`Apply`/`ShouldDelete`), config-test del worker (guarda del `partial`, lifecycle `Async`, replica de metadata -- MEF-ADR-0034 seccion 6) y test de composicion de la Function GET (hermano de MEF-ADR-0029). Declararlas en el issue evita que la fase roja cubra solo la proyeccion y deje el registro en el worker o la Function sin verificar.

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
