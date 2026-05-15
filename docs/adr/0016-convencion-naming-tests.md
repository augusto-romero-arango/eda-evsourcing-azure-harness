# ADR-0016: Convencion de nombres para metodos de test

## Estado

Aceptado

## Contexto

El proyecto venia con dos convenciones de nombrado de tests conviviendo sin documentacion
explicita:

- `Debe[Resultado]_Cuando[Condicion]` — usado mayoritariamente en tests de command
  handlers y endpoints.
- `<Sujeto>_<LoQuePasa>_Cuando<Condicion>` — usado mayoritariamente en tests de value
  objects, entidades y deserializacion.

Conteo al 2026-04-26:

| Patron | Tests |
|---|---|
| `<Sujeto>_<LoQuePasa>_Cuando<Condicion>` | 178 |
| `Debe[Resultado]_Cuando[Condicion]` | 60 |
| Variantes (sin `_Cuando` o sin tres trozos) | ~14 |

Los agentes `test-writer` y `reviewer` prescribian `Debe[Resultado]_Cuando[Condicion]`,
pero la mayoria de la codebase no lo seguia. La review del PR #148 hizo visible la
inconsistencia: el reviewer humano leyo los tests `Desde_...`, `Partir_...` (que siguen
el patron dominante) y los marco como erroneos por no empezar con `Debe_`.

Necesitamos una sola convencion clara que:

- Se aplique a **todos** los tests del proyecto (VOs, entidades, command handlers,
  endpoints, validators, smoke tests).
- Sea coherente con la mayor parte de la codebase actual (minimizar churn).
- Lea como una especificacion del comportamiento bajo prueba.

## Decision

Adoptamos un patron unico: `<Sujeto>_<LoQuePasa>_Cuando<Condicion>`.

### Estructura

```
<Sujeto>_<LoQuePasa>[_Cuando<Condicion>]
```

- **Sujeto**: el metodo, propiedad o concepto bajo prueba. En un test de un value object
  es usualmente el factory o la propiedad invocada (`Crear`, `DuracionEnMinutos`,
  `ResolverA`, `ToString`). En un test de un command handler es el comando o el verbo de
  negocio (`RegistrarMarcacion`, `CrearTurno`).
- **LoQuePasa**: el efecto observable. Puede ser el evento emitido, el valor retornado,
  la excepcion lanzada o el cambio de estado (`EmiteMarcacionRegistrada`,
  `Retorna540`, `LanzaArgumentException`, `ActualizaEstadoAEnPausa`).
- **Cuando<Condicion>** *(opcional)*: el escenario que dispara el comportamiento. Se
  omite cuando el escenario es trivial o cuando el sujeto y `LoQuePasa` ya lo describen
  en su totalidad (ej. `Vacio_TieneRetardoNetoEnCero`).

### Ejemplos por tipo de test

| Tipo de test | Ejemplo |
|---|---|
| Value object — factory | `Crear_LanzaArgumentException_CuandoInicioEsMayorQueFin` |
| Value object — propiedad | `DuracionEnMinutos_Retorna540_CuandoRango8A17` |
| Value object — `ToString()` | `ToString_MuestraOffsetEnFin_CuandoRangoNocturno` |
| Value object — caso trivial | `Vacio_TieneRetardoNetoEnCero` |
| Command handler — emision | `RegistrarMarcacion_EmiteMarcacionRegistrada_CuandoMarcacionEsNueva` |
| Command handler — fallo | `RegistrarMarcacion_EmiteMarcacionFallida_CuandoMarcacionDuplicada` |
| Command handler — orquestacion | `AsignarTurno_LanzaInvalidOperationException_CuandoTurnoNoExiste` |
| Endpoint HTTP | `CrearTurno_Retorna202_CuandoPayloadEsValido` |
| Validator | `Validar_RechazaConErrores_CuandoNombreEstaVacio` |
| Round-trip de serializacion | `RoundTrip_PreservaIgualdad_CuandoOrdinariaSinHijos` |
| Smoke test | `RegistrarMarcacion_PublicaMarcacionRegistrada_CuandoSeInvocaElEndpoint` |

### Sujeto en command handlers

Para command handlers, el `<Sujeto>` es el **nombre del comando** (`RegistrarMarcacion`,
`CrearTurno`), **no** el metodo del handler (`HandleAsync`). El comando expresa el verbo
de negocio bajo prueba; el metodo `HandleAsync` es solo el punto de entrada tecnico.

### Idioma

Los nombres se escriben en espanol siguiendo PascalCase, sin acentos ni caracteres
especiales — alineado con el resto del codigo del proyecto.

## Consecuencias

### Positivas

- Una sola convencion para todo el proyecto, alineada con la mayoria de la codebase.
- Los nombres son descriptivos y se leen como especificaciones.
- Los agentes `test-writer` y `reviewer` aplican una sola regla, sin matices por tipo
  de test.

### Negativas

- 60 tests existentes con patron `Debe[Resultado]_Cuando[Condicion]` quedan fuera de la
  convencion hasta que se migren. Se gestionara via issue de refactor dedicado.
- Los nombres de comando como sujeto pueden ser largos cuando el comando es verboso.
  Mitigacion: se acepta `<Verbo>_<LoQuePasa>` cuando el comando entero seria
  redundante con el aggregate ya implicito.

### Trade-off considerado

`Debe[Resultado]_Cuando[Condicion]` se sentia mas idiomatico en BDD (xUnit + Given/When/Then
ya prefijan el comportamiento). Pero requiere prefijar 178 tests con `Debe...` y rompe la
lectura natural de tests de propiedades (`Debe[QueAlgo]_Cuando[X]` se vuelve forzado para
una propiedad como `DuracionEnMinutos`). El patron sujeto-centrico encaja en ambos casos.
