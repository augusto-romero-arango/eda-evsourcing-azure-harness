# MEF-ADR-0052: Decision multi-runtime sobre navegacion semantica en agentes C#

- **Fecha**: 2026-09-07
- **Estado**: aceptado
- **Aplica a**: doctrina de navegacion semantica (LSP) en los agentes publicados que trabajan sobre C# (`planner`, `implementer`, `projection-implementer`, `reviewer`), en ambos runtimes soportados hoy (Claude Code, OpenCode). Sintetiza la evidencia de #979 (piloto Claude Code) y #980 (piloto OpenCode) sobre el protocolo fijado por #976 (`docs/testing/lsp-experiment-protocol.md`). Cross-referencia MEF-ADR-0050 (neutralidad de toda operacion: la capacidad se expresaria como intencion neutral si se adoptara), MEF-ADR-0049 (arquitectura neutral de runtime: precedente de mapeos por runtime sin confundirlo con soporte publicado disponible), MEF-ADR-0019 (publicado vs interno: identifica que lado consumiria cada follow-up) y MEF-ADR-0030 (esquema de identificacion, fija el numero `0052` como libre).

**Issues bloqueados por este ADR**: ninguno. Este ADR no ejecuta adopcion; los follow-ups de la seccion "Decision, punto 5" quedan como candidatos para issues futuros que declaren su dependencia de `MEF-ADR-0052`, no como trabajo que este documento reserve o bloquee.

## Contexto

#976 fijo un protocolo A/B (`docs/testing/lsp-experiment-protocol.md`) para medir si la navegacion semantica (LSP) reduce tokens/tiempo o mejora calidad frente a busqueda textual, en los tres roles con oraculo independiente (`planner` / analisis de impacto, `implementer` / cambio sobre test rojo, `reviewer` / revision de diff transversal), sobre el mismo SHA congelado del consumidor `Bitakora.ControlAsistencia`. El protocolo declara explicitamente que **solo son validos los deltas texto-vs-LSP dentro del mismo runtime**: Claude Code y OpenCode exponen servidor, tool schema, wire format y mecanismo de activacion distintos, y una mejora en uno no autoriza generalizar al otro. #978 retiro antes la dependencia del MCP de Rider de los agentes publicados, asi que el baseline textual de ambos pilotos ya no lo usa.

#979 (piloto Claude Code) y #980 (piloto OpenCode) ejecutan ese protocolo cada uno sobre su propio mecanismo:

- **Claude Code**: plugin oficial `csharp-lsp` 1.0.0 del marketplace `anthropics/claude-plugins-official`, respaldado por el binario `csharp-ls`.
- **OpenCode**: servidor C# nativo (requiere .NET SDK), habilitado solo con `OPENCODE_EXPERIMENTAL_LSP_TOOL=true` (o el flag experimental global) y permiso `lsp: allow` -- tres gates independientes.

