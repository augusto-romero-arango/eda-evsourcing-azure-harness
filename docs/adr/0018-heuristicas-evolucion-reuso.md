# ADR-0018: Heuristicas de evolucion y reuso del codigo

## Estado

Aceptado

## Contexto

El proyecto modela reglas del dominio laboral colombiano. Muchas de esas reglas
se parecen entre si pero pueden divergir cuando aparecen matices regulatorios
(topes diferenciados, ventanas temporales, exclusiones por concepto). Sin una
heuristica explicita sobre cuando extraer codigo comun y cuando dejarlo
duplicado, cada conversacion de revision lo discute desde cero y la decision
oscila segun el reviewer del momento.

La laguna se hizo visible al refinar #136 y #116. Ambos issues implementan el
mismo algoritmo --"consumir los ultimos N minutos de una lista de intervalos
extras, usando `IntervaloTemporal.Partir(int)` cuando un intervalo se atraviesa
parcialmente"-- uno para compensacion intra-franja y otro para compensacion
cross-franja. La decision tomada al refinarlos fue **mantener duplicado** hasta
evidenciar que ambos sitios evolucionan igual, porque el dominio laboral
colombiano puede introducir reglas distintas que harian forzada una API
unificada. Ese razonamiento quedo cargado en las notas tecnicas de cada issue,
pero no como heuristica del proyecto.

ADR-0012 abrio el patron de "ADR como tabla de heuristicas con disclaimer de
heuristicas vs principios". Este ADR replica el patron en un eje ortogonal: la
evolucion y el reuso del codigo.

## Decision

### Disclaimer

Estas son heuristicas, no principios absolutos. En desarrollo de software nada
es blanco o negro. El criterio especifico de cada caso puede ajustarse durante
la conversacion de diseno (planner, test-writer, implementer, reviewer). Lo que
aqui se define es el **punto de partida** -- la decision por defecto cuando
nadie aporta argumento explicito en contra. Cualquier desviacion es legitima si
queda argumentada en la conversacion del issue, del PR o de un nuevo ADR.

### Tabla de heuristicas

| Heuristica | Regla operativa |
|---|---|
| **Rule of Three** | Tolerar duplicacion hasta la tercera repeticion. Con dos sitios, la duplicacion se mantiene; recien al tercer caso vale la pena evaluar si la abstraccion es estable y aporta. La extraccion prematura crea acoplamiento dificil de revertir si los sitios divergen. |
| **Riesgo de divergencia del dominio** | No extraer cuando los sitios pueden divergir por reglas del dominio que aun no se han manifestado. Si la legislacion laboral colombiana puede introducir matices distintos para cada caso (topes, ventanas, exclusiones), encerrar el algoritmo en una API comun fuerza un contrato que se sentira artificial cuando aparezcan los matices. Mantener duplicado preserva la libertad de divergir sin refactor. |
| **Autoridad de extraccion** | El reviewer no debe pedir extraccion si el implementer no la ofrece, salvo evidencia documentada de evolucion conjunta de los sitios. La iniciativa parte del implementer (que conoce la forma actual del codigo); el reviewer juzga la propuesta, no la origina. La excepcion es cuando un cambio reciente toco simultaneamente los dos sitios y los dejo identicos -- ese es el momento natural para proponer la extraccion en el mismo PR. |
| **Costo de la duplicacion estable** | Aceptar el costo de mantener codigo duplicado mientras la duplicacion sea estable y mecanica. Si los sitios cambian en sincronia un par de veces sin diverger, la duplicacion deja de ser estable y entra en el camino de la extraccion (aplicando Rule of Three al tercer caso). |

### Ejemplo concreto del proyecto

`#136` (compensacion intra-franja) y `#116` (compensacion cross-franja)
implementan el mismo algoritmo de consumir los ultimos N minutos de una lista
de intervalos extras, particionando con `IntervaloTemporal.Partir(int)` cuando
un intervalo se atraviesa parcialmente.

Decision aplicada: mantener duplicado. La compensacion intra-franja y la
cross-franja **pueden divergir** si la regulacion introduce reglas
diferenciadas (ej. tope distinto para extras intra vs cross, ventana temporal
para compensacion cross-franja, exclusion de ciertos conceptos solo en una
direccion). Mientras eso no ocurra, el reviewer no pide extraccion y el
implementer no la ofrece. Si en el futuro un issue concreto demuestra que
ambos algoritmos siguen identicos tras varias evoluciones, ese issue propone
la extraccion con el caso documentado.

### Lo que esta heuristica NO regula

- **Tools de deteccion** (linters, analisis de duplicacion). Este ADR es sobre
  criterio de diseno, no sobre automatizacion.
- **Naming, estructura de carpetas u otros ejes de evolucion**. Si esas
  heuristicas crecen, merecen su propio ADR (igual que ADR-0012 se mantuvo
  focalizado en modelado de objetos).
- **Reuso de utilidades sin riesgo de divergencia** (helpers de fechas,
  formatters, etc.). La heuristica aplica cuando el codigo expresa **reglas del
  dominio** que pueden divergir, no cuando expresa mecanica neutral.

## Consecuencias

**Positivas**

- Las conversaciones sobre extraccion vs duplicacion tienen ancla compartida en
  vez de reabrirse desde cero en cada PR.
- Se preserva la libertad de divergir reglas del dominio sin pagar deuda de
  refactor por una abstraccion prematura.
- El reviewer y el implementer reciben criterios claros de quien propone la
  extraccion y bajo que evidencia, eliminando el ping-pong silencioso.
- El proyecto reconoce explicitamente que la duplicacion estable tiene un costo
  aceptable, no un anti-patron a perseguir siempre.

**Negativas**

- Se acepta cierto costo de mantenimiento del codigo duplicado (cambios deben
  replicarse en los sitios identicos hasta que se demuestre divergencia).
- El criterio "el implementer ofrece, el reviewer juzga" puede dejar pasar
  duplicaciones extraibles si nadie las nota; el costo se paga en cambios
  futuros, no de forma inmediata.
- La Rule of Three no es mecanica: el tercer caso puede aparecer mucho despues
  y los sitios anteriores podrian haber acumulado diferencias sutiles; la
  evaluacion al tercer caso requiere atencion explicita, no solo conteo.

## Referencias

- ADR-0012 (Heuristicas de modelado de objetos de dominio) -- precedente del
  formato y del disclaimer de heuristicas vs principios.
- Issue #136 (Calcular retardo, compensacion intra-franja y ensamblar
  DesgloseFranja) -- caso ejemplificador, sitio 1.
- Issue #116 (Consolidar DesgloseFranjas del dia con compensacion cronologica
  inversa) -- caso ejemplificador, sitio 2.
- Field note `docs/bitacora/field-notes/2026-04-26-1355-planner.md` -- sesion
  donde se decidio elevar la heuristica a ADR.
- Martin Fowler, "Refactoring" -- origen popular de la "Rule of Three".
