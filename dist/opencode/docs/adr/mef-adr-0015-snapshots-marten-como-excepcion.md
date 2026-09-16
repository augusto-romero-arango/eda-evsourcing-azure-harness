# MEF-ADR-0015: Snapshots de Marten como excepción, no como regla

## Estado

Aceptado

## Contexto

Marten soporta **snapshots** de aggregate como optimización de rendimiento: en lugar de rehidratar un aggregate re-aplicando todos los eventos de su stream, Marten puede guardar periódicamente una foto serializada del estado actual y reconstruir desde la foto más las pocas deltas posteriores. Existen dos estrategias principales:

- `Live`: nunca se persiste el estado; cada `GetAggregateRootAsync` rehidrata aplicando todos los eventos.
- `Inline` / `Async`: Marten guarda snapshots del aggregate automáticamente tras cada (o cada N) eventos aplicados.

La tentación de usar snapshots aparece cada vez que se considera si un aggregate "debería guardar su estado derivado" para evitar recalcularlo. Aparece en el modelado de aggregates ricos (con `DesgloseHoras`, `ControlesDeFranja`, otras proyecciones derivadas) o cuando se piensa en optimizar I/O.

La decisión por defecto hasta hoy en el proyecto ha sido implícita: Marten se usa en modo `Live` (ningún aggregate tiene snapshot activado, ver la ausencia total de configuración `UseAggregateStreaming`, `Inline`, `Async`, o `Snapshot` en `src/`). Pero esa ausencia implícita no es suficiente: durante el refinamiento de issues aparecen discusiones recurrentes de "¿y si guardamos esto en el snapshot?" que consumen tiempo y distraen del modelado real. Además, adoptar snapshots tiene implicaciones arquitectónicas que merecen estar documentadas para que cualquier agente de planificación o implementación las considere antes de proponer su uso.

## Decisión

### Regla general

**Los aggregates del proyecto no usan snapshots**. Cada `GetAggregateRootAsync` rehidrata aplicando todos los eventos del stream desde el inicio (modo `Live` de Marten).

### Snapshots son excepción, nunca default

Activar snapshots para un aggregate específico requiere **todos** los siguientes criterios:

1. **Evidencia en producción de problema de rendimiento**, documentada con mediciones concretas (tiempo de rehidratación, longitud típica del stream, frecuencia de acceso). Sospechas, proyecciones teóricas y "por si acaso" no son causa suficiente.
2. **Autorización explícita del owner del proyecto** antes de implementar. No es una decisión de refactor que un agente o colaborador pueda tomar autónomamente.
3. **ADR específico** que documente el aggregate afectado, la evidencia, la estrategia elegida (`Inline` vs `Async`), el plan de versionado del estado serializado y la estrategia de invalidación ante cambios de algoritmo.

Sin los tres puntos, **ningún aggregate gana snapshot**.

### Estado derivado en aggregates

Cuando un aggregate necesita exponer estado **derivado** (calculado a partir de otros campos, como `DesgloseHoras` que se consolida desde `ControlesDeFranja`), puede hacerlo de dos formas:

- **Campo recalculado en cada `Apply`**: propiedad pública con setter privado, recalculada por un método privado invocado al final de cada handler de evento. Es el patrón establecido (ej: `ControlesDeFranja` en `ControlDiarioAggregateRoot`).
- **Propiedad calculada bajo demanda**: `get` que calcula cada vez que se accede.

Ambas son aceptables. Preferir campo recalculado cuando el mismo valor se lee varias veces en un mismo ciclo (handler + publicación de evento + asserts de test) para evitar recalcular más de una vez. Preferir propiedad calculada cuando el cálculo es barato o la lectura es esporádica.

**Ninguna de las dos formas equivale a activar snapshot.** Ambas son transparentes al mecanismo de persistencia: Marten sigue guardando solo eventos, y el estado derivado se reconstruye aplicando eventos al rehidratar. Si el algoritmo que produce el estado derivado cambia en un deploy futuro, la próxima rehidratación produce el resultado nuevo automáticamente.

## Consecuencias

**Positivas**

- **Contratos estables y rehidratación transparente**: un cambio en la lógica de consolidación (por ejemplo, la compensación cross-franja del desglose de horas) surte efecto en toda la historia sin migración de snapshots ni versionado de estado serializado.
- **Modelado enfocado en comportamiento**: las discusiones de "¿esto va en el snapshot?" quedan canceladas por defecto. Solo se abren cuando hay evidencia de rendimiento — no cuando se está pensando el dominio.
- **Simplicidad operativa**: no hay tablas de snapshots que versionar, ni procesos de regeneración, ni inconsistencias entre snapshot viejo y evento nuevo.
- **Costo cero hasta que se demuestre lo contrario**: no se paga almacenamiento de snapshots ni overhead de serialización hasta que haya un caso real.

**Negativas**

- **Rehidratación lineal con la longitud del stream**: para aggregates de streams muy largos (miles de eventos), el costo de CPU por `GetAggregateRootAsync` crece. Esto es **aceptable** hasta que se evidencie lo contrario en producción — los dominios actuales (asistencia: ~decenas de eventos por día por aggregate) están lejos del umbral problemático.
- **Actuar reactivamente ante rendimiento**: si un día hay un problema real, activar snapshot requiere trabajo (ADR + implementación + coordinación de deploy). Es un trade-off deliberado: preferimos pagar ese costo solo si es necesario, en vez de pagarlo anticipadamente.

**Riesgo aceptado**

- **Un aggregate puntual podría crecer más rápido de lo previsto**: si el crecimiento lleva a latencias problemáticas antes de que se detecte, algunos comandos pueden tardar más de lo aceptable durante un período. Mitigación: telemetría de `App Insights` en los handlers permite detectarlo rápidamente (ver ADR de control de costos de Application Insights del proyecto consumidor). Umbral de alerta propuesto: rehidratación de aggregate > 500ms p95.

## Referencias

- MEF-ADR-0003: Event sourcing con Marten + Wolverine (define el stack; este ADR restringe una capacidad de Marten específicamente).
- ADR de control de costos de App Insights del proyecto consumidor: Control de costos Application Insights (la telemetría que permite detectar el momento en que la excepción se justifique).
- MEF-ADR-0012: Estilo de modelado de objetos de dominio (explica el enfoque de aggregates ricos y cómo exponen estado).
- Patrón de `ControlesDeFranja` en `ControlDiarioAggregateRoot`: campo recalculado al final de cada `Apply` — ejemplo canónico del enfoque recomendado en este ADR.
