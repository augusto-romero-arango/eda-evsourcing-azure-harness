# MEF-ADR-0008: Knowledge Crunching como proposito del agente planner

**Fecha**: 2026-04-02
**Estado**: Aceptado

---

## Contexto

El proyecto usa event sourcing con aggregates con comportamiento (MEF-ADR-0003). Los agentes de codificacion (`es-test-writer`, `es-implementer`) necesitan informacion precisa sobre comandos, eventos, aggregates y triggers para producir codigo correcto. Sin esa informacion en el issue, los agentes tienen que inferirla del texto libre, lo que produce resultados menos predecibles.

El agente `planner` ya hacia planificacion y creacion de issues, pero no tenia como objetivo explicito la destilacion del conocimiento del dominio. Esto dejaba un gap: el usuario describia necesidades en lenguaje natural ("quiero registrar cuando un empleado llega"), y la traduccion a vocabulario tecnico del dominio (comando `RegistrarMarcacion`, evento `MarcacionRegistrada`, aggregate `DiaOperativoAggregateRoot`) quedaba como responsabilidad implicita de los agentes de codificacion.

Eric Evans describe en Domain-Driven Design el concepto de **Knowledge Crunching**: el proceso iterativo de conversar con expertos del dominio para descubrir el modelo subyacente, nombrar conceptos con precision, y refinar el lenguaje ubicuo del sistema. En nuestro contexto, ese proceso ocurre en la conversacion entre el usuario y el planner.

---

## Decision

### El planner es el agente de Knowledge Crunching

Su proposito principal ya no es solo "crear issues". Es descubrir el modelo del dominio a traves de conversaciones y cristalizar ese conocimiento en issues que los agentes de codificacion puedan consumir sin ambiguedad.

### Los eventos son ciudadanos de primera clase

En un sistema event-sourced, cada feature es un flujo: un comando produce eventos que cambian un aggregate y potencialmente notifican a otros dominios. El planner guia la conversacion hacia esa estructura:

1. **Que accion inicia esto?** → el comando
2. **Que pasa cuando sale bien?** → evento de exito
3. **Que puede salir mal?** → eventos de fallo
4. **Quien cambia de estado?** → aggregate root
5. **A quien mas le importa?** → consumidores cross-domain
6. **Como se dispara?** → HTTP o ServiceBus

### Los issues incluyen "Modelo de eventos"

Una seccion nueva en el body del issue captura el resultado del Knowledge Crunching:

```markdown
## Modelo de eventos
- **Comando**: `RegistrarMarcacion` (trigger: HTTP)
  - Payload: `EmpleadoId (Guid)`, `Timestamp (DateTimeOffset)`, `Tipo (EntradaSalida)`
- **Aggregate**: `DiaOperativoAggregateRoot`
  - Estado que cambia: `Marcaciones`, `UltimaMarcacion`
- **Eventos de exito**: `MarcacionRegistrada` - EmpleadoId, Timestamp, Tipo
- **Eventos de fallo**: `RegistroMarcacionFallido` - empleado sin turno asignado
- **Consumidores**: CalculoHoras escucha via topic `eventos-asistencia`
```

Esta seccion es el input directo para:
- `es-test-writer`: nombra correctamente commands, eventos, aggregate; escribe los `Given/When/Then`
- `es-implementer`: sabe que propiedades implementar en el aggregate, que tipo de trigger usar, si necesita infraestructura Service Bus
- `es-reviewer`: verifica que la implementacion refleje el modelo acordado

### El Knowledge Crunching es iterativo

No se espera que el usuario llegue con el modelo completo. El modo `explorar` del planner esta disenado para guiar la conversacion gradualmente: empieza con una idea vaga, hace preguntas, lee codigo existente, y termina con un modelo de eventos que el usuario valida antes de crear el issue.

---

## Alternativas consideradas

**Dejar la traduccion a los agentes de codificacion**: descartado. Los agentes ES pueden inferir nombres del texto libre, pero el resultado es menos predecible. Un nombre mal inferido (`RegistroDeEntrada` vs `MarcacionRegistrada`) se propaga a tests, handlers y eventos, creando inconsistencia con el lenguaje ubicuo.

**Modelo de eventos en archivo YAML separado (eda-modeler)**: complementario, no alternativo. El `eda-modeler` crea flujos cross-domain completos en `docs/eda/flows/`. El modelo de eventos del issue es mas compacto y especifico a una tarea. Ambos se alimentan mutuamente.

---

## Consecuencias

- El planner es mas lento deliberadamente. Hace mas preguntas antes de crear un issue. Esto es una inversion: issues mejor definidos producen codigo mas correcto en el primer ciclo del pipeline.
- El vocabulario del dominio se estabiliza mas rapido. Cada sesion de Knowledge Crunching fija nombres de comandos, eventos y aggregates que se reusan en issues posteriores.
- La seccion "Modelo de eventos" puede omitirse para issues que no tocan comportamiento de dominio (refactor, tooling, infra pura). No es obligatoria universalmente.
- Los agentes de codificacion se benefician sin modificaciones. El modelo de eventos llega como parte del body que ya reciben. Solo es texto mas estructurado y preciso.
