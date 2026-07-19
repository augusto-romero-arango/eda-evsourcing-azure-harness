# MEF-ADR-0002: Estrategia de testing para dominios con event sourcing

## Estado

Aceptado

## Contexto

El proyecto adopto event sourcing como modelo de persistencia para los dominios. Los tests
existentes (basados en `CalculadoraTestBase`, patron AAA, helpers como `Turnos.cs` y `Dias.cs`)
fueron disenados para calculos de horas y no aplican a command handlers que emiten eventos y
mutan estado via aggregate roots.

Se necesita una estrategia de testing que:
- Verifique que cada command handler emite los eventos correctos.
- Verifique que cada evento produce el cambio de estado esperado en el aggregate root.
- Cubra escenarios de idempotencia y error (comandos repetidos o en estado invalido).
- Reduzca la duplicacion de codigo entre tests del mismo agregado.

El equipo desarrollo un harness de testing propio (`Cosmos.EventSourcing.Testing.Utilities`)
que provee un DSL estilo BDD (Given/When/Then/And) y un event store en memoria (`TestStore`).
Este harness ya fue validado en el proyecto ControlPlane.

## Decision

### DSL y clases base

Todos los tests de command handlers en dominios con event sourcing heredan de las clases base
del harness:

- `CommandHandlerAsyncTest<TCommand>` para handlers asincronos.
- `CommandHandlerTest<TCommand>` para handlers sincronos.
- Variantes con `TResult` cuando el handler retorna un valor.

El flujo de cada test sigue el patron:

```
Given(eventos previos)  ->  When/WhenAsync(comando)  ->  Then(eventos emitidos)  ->  And(estado del agregado)
```

### Cobertura obligatoria

Cada test DEBE verificar **tanto** los eventos emitidos (`Then`) **como** el estado resultante
del agregado (`And`). Verificar solo eventos o solo estado es insuficiente: los eventos son el
contrato externo y el estado es la verdad interna. Ambos deben ser correctos.

Para cada command handler se deben cubrir:

1. **Camino feliz**: comando valido emite eventos y deja el agregado en el estado correcto.
2. **Todas las ramas de eventos**: si un handler emite distintos eventos segun el estado previo,
   cada rama tiene su test.
3. **Idempotencia o error**: si el comando se ejecuta sobre un estado invalido (ej: repetir un
   comando ya procesado), se verifica que lanza la excepcion correcta.

### Oraculo independiente (no-tautologia)

El valor esperado de toda asercion (`Then`, `And`, `ThenIsPublished*`) DEBE construirse SIEMPRE a
mano como **oraculo independiente**: armado con las primitivas y factories del dominio, y nunca
derivado ejecutando la logica bajo prueba -ni el SUT ni los colaboradores de produccion que esa
logica invoca-.

Un esperado calculado por el mismo codigo que se verifica vuelve el test **tautologico**: si la
logica de produccion tiene un bug, ese bug contamina por igual el valor esperado y el valor actual,
ambos coinciden, y la prueba pasa sin detectar la regresion. El test deja de ser una especificacion
independiente del comportamiento y se convierte en un espejo del codigo bajo prueba: ya no es una
red de seguridad, porque jamas puede fallar por la razon correcta.

- **Antipatron**: `var esperado = ConsolidadorDesgloseHoras.Consolidar(franjas);` para luego
  comparar ese `esperado` contra el desglose que el aggregate produjo con esa misma consolidacion.
  El esperado y el actual recorren el mismo camino de produccion, asi que un error en
  `Consolidar` los afecta a ambos por igual.
- **Patron correcto**: armar el esperado a mano -`new MomentoDelDia(...)`,
  `IntervaloTemporal.Crear(...)`, `new DesgloseHoras(...)`- de modo que represente el resultado
  deseado calculado por una via distinta a la del codigo bajo prueba.

Este principio esta al mismo nivel normativo que la cobertura obligatoria Then + And: ambos son
condiciones estructurales que un test de event sourcing DEBE cumplir para tener valor como red de
seguridad. La cobertura garantiza que se verifican contrato (eventos) y estado; el oraculo
independiente garantiza que esa verificacion no sea circular.

### Organizacion de clases de test

- **Una clase por command handler** cuando los handlers son independientes.
- **Nested classes** cuando multiples handlers operan sobre el mismo aggregate root. La clase
  contenedora expone factory methods estaticos para crear los eventos de precondicion compartidos.

### Reduccion de duplicacion

Despues de escribir todos los tests se aplica una fase de refactoring:

- Factory methods estaticos para eventos de precondicion reutilizados en multiples tests.
- Constantes estaticas para datos de prueba repetidos.
- Clases base intermedias solo cuando 3 o mas clases de test comparten el mismo patron de setup.

### Dependencias externas

Las dependencias de los handlers (distintas del event store y event senders) se reemplazan con
fakes manuales, no con librerias de mocking como NSubstitute. Los fakes son clases concretas
con comportamiento predecible y constantes estaticas para valores de retorno.

### Familia de agentes separada

Los agentes de codificacion para event sourcing (`es-test-writer`, `es-implementer` y
`es-reviewer`) son una familia completamente independiente. Cada agente ES es autosuficiente
y no depende de los agentes del pipeline clasico. Esto permite que la familia ES evolucione
sin interferencia y sin acoplamientos implicitos.

### Stack de dependencias

Los proyectos de tests para dominios ES usan:

- `Cosmos.EventSourcing.Testing.Utilities` (trae transitivamente AwesomeAssertions, xunit v3,
  Cosmos.EventSourcing.Abstractions, Cosmos.EventDriven.Abstractions)
- `xunit.v3.mtp-v2` (runner de xunit v3)

Esto difiere del stack de tests clasico (xunit v2, NSubstitute, coverlet).

## Consecuencias

### Positivas

- **Cobertura estructural**: al exigir Then + And, cada test verifica el contrato de eventos y
  la mutacion de estado, eliminando la clase de bugs donde el evento se emite pero el estado
  no se actualiza (o viceversa).
- **Tests no tautologicos**: al exigir que el esperado sea un oraculo independiente del codigo
  bajo prueba, un bug en la logica de produccion no puede contaminar a la vez el esperado y el
  actual; el test conserva su capacidad de detectar regresiones en lugar de reflejarlas.
- **Legibilidad**: el DSL Given/When/Then/And hace que los tests lean como especificaciones
  del comportamiento del dominio.
- **Independencia**: la familia de agentes separada permite iterar en los lineamientos de ES
  sin riesgo de regresion en los agentes clasicos.
- **Harness validado**: el harness ya fue probado en ControlPlane, reduciendo el riesgo de
  adopcion.

### Negativas

- **Dos familias de agentes**: hay duplicacion conceptual entre las familias. Si se descubre
  una mejora generica (ej: formato de summaries), hay que aplicarla en ambas.
- **Stack de tests diferente**: los dominios ES usan xunit v3 mientras los clasicos usan
  xunit v2. Esto puede generar confusion si un desarrollador trabaja en ambos tipos.
- **Curva de aprendizaje**: el DSL Given/When/Then/And requiere entender el modelo de event
  sourcing (aggregate root, Apply, uncommitted events) para escribir tests efectivos.
