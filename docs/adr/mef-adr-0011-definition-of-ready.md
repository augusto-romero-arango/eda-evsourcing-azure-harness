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

| Seccion | `feature` | `refactor` | `infra` | `tooling` |
|---|---|---|---|---|
| Titulo: `[verbo infinitivo] [que cosa]` | Obligatorio | Obligatorio | Obligatorio | Obligatorio |
| Label `tipo:X` | Obligatorio | Obligatorio | Obligatorio | Obligatorio |
| Label `dom:X` | Obligatorio | Obligatorio | Opcional | Opcional |
| Label `estado:listo` | Obligatorio | Obligatorio | Obligatorio | Obligatorio |
| `## Contexto` | Obligatorio | Obligatorio | Obligatorio | Obligatorio |
| `## Dependencias` | Obligatorio | Obligatorio | Obligatorio | Obligatorio |
| `## Modelo de eventos` | **Critico** | No aplica | No aplica | No aplica |
| `## Criterios de aceptacion` | **Critico** | **Critico** | **Critico** | **Critico** |
| `## Notas tecnicas` | Recomendado | Recomendado | Recomendado | Recomendado |
| `## Impacto en archivos` | Recomendado | Obligatorio | Obligatorio | Recomendado |
| `## Ambiente` | No aplica | No aplica | Obligatorio | No aplica |

**Nota sobre bugs**: un issue con label `bug` siempre lleva un `tipo:` valido (`feature`, `refactor`, `tooling` o `infra`). Los criterios DoR se aplican segun ese `tipo:`, no segun el label `bug`. Si el bug involucra comportamiento del aggregate, el `## Modelo de eventos` es obligatorio (esto aplica cuando el tipo es `feature`).

Los issues con label `bug` aplican los criterios de la columna correspondiente a su `tipo:`.

### Por que cada campo critico

- **Modelo de eventos**: input directo del `test-writer` para nombrar comandos, eventos y aggregates. Sin el, el agente inventa nombres que divergen del lenguaje ubicuo descubierto en el knowledge crunching.

- **Criterios de aceptacion**: el `test-writer` crea al menos un test por criterio. El `reviewer` valida cobertura con tabla `Criterio | Estado | Test(s)`. Sin CAs, ambos agentes trabajan a ciegas.

- **Label `dom:X`**: el skill `/implement` usa este label para detectar si el dominio necesita scaffold (proyecto .NET, tests, Terraform, GitHub Actions). Sin el, no puede verificar si el dominio existe.

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
3. Label `dom:X` presente (si tipo es `feature` o `refactor`)
4. Body contiene `## Criterios de aceptaci` (prefijo, tolera tildes)
5. Body contiene `## Modelo de eventos` (solo si tipo es `feature`)

Si falla cualquier criterio, muestra todos los que fallan y sugiere `planner refinar`.

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