Este issue (#981) **sintetiza** esa evidencia; no ejecuta ningun par adicional ni cambia doctrina de agente por su cuenta.

### Resultado de #979 (piloto Claude Code)

`docs/testing/lsp-pilot-claude.md` concluye **NO EVALUABLE** para los tres roles del corpus. El preflight se ejecuto completo (los cuatro gates que fija el protocolo) y se detuvo en el primer gate en rojo:

| Gate | Resultado |
|---|---|
| 1. Binario `csharp-ls` presente | falla (`which csharp-ls` -> no encontrado) |
| 2. Plugin `csharp-lsp` instalado y habilitado | falla (`claude plugin list` no lo muestra; solo `azure@claude-plugins-official`, deshabilitado) |
| 3. Tool `LSP` disponible en una consulta de control dentro de `claude -p` headless | falla (dos consultas de control, formulaciones distintas, ambas confirman ausencia) |
| 4. Frescura tras una edicion | no alcanzado (depende del gate 3) |

Consecuencia: **cero pares corridos** en los tres roles -- ni siquiera el brazo texto se ejecuto de forma aislada, porque el protocolo no acepta pares incompletos. El reporte distingue explicitamente que el bloqueo es de **entorno** (plugin/binario no instalados en la maquina donde corre el stage headless), no de **mecanismo**: el plugin existe, esta versionado (`1.0.0`) y documentado por el marketplace oficial. Instalarlo fue evaluado y descartado por el propio piloto -- cambia configuracion de plugins a nivel usuario/maquina, fuera del alcance de una etapa headless sin turno humano que confirme un cambio de entorno compartido.

### Resultado de #980 (piloto OpenCode)

A la fecha de este ADR (2026-09-07), **el issue #980 sigue abierto (`estado:listo`, sin PR)**. No existe `docs/testing/lsp-pilot-opencode.md` en el repo. Esto **no es equivalente** al `no evaluable` de #979: en #979 el preflight se ejecuto y fallo en un gate observado empiricamente; en #980 **la ejecucion misma nunca comenzo** -- no hay preflight de servidor C#/feature-flag/permiso corrido, no hay consultas de control, no hay ninguna fila de evidencia, ni siquiera un intento fallido de par.

Este ADR registra ese estado con la misma transparencia que exige CA-1: no oculta que una de las dos dependencias declaradas (#980) no aporto evidencia, y no fabrica ni infiere un resultado en su lugar.

## Decision

### 1. Tabla por runtime y rol (CA-1)

Ninguna celda compara cifras absolutas entre runtimes -- ninguna de las seis combinaciones alcanzo siquiera un par valido, asi que no hay cifra que comparar en ningun sentido:

| Runtime | Rol | Preflight ejecutado | Pares corridos | Resultado del piloto |
|---|---|---|---|---|
| Claude Code | `planner` | si (4 gates, falla en gate 3) | 0/3 | `no evaluable` |
| Claude Code | `implementer` | si (4 gates, falla en gate 3) | 0/3 | `no evaluable` |
| Claude Code | `reviewer` | si (4 gates, falla en gate 3) | 0/3 | `no evaluable` |
| OpenCode | `planner` | no (piloto #980 no ejecutado) | 0/3 | `no evaluable` (piloto pendiente) |
| OpenCode | `implementer` | no (piloto #980 no ejecutado) | 0/3 | `no evaluable` (piloto pendiente) |
| OpenCode | `reviewer` | no (piloto #980 no ejecutado) | 0/3 | `no evaluable` (piloto pendiente) |

Roles fuera del corpus de #976 (`test-writer`, `smoke-test-writer`, `projection-test-writer`, `projections-scaffolder`, `projection-implementer` en su rol read-side) no figuran en la tabla: no fueron probados en ningun runtime y este ADR no les asigna fila ni conclusion (ver punto 4).

### 2. Decision explicita por combinacion, con umbrales y tradeoffs (CA-2)

Para las **seis** combinaciones runtime x rol de la tabla, la decision es **evidencia insuficiente**. Aplicando el criterio de dos pasos predeclarado por #976:

1. **No inferioridad de calidad** (obligatorio primero): no evaluable en las seis combinaciones -- exige que el brazo LSP pase el mismo oraculo que el brazo texto en 3 repeticiones, y cero repeticiones del brazo LSP corrieron en ningun runtime. Ninguna combinacion queda "rechazada por calidad": eso exigiria haber observado al brazo LSP fallar el oraculo, y no se lo observo en absoluto en ningun caso.
2. **Beneficio neto** (medianas de tokens de input y wall-clock, umbrales -10%/-15%): no se evalua en ninguna combinacion, por la misma regla explicita de #976 -- sin tres repeticiones validas por brazo no se calcula ninguna mediana, ni se sustituye con datos de otro runtime.

Tradeoffs de tokens, tiempo y calidad quedan **sin medir** en las seis combinaciones -- no hay una sola fila de evidencia cuantitativa que reportar. Los dos ejes que si dejan senal, de madurez experimental e indexacion, son cualitativamente distintos entre runtimes y no se promedian entre si:

- **Claude Code**: el bloqueador es de **entorno**, no de mecanismo. El plugin `csharp-lsp` es oficial, versionado (`1.0.0`) y depende de una instalacion externa a nivel de usuario/maquina (binario `csharp-ls` + `claude plugin install`) que ningun stage headless del pipeline publicado ejecuta hoy por su cuenta. Dos reportes abiertos del tracker de terceros (`anthropics/claude-code#84125`, `#79744`) senalan riesgo adicional de poda de la tool en subagentes y de desincronizacion tras editar en modo interactivo -- ninguno de los dos se llego a verificar aqui porque el gate 3 fallo antes.
- **OpenCode**: el bloqueador es de **ejecucion del piloto**, no de mecanismo ni de entorno conocido -- no hay ningun dato, ni siquiera negativo, sobre si los tres gates (servidor C#, feature flag, permiso) pasarian en el entorno del pipeline. La propia documentacion oficial de OpenCode (citada por #976/#980) advierte que LSP "no siempre es beneficio neto", y el mecanismo exige tres gates independientes en vez de uno, una superficie de fallo mayor que la de Claude Code -- una senal de madurez experimental a favor de no asumir disponibilidad, no una conclusion sobre resultado.

### 3. Capacidad neutral separada de `read` (CA-3, condicional -- no disparada)

Ninguna combinacion se adopta en este ADR, asi que **este ADR no define todavia** una capacidad neutral de navegacion semantica en el contrato de agentes. Deja fijado, para cuando un piloto futuro si apruebe algun rol/runtime, el criterio que MEF-ADR-0050 y la nota tecnica de #981 ya anticipan:

- La capacidad se expresaria en la fuente neutral (`src/internal/{agents,commands}/*.md`) como intencion semantica separada de `read` -- nunca fusionada con ella --, y cada adaptador de runtime mapearia esa intencion a su mecanismo concreto (`LSP` como tool de Claude Code, `lsp` como capacidad escalar de OpenCode).
- **Prohibido mapear LSP implicitamente desde `read`.** La asimetria vigente hoy en `src/internal/contract/opencode-permissions.json` (`capability_scalar.read` incluye `"lsp"`, mientras que en Claude Code `read` nunca implica la tool `LSP`) es un detalle de implementacion del contrato interno de hoy -- documentado, no doctrina a preservar. Si algun rol/runtime se adoptara en el futuro, ese mapping se revisaria explicitamente en vez de heredarse por inercia (ver follow-up 4 mas abajo).
- `dotnet build`/`dotnet test` seguirian siendo el oraculo autoritativo sobre correctud en cualquier escenario, LSP habilitado o no -- ningun piloto ni adopcion futura cambia esto.

### 4. Fallback textual y no-carga de configuracion (CA-4)

Como las seis combinaciones evaluables resultan en evidencia insuficiente, la doctrina vigente **no cambia**: los agentes publicados que trabajan sobre C# (`planner`, `implementer`, `projection-implementer`, `reviewer`) continuan con el baseline textual fijado tras #978 (sin MCP de Rider, navegacion con `Glob`/`Grep`/`Read`, diagnostico con `dotnet build`/`dotnet test`).

Como consecuencia directa de este ADR:

- Ningun agente publicado ni interno carga el plugin `csharp-lsp` de Claude Code ni declara la tool `LSP` en su configuracion.
- Ningun perfil de agente exporta `OPENCODE_EXPERIMENTAL_LSP_TOOL` ni declara `lsp: allow` en `src/internal/contract/opencode-permissions.json` ni en ningun `opencode.json` de proyecto consumidor.
- Los roles que #976 excluyo explicitamente del corpus (`test-writer`, `smoke-test-writer`, `projection-test-writer`, `projections-scaffolder`, y `projection-implementer` en su rol read-side) permanecen **fuera de cualquier adopcion**: no hay evidencia a favor ni en contra para ellos, y el resultado de evidencia insuficiente en los tres roles si probados tampoco se extrapola hacia ellos.

### 5. Follow-ups por componente y lado, sin issue contenedor (CA-5)

Se enumeran como candidatos; **ninguno se ejecuta en este ADR** y este ADR no crea un issue que los agrupe. Cualquier issue de adopcion posterior debe declarar su dependencia de `MEF-ADR-0052`:

1. **Lado publicado, Claude Code**: instalar `csharp-ls` (`dotnet tool install --global csharp-ls` o Homebrew) y el plugin `csharp-lsp@claude-plugins-official` en el entorno donde corre el pipeline headless; repetir los cuatro gates del preflight de #979 -- esta vez el gate 3 desde un worktree del consumidor y dentro de los subagentes que invoca cada etapa (no solo la sesion padre), y el gate 4 de frescura tras una edicion real -- antes de correr los 3 casos x 3 pares que fija #976.
2. **Lado publicado, OpenCode**: ejecutar #980 desde cero -- el issue sigue abierto y sin reporte. Verificar los tres gates (servidor C#, feature flag, permiso) por separado antes de cualquier par.
3. **Ambos runtimes**: si un piloto futuro aprueba el paso 1 (no inferioridad de calidad) en algun rol, evaluar el paso 2 (umbrales -10%/-15%) con las tres repeticiones por caso que exige #976, sin comparar cifras absolutas entre Claude Code y OpenCode en ningun punto.
4. **Lado interno**: si algun rol/runtime resultara adoptado en un ADR futuro, revisar entonces la asimetria `read` -> `lsp` de `src/internal/contract/opencode-permissions.json` a la luz del punto 3 de esta decision (capacidad neutral separada), en vez de asumir que el mapping actual ya es la doctrina correcta.

### 6. Fragmentos de changelog (CA-6)

`changelog.d/981.added.md` y `changelog.d/981.adr-index.md` documentan este ADR sin editar `CHANGELOG.md` ni `docs/adr/INDICE-TEMATICO.md` directamente.

## Alternativas consideradas

### Alt a: Esperar a que #980 se ejecute antes de sintetizar

Posponer este ADR hasta que el piloto OpenCode produzca su propio reporte, para que las seis combinaciones tengan al menos un preflight ejecutado.

**Descartada**: el propio issue #981 anticipa en su contexto que la sintesis puede concluir `no adoptar`, `adoptar solo en <runtime/rol>` o **pedir un nuevo piloto acotado** cuando un rol/runtime "no fue evaluable" -- exactamente el estado de OpenCode hoy. Bloquear la sintesis indefinidamente en una dependencia no cerrada es menos util que documentar el estado actual con transparencia total (incluyendo que #980 no corrio) y dejar el follow-up 2 explicito; un ADR futuro puede enmendar esta conclusion en cuanto #980 aporte evidencia real, sin que este documento haya fingido una espera que no tiene fecha.

### Alt b: Extrapolar el resultado `no evaluable` de Claude Code a OpenCode

Asumir que, si el mecanismo Claude Code no esta disponible en este entorno, tampoco lo estara el de OpenCode, y cerrar la sintesis sin distinguir ambos casos.

**Descartada**: contradice el principio del propio protocolo (#976) de que solo son validos los deltas dentro del mismo runtime -- cada uno tiene su propio mecanismo, servidor y gates de activacion completamente independientes. El bloqueador de Claude Code es de instalacion de un plugin+binario concretos; el de OpenCode (a la fecha de este ADR) es que el piloto nunca corrio. Son causas distintas que este ADR mantiene distinguidas en la tabla del punto 1 y en el punto 2, en vez de fundirlas en una sola conclusion.

### Alt c: Instalar el plugin/binario de Claude Code dentro de este mismo stage para desbloquear el piloto

Aprovechar la escritura de este ADR para instalar `csharp-ls` y el plugin `csharp-lsp`, re-ejecutar #979 con datos reales, y sintetizar con evidencia completa.

**Descartada**: #979 ya evaluo y descarto explicitamente esta opcion -- instalar un plugin de Claude Code cambia configuracion a nivel de usuario/maquina, fuera del arbol del repo y del alcance de una etapa headless sin turno humano que confirme un cambio de entorno compartido. Este issue (#981) es de sintesis documental, no de ejecucion de pilotos; reabrir la ejecucion aqui duplicaria el alcance que #979 ya delimito.

## Consecuencias

### Positivas

- **Ninguna doctrina de agente cambia por intuicion o por extrapolacion entre runtimes**: las seis combinaciones quedan en evidencia insuficiente, con la causa de cada bloqueo documentada por separado (entorno vs ejecucion pendiente).
- **El fallback textual post-#978 sigue siendo la unica doctrina activa**, sin que ningun agente publicado cargue schema o configuracion de LSP como efecto colateral de un piloto que no concluyo.
- **Los follow-ups quedan concretos y verificables** (instalacion exacta para Claude Code, ejecucion pendiente de #980 para OpenCode) en vez de un generico "reintentar mas adelante".
- **MEF-ADR-0050 y MEF-ADR-0049 quedan honrados**: ninguna doctrina comun asume un mecanismo de runtime concreto, y el punto 3 deja fijado el criterio de mapeo neutral para cuando (si) haga falta.

### Negativas

- **La pregunta original de #976 (LSP reduce tokens/mejora calidad frente a texto?) sigue sin respuesta** para los tres roles en ambos runtimes -- este ADR sintetiza ausencia de evidencia, no un resultado positivo o negativo del mecanismo en si.
- **El piloto Claude Code requiere trabajo de entorno fuera del pipeline** (instalar plugin + binario a nivel de usuario/maquina) antes de poder reintentarse con datos reales.
- **El piloto OpenCode representa esfuerzo pendiente completo**: #980 no tiene ni un preflight corrido, a diferencia de #979 que al menos deja los cuatro gates documentados.
- **Un tercer ADR de sintesis podria ser necesario** si #979 y #980 se re-ejecutan en momentos distintos y ninguno de los dos justifica reabrir este documento por si solo -- riesgo aceptado porque forzar sincronizacion exacta entre dos pilotos independientes no esta en el alcance de ninguno de los tres issues (#979, #980, #981).

## Referencias

- Issue #976: protocolo, corpus, umbrales y formato de evidencia (`docs/testing/lsp-experiment-protocol.md`).
- Issue #978 (PR #1002): retiro de la dependencia del MCP de Rider de los agentes publicados -- baseline textual de ambos pilotos.
- Issue #979 (PR #1011): piloto Claude Code, `docs/testing/lsp-pilot-claude.md` -- fuente del resultado `no evaluable` y de los cuatro gates de preflight citados en este ADR.
- Issue #980: piloto OpenCode -- abierto sin reporte a la fecha de este ADR (2026-09-07); fuente del estado "piloto no ejecutado" citado en este ADR.
- MEF-ADR-0050 (principio de neutralidad de runtime): fuente del criterio de capacidad neutral separada de `read` que el punto 3 fijaria si se adoptara.
- MEF-ADR-0049 (arquitectura neutral runtime/proveedor): precedente de mapeos por runtime y origen de `src/internal/contract/opencode-permissions.json`, cuya asimetria `read`->`lsp` cita el punto 3.
- MEF-ADR-0019 (publicado vs interno): los follow-ups del punto 5 declaran explicitamente a que lado pertenece cada uno.
- MEF-ADR-0030 (esquema de identificacion de ADRs): fija el numero `MEF-ADR-0052` (verificado libre: `docs/adr/` llegaba a `MEF-ADR-0051` antes de este ADR).

## Control de cambios

- 2026-09-07: creacion como `aceptado` (issue #981). Sintetiza la evidencia de #979 (piloto Claude Code, `no evaluable` por plugin/binario ausentes en el entorno, no por inviabilidad del mecanismo) y #980 (piloto OpenCode, no ejecutado -- issue abierto sin reporte a esta fecha); fija `evidencia insuficiente` para las seis combinaciones runtime x rol evaluables por #976, sin comparar cifras absolutas entre runtimes y sin extrapolar el bloqueo de uno al otro (seccion "Decision", puntos 1-2); deja fijado el criterio de capacidad neutral separada de `read` para una adopcion futura, sin dispararlo (punto 3); mantiene el fallback textual post-#978 y prohibe cargar configuracion/schema de LSP en cualquier agente publicado como efecto de este ADR, dejando los roles no probados explicitamente fuera (punto 4); y enumera cuatro follow-ups por componente y lado sin ejecutarlos ni crear un issue contenedor (punto 5).
