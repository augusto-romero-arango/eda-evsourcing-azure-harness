# MEF-ADR-0052: Decision multi-runtime sobre navegacion semantica en agentes C#

- **Fecha**: 2026-09-07
- **Estado**: aceptado
- **Aplica a**: doctrina de navegacion semantica (LSP) en los agentes publicados que trabajan sobre C# -- los tres roles del corpus de #976 (`planner`, `implementer`, `reviewer`) mas `projection-implementer`, que hereda la doctrina resultante sin haber sido probado en ningun runtime --, en ambos runtimes soportados hoy (Claude Code, OpenCode). Sintetiza la evidencia de #979 (piloto Claude Code) y #980 (piloto OpenCode) sobre el protocolo fijado por #976 (`docs/testing/lsp-experiment-protocol.md`). Cross-referencia MEF-ADR-0050 (neutralidad de toda operacion: la capacidad se expresaria como intencion neutral si se adoptara), MEF-ADR-0049 (arquitectura neutral de runtime: precedente de mapeos por runtime sin confundirlo con soporte publicado disponible), MEF-ADR-0019 (publicado vs interno: identifica que lado consumiria cada follow-up) y MEF-ADR-0030 (esquema de identificacion, fija el numero `0052` como libre).

**Issues bloqueados por este ADR**: ninguno. Este ADR no ejecuta adopcion; los follow-ups de la seccion "Decision, punto 5" quedan como candidatos para issues futuros que declaren su dependencia de `MEF-ADR-0052`, no como trabajo que este documento reserve o bloquee.

## Contexto

#976 fijo un protocolo A/B (`docs/testing/lsp-experiment-protocol.md`) para medir si la navegacion semantica (LSP) reduce tokens/tiempo o mejora calidad frente a busqueda textual, en los tres roles con oraculo independiente (`planner` / analisis de impacto, `implementer` / cambio sobre test rojo, `reviewer` / revision de diff transversal), sobre el mismo SHA congelado del consumidor `Bitakora.ControlAsistencia`. El protocolo declara explicitamente que **solo son validos los deltas texto-vs-LSP dentro del mismo runtime**: Claude Code y OpenCode exponen servidor, tool schema, wire format y mecanismo de activacion distintos, y una mejora en uno no autoriza generalizar al otro. #978 retiro antes la dependencia del MCP de Rider de los agentes publicados, asi que el baseline textual de ambos pilotos ya no lo usa.

#979 (piloto Claude Code) y #980 (piloto OpenCode) ejecutan ese protocolo cada uno sobre su propio mecanismo:

- **Claude Code**: plugin oficial `csharp-lsp` 1.0.0 del marketplace `anthropics/claude-plugins-official`, respaldado por el binario `csharp-ls`.
- **OpenCode**: servidor C# nativo (requiere .NET SDK), habilitado solo con `OPENCODE_EXPERIMENTAL_LSP_TOOL=true` (o el flag experimental global) y permiso `lsp: allow` -- tres gates independientes.

Este issue (#981) **sintetiza** esa evidencia; no ejecuta ningun par adicional ni cambia doctrina de agente por su cuenta.

### Resultado de #979 (piloto Claude Code)

`docs/testing/lsp-pilot-claude.md` concluye **NO EVALUABLE** para los tres roles del corpus. El preflight se ejecuto completo (los cuatro gates que fija el protocolo): los gates 1, 2 y 3 quedaron en rojo -- el 3 verificado empiricamente, no inferido del fallo de los anteriores -- y el 4 no se alcanzo por depender del 3:

| Gate | Resultado |
|---|---|
| 1. Binario `csharp-ls` presente | falla (`which csharp-ls` -> no encontrado) |
| 2. Plugin `csharp-lsp` instalado y habilitado | falla (`claude plugin list` no lo muestra; solo `azure@claude-plugins-official`, deshabilitado) |
| 3. Tool `LSP` disponible en una consulta de control dentro de `claude -p` headless | falla (dos consultas de control, formulaciones distintas, ambas confirman ausencia) |
| 4. Frescura tras una edicion | no alcanzado (depende del gate 3) |

Consecuencia: **cero pares corridos** en los tres roles -- ni siquiera el brazo texto se ejecuto de forma aislada, porque el protocolo no acepta pares incompletos. El reporte distingue explicitamente que el bloqueo es de **entorno** (plugin/binario no instalados en la maquina donde corre el stage headless), no de **mecanismo**: el plugin existe, esta versionado (`1.0.0`) y documentado por el marketplace oficial. Instalarlo fue evaluado y descartado por el propio piloto -- cambia configuracion de plugins a nivel usuario/maquina, fuera del alcance de una etapa headless sin turno humano que confirme un cambio de entorno compartido.

### Resultado de #980 (piloto OpenCode)

`docs/testing/lsp-pilot-opencode.md` concluye **NO EVALUABLE** para los tres roles del corpus, con los **tres gates de mecanismo en verde** y el gate 4 (frescura) no concluyente. El piloto evaluo los cuatro gates, sin detenerse en ninguno, porque ninguno de los tres de mecanismo fallo:

| Gate | Resultado |
|---|---|
| 1. Servidor C# built-in (seccion `lsp` habilitada + .NET SDK detectado) | pasa (confirmado con invocacion real de la tool, no solo con el log de registro) |
| 2. Feature flag `OPENCODE_EXPERIMENTAL_LSP_TOOL=true` | pasa |
| 3. Permiso `lsp: allow` | pasa |
| 4. Frescura tras una edicion | no concluyente (la consulta de verificacion se colgo en el arranque de `opencode run`, no respondio en 10m48s y se aborto) |

La evidencia de los gates 2 y 3 es una sesion real de `opencode run` que invoco la tool `lsp` con `operation: documentSymbol` sobre un `.cs` de prueba y devolvio sus cuatro simbolos correctos, verificables contra el contenido del archivo -- no un log de registro ni la respuesta de un modelo sobre si mismo; el log de esa sesion registra ademas la evaluacion `permission=lsp -> allow` como paso propio. Con una salvedad que el reporte deja explicita: los gates 2 y 3 se confirmaron **en la misma corrida**, sin control negativo con el feature flag sin exportar ni con `lsp: deny`, asi que la verificacion "por separado" que pide #976 se cumplio para el gate 1 y solo parcialmente para los otros dos. Entorno: OpenCode `1.18.29`, .NET SDK `10.0.201`, modelo `openai/gpt-5.4-mini` (unico proveedor con credenciales activas ahi, asi que el piloto **no** comparte proveedor/modelo con #979 -- el protocolo no lo exige, porque nunca se comparan cifras absolutas entre runtimes).

Consecuencia: **cero pares corridos** en los tres roles, igual que #979, pero **por una causa distinta**. Aqui el mecanismo esta disponible y funcional desde el preflight; lo que falta es la ejecucion del corpus, porque los 3 casos x 3 pares exigen worktrees del SHA congelado del consumidor con oraculos predeclarados por un operador humano -- exactamente lo que la nota tecnica de #980 reserva como paso humano posterior ("La ejecucion y exportacion de evidencia desde el consumidor son pasos humanos; el PR de Mefisto solo incorpora el reporte sanitizado").

El piloto deja ademas dos limitaciones operativas registradas, relevantes para quien ejecute el corpus real: los comandos `opencode debug lsp document-symbols/symbols/diagnostics` devuelven resultados vacios (`[]` y `{"<archivo>": []}`) incluso con el servidor `csharp` registrado -- crean y destruyen la instancia en el mismo milisegundo del `init` --, asi que esa CLI **no** es un proxy fiable del gate 1; y el arranque de `opencode run` se colgo en dos de las cuatro invocaciones del piloto -- la sonda del gate 4 (10m48s sin respuesta) y la consulta de control `C1` (16m31s) --, ambas detenidas en el mismo punto del log (`init`, antes de crear o adjuntar sesion y antes de cualquier llamada al proveedor), mientras las otras dos completaron en 2.4s y 7.7s. Como `C1` era una sesion nueva sin edicion previa, ese cuelgue **no** es atribuible a continuar sesion ni a la edicion: el gate 4 queda sin medir y quien corra el corpus necesita limite de tiempo por ejecucion.

## Decision

### 1. Tabla por runtime y rol (CA-1)

Ninguna celda compara cifras absolutas entre runtimes -- ninguna de las seis combinaciones alcanzo siquiera un par valido, asi que no hay cifra que comparar en ningun sentido:

| Runtime | Rol | Preflight ejecutado | Pares corridos | Resultado del piloto |
|---|---|---|---|---|
| Claude Code | `planner` | si (4 gates; fallan 1-3, el 4 no alcanzado) | 0/3 | `no evaluable` |
| Claude Code | `implementer` | si (4 gates; fallan 1-3, el 4 no alcanzado) | 0/3 | `no evaluable` |
| Claude Code | `reviewer` | si (4 gates; fallan 1-3, el 4 no alcanzado) | 0/3 | `no evaluable` |
| OpenCode | `planner` | si (4 gates: 1-3 en verde, gate 4 no concluyente) | 0/3 | `no evaluable` (corpus pendiente, mecanismo disponible) |
| OpenCode | `implementer` | si (4 gates: 1-3 en verde, gate 4 no concluyente) | 0/3 | `no evaluable` (corpus pendiente, mecanismo disponible) |
| OpenCode | `reviewer` | si (4 gates: 1-3 en verde, gate 4 no concluyente) | 0/3 | `no evaluable` (corpus pendiente, mecanismo disponible) |

**Como se lee la regla del protocolo.** #976 dice que un rol cuyo mecanismo LSP no esta disponible de forma estable "concluye `no evaluable` y queda fuera de la sintesis de #981". Este ADR lo lee como *fuera del calculo de medianas y de cualquier adopcion*, **no** fuera del registro: CA-1 de #981 exige explicitamente no ocultar corridas fallidas ni no evaluables. De ahi que las seis combinaciones figuren en la tabla con su causa y su conteo de pares en cero, y que ninguna aporte cifra a ningun umbral del punto 2.

Roles fuera del corpus de #976 (`test-writer`, `smoke-test-writer`, `projection-test-writer`, `projections-scaffolder`, `projection-implementer` en su rol read-side) no figuran en la tabla: no fueron probados en ningun runtime y este ADR no les asigna fila ni conclusion (ver punto 4).

### 2. Decision explicita por combinacion, con umbrales y tradeoffs (CA-2)

Para las **seis** combinaciones runtime x rol de la tabla, la decision es **evidencia insuficiente**. Aplicando el criterio de dos pasos predeclarado por #976:

1. **No inferioridad de calidad** (obligatorio primero): no evaluable en las seis combinaciones -- exige que el brazo LSP pase el mismo oraculo que el brazo texto en 3 repeticiones, y cero repeticiones del brazo LSP corrieron en ningun runtime. Ninguna combinacion queda "rechazada por calidad": eso exigiria haber observado al brazo LSP fallar el oraculo, y no se lo observo en absoluto en ningun caso.
2. **Beneficio neto** (medianas de tokens de input y wall-clock, umbrales -10%/-15%): no se evalua en ninguna combinacion, por la misma regla explicita de #976 -- sin tres repeticiones validas por brazo no se calcula ninguna mediana, ni se sustituye con datos de otro runtime.

Tradeoffs de tokens, tiempo y calidad quedan **sin medir** en las seis combinaciones -- no hay una sola fila de evidencia cuantitativa que reportar.

El tradeoff de **indexacion** queda igualmente sin medir: la columna `cache` (`fria`/`caliente`) que el formato de evidencia de #976 obliga a anotar aparte -- nunca promediada con tokens ni con tiempo -- no tiene un solo valor registrado en ninguno de los dos pilotos -- el `cache read` de prompt que #980 si anota en sus consultas de control es cache del LLM, no indexacion, y no alimenta esa columna. Lo unico conocido hoy de ese eje es cualitativo y se deriva del diseno de cada mecanismo, no de una medicion: en **Claude Code** el plugin no aporta servidor propio sino que ejecuta el binario `csharp-ls` del `PATH`, que debe cargar proyecto/solucion antes de responder la primera consulta semantica -- por eso el costo de arranque en frio es un dato del preflight y no un supuesto heredable; en **OpenCode** el servidor C# built-in exige un .NET SDK detectado y arranca deshabilitado salvo configuracion explicita de la seccion `lsp`, y el piloto #980 dejo un unico wall-clock util de consulta de control -- 7.7s para una sesion nueva que invoca `glob` + `lsp(documentSymbol)` sobre un archivo de prueba trivial --, que mide disponibilidad del mecanismo, **no** entra en ninguna mediana del corpus y no es un costo de indexacion cuantificado. Las otras dos invocaciones que ese piloto aborto se colgaron en el arranque, antes del servidor LSP y del proveedor, asi que no miden nada de este eje. Este ADR no contrasta esa cifra entre runtimes.

Los dos ejes restantes con senal cualitativa -- **madurez experimental** y causa del bloqueo -- son distintos entre runtimes y no se promedian entre si:

- **Claude Code**: el bloqueador es de **entorno**, no de mecanismo. El plugin `csharp-lsp` es oficial, versionado (`1.0.0`) y depende de una instalacion externa a nivel de usuario/maquina (binario `csharp-ls` + `claude plugin install`) que ningun stage headless del pipeline publicado ejecuta hoy por su cuenta. Dos reportes abiertos del tracker de terceros (`anthropics/claude-code#84125`, `#79744`) senalan riesgo adicional de poda de la tool en subagentes y de desincronizacion tras editar en modo interactivo -- ninguno de los dos se llego a verificar aqui porque el gate 3 fallo antes.
- **OpenCode**: el mecanismo esta **confirmado disponible** en el entorno del piloto -- los tres gates en verde con invocacion real de la tool --, asi que el bloqueador no es de mecanismo ni de entorno: es la **ejecucion del corpus**, un paso humano sobre el consumidor congelado. La senal de madurez experimental se mantiene, pero ahora con matices medidos en vez de supuestos: la documentacion oficial de OpenCode (citada por #976/#980) advierte que LSP "no siempre es beneficio neto"; el mecanismo exige tres gates independientes en vez de uno, una superficie de fallo mayor que la de Claude Code; el gate 4 de frescura quedo **sin verificar**; y dos de las cuatro invocaciones de `opencode run` del piloto se colgaron en el arranque -- antes de crear o adjuntar sesion y antes de llamar al proveedor -- en el mismo entorno donde las otras dos completaron en segundos. Ese cuelgue es de la CLI, no del mecanismo LSP, pero basta para no dar por deterministica la ejecucion por lotes que exige el corpus.

### 3. Capacidad neutral separada de `read` (CA-3, condicional -- no disparada)

Ninguna combinacion se adopta en este ADR, asi que **este ADR no define todavia** una capacidad neutral de navegacion semantica en el contrato de agentes. Deja fijado, para cuando un piloto futuro si apruebe algun rol/runtime, el criterio que MEF-ADR-0050 y la nota tecnica de #981 ya anticipan:

- La capacidad se expresaria en la fuente neutral (`src/internal/{agents,commands}/*.md`) como intencion semantica separada de `read` -- nunca fusionada con ella --, y cada adaptador de runtime mapearia esa intencion a su mecanismo concreto (`LSP` como tool de Claude Code, `lsp` como capacidad escalar de OpenCode).
- **Prohibido mapear LSP implicitamente desde `read`.** La asimetria vigente hoy en `src/internal/contract/opencode-permissions.json` (`capability_scalar.read` incluye `"lsp"`, mientras que en Claude Code `read` nunca implica la tool `LSP`) es un detalle de implementacion del contrato interno de hoy -- documentado, no doctrina a preservar. Su efecto practico es observable, no teorico: los adaptadores generados del lado interno emiten hoy `"lsp":"allow"` por herencia de `read` (ver el punto 4). Si algun rol/runtime se adoptara en el futuro, ese mapping se revisaria explicitamente en vez de heredarse por inercia (ver follow-up 4 mas abajo).
- `dotnet build`/`dotnet test` seguirian siendo el oraculo autoritativo sobre correctud en cualquier escenario, LSP habilitado o no -- ningun piloto ni adopcion futura cambia esto.

### 4. Fallback textual y no-carga de configuracion (CA-4)

Como las seis combinaciones evaluables resultan en evidencia insuficiente, la doctrina vigente **no cambia**: los agentes publicados que trabajan sobre C# (`planner`, `implementer`, `projection-implementer`, `reviewer`) continuan con el baseline textual fijado tras #978 (sin MCP de Rider, navegacion con `Glob`/`Grep`/`Read`, diagnostico con `dotnet build`/`dotnet test`).

Como consecuencia directa de este ADR:

- Ningun agente publicado ni interno carga el plugin `csharp-lsp` de Claude Code ni declara la tool `LSP` en su configuracion.
- Ningun perfil de agente exporta `OPENCODE_EXPERIMENTAL_LSP_TOOL`, ni en el lado publicado ni en el interno, ni en ningun `opencode.json` de proyecto consumidor: ese flag es el gate que mantiene apagada la tool `lsp` de OpenCode hoy, y este ADR no lo enciende en ninguna parte.
- **Estado real del contrato interno, en vez de una afirmacion mas limpia y falsa**: el mapping `capability_scalar.read` de `src/internal/contract/opencode-permissions.json` ya incluye `"lsp"`, asi que los cinco adaptadores generados del lado interno (`.opencode/agents/`: `mefisto-planner`, `mefisto-writer`, `mefisto-reviewer`, `mefisto-investigator`, `mefisto-historiador`) emiten `"lsp":"allow"` en su bloque `permission` **por herencia de la capacidad `read`**, sin que ninguno la declare. Eso es exactamente la asimetria que el punto 3 proscribe para una adopcion futura, y **este ADR no la toca**: es lado interno (MEF-ADR-0019), preexistente a los pilotos, inerte mientras el feature flag siga sin exportarse, y su correccion es el follow-up 4 del punto 5 -- no un efecto colateral de esta sintesis. Ningun agente **publicado** declara la capacidad LSP en ningun runtime.
- Los roles que #976 excluyo explicitamente del corpus (`test-writer`, `smoke-test-writer`, `projection-test-writer`, `projections-scaffolder`, y `projection-implementer` en su rol read-side) permanecen **fuera de cualquier adopcion**: no hay evidencia a favor ni en contra para ellos, y el resultado de evidencia insuficiente en los tres roles si probados tampoco se extrapola hacia ellos.

### 5. Follow-ups por componente y lado, sin issue contenedor (CA-5)

Se enumeran como candidatos; **ninguno se ejecuta en este ADR** y este ADR no crea un issue que los agrupe. Cualquier issue de adopcion posterior debe declarar su dependencia de `MEF-ADR-0052`:

1. **Lado publicado, Claude Code**: instalar `csharp-ls` (`dotnet tool install --global csharp-ls` o Homebrew) y el plugin `csharp-lsp@claude-plugins-official` en el entorno donde corre el pipeline headless; repetir los cuatro gates del preflight de #979 -- esta vez el gate 3 desde un worktree del consumidor y dentro de los subagentes que invoca cada etapa (no solo la sesion padre), y el gate 4 de frescura tras una edicion real -- antes de correr los 3 casos x 3 pares que fija #976.
2. **Lado publicado, OpenCode**: #980 ya dejo el preflight en verde y la receta de configuracion verificada, asi que lo pendiente **no** es reejecutar el preflight sino correr el corpus -- materializar `planner`/`implementer`/`reviewer` como configuracion temporal equivalente de OpenCode (hoy sin generador automatico: `generate-internal-adapters.sh` opera sobre agentes internos, no sobre los publicados) y ejecutar los 3 casos x 3 pares sobre worktrees limpios del SHA congelado. Cerrar de paso el gate 4 de frescura, que quedo sin verificar, y reverificar los cuatro gates desde cero si cambia la version de OpenCode, el .NET SDK o el modelo.
3. **Ambos runtimes**: si un piloto futuro aprueba el paso 1 (no inferioridad de calidad) en algun rol, evaluar el paso 2 (umbrales -10%/-15%) con las tres repeticiones por caso que exige #976, sin comparar cifras absolutas entre Claude Code y OpenCode en ningun punto.
4. **Lado interno**: si algun rol/runtime resultara adoptado en un ADR futuro, revisar entonces la asimetria `read` -> `lsp` de `src/internal/contract/opencode-permissions.json` a la luz del punto 3 de esta decision (capacidad neutral separada), en vez de asumir que el mapping actual ya es la doctrina correcta.

### 6. Fragmentos de changelog (CA-6)

`changelog.d/981.added.md` y `changelog.d/981.adr-index.md` documentan este ADR sin editar `CHANGELOG.md` ni `docs/adr/INDICE-TEMATICO.md` directamente. La enmienda del 2026-09-07 anade `changelog.d/980.changed.md` y **no** un segundo fragmento de indice: `changelog.d/981.adr-index.md` sigue sin consolidar y ya aporta la fila de `MEF-ADR-0052`, asi que otro produciria una fila duplicada del mismo ADR.

## Alternativas consideradas

### Alt a: Esperar a que #980 se ejecute antes de sintetizar

Posponer este ADR hasta que el piloto OpenCode produzca su propio reporte, para que las seis combinaciones tengan al menos un preflight ejecutado.

**Descartada**: el propio issue #981 anticipa en su contexto que la sintesis puede concluir `no adoptar`, `adoptar solo en <runtime/rol>` o **pedir un nuevo piloto acotado** cuando un rol/runtime "no fue evaluable" -- exactamente el estado de OpenCode. Bloquear la sintesis indefinidamente en una dependencia no cerrada es menos util que documentar el estado con transparencia total y dejar el follow-up 2 explicito, sin fingir una espera que no tiene fecha.

La enmienda del 2026-09-07 confirma que la eleccion fue correcta en su forma, pero no en su lectura del estado: el reporte de #980 si existia -- escrito y con los tres gates de mecanismo en verde -- y solo no estaba en `main` porque el watchdog del pipeline interno mato a su etapa `writer` por timeout antes del commit (`TIMEOUT`, 1859s, exit 124), tras haber escrito los deliverables. Incorporarlo no cambio la conclusion de la sintesis (las seis combinaciones siguen en `evidencia insuficiente` por corpus vacio), pero si la causa registrada para OpenCode. Leccion transferible para futuras sintesis: la ausencia de un archivo en `main` no es evidencia de que el trabajo no se hizo, sobre todo cuando la dependencia declarada corrio en el mismo batch.

### Alt b: Extrapolar el resultado `no evaluable` de Claude Code a OpenCode

Asumir que, si el mecanismo Claude Code no esta disponible en este entorno, tampoco lo estara el de OpenCode, y cerrar la sintesis sin distinguir ambos casos.

**Descartada**: contradice el principio del propio protocolo (#976) de que solo son validos los deltas dentro del mismo runtime -- cada uno tiene su propio mecanismo, servidor y gates de activacion completamente independientes. El bloqueador de Claude Code es de instalacion de un plugin+binario concretos; el de OpenCode es la ejecucion del corpus, con el mecanismo ya confirmado disponible. Son causas distintas que este ADR mantiene distinguidas en la tabla del punto 1 y en el punto 2, en vez de fundirlas en una sola conclusion.

La evidencia de #980 muestra ademas que la extrapolacion habria sido **factualmente falsa**, no solo metodologicamente invalida: el mecanismo LSP de OpenCode si estaba disponible y respondiendo con datos semanticos correctos en el mismo entorno donde el de Claude Code no lo estaba.

### Alt c: Instalar el plugin/binario de Claude Code dentro de este mismo stage para desbloquear el piloto

Aprovechar la escritura de este ADR para instalar `csharp-ls` y el plugin `csharp-lsp`, re-ejecutar #979 con datos reales, y sintetizar con evidencia completa.

**Descartada**: #979 ya evaluo y descarto explicitamente esta opcion -- instalar un plugin de Claude Code cambia configuracion a nivel de usuario/maquina, fuera del arbol del repo y del alcance de una etapa headless sin turno humano que confirme un cambio de entorno compartido. Este issue (#981) es de sintesis documental, no de ejecucion de pilotos; reabrir la ejecucion aqui duplicaria el alcance que #979 ya delimito.

## Consecuencias

### Positivas

- **Ninguna doctrina de agente cambia por intuicion o por extrapolacion entre runtimes**: las seis combinaciones quedan en evidencia insuficiente, con la causa de cada bloqueo documentada por separado (entorno ausente en Claude Code vs corpus pendiente en OpenCode, con el mecanismo ahi confirmado disponible).
- **El fallback textual post-#978 sigue siendo la unica doctrina activa**, sin que ningun agente publicado cargue schema o configuracion de LSP como efecto colateral de un piloto que no concluyo.
- **Los follow-ups quedan concretos y verificables** (instalacion exacta para Claude Code; corpus sobre el consumidor congelado para OpenCode, con la receta de configuracion ya verificada por #980) en vez de un generico "reintentar mas adelante".
- **MEF-ADR-0050 y MEF-ADR-0049 quedan honrados**: ninguna doctrina comun asume un mecanismo de runtime concreto, y el punto 3 deja fijado el criterio de mapeo neutral para cuando (si) haga falta.

### Negativas

- **La pregunta original de #976 (LSP reduce tokens/mejora calidad frente a texto?) sigue sin respuesta** para los tres roles en ambos runtimes -- este ADR sintetiza ausencia de evidencia, no un resultado positivo o negativo del mecanismo en si.
- **El piloto Claude Code requiere trabajo de entorno fuera del pipeline** (instalar plugin + binario a nivel de usuario/maquina) antes de poder reintentarse con datos reales.
- **El corpus real es el esfuerzo pendiente en ambos runtimes**: #980 deja el preflight en verde y la receta de configuracion verificada, pero los 18 pares (36 corridas) sobre el consumidor congelado son trabajo humano no ejecutado -- y en Claude Code no se llega siquiera a ese punto sin resolver antes la instalacion del plugin/binario. El gate 4 de frescura queda sin verificar en OpenCode, y el arranque de `opencode run` se colgo en dos de las cuatro invocaciones del piloto: quien corra el corpus necesita limite de tiempo por ejecucion y la regla de reemplazo de #976.
- **La asimetria `read` -> `lsp` del contrato interno sigue vigente** tras este ADR (punto 4): los adaptadores OpenCode del lado interno conceden `lsp: allow` por herencia de `read`, hoy inerte por el feature flag no exportado, y su correccion queda diferida al follow-up 4 en vez de resolverse aqui.
- **Un tercer ADR de sintesis podria ser necesario** si #979 y #980 se re-ejecutan en momentos distintos y ninguno de los dos justifica reabrir este documento por si solo -- riesgo aceptado porque forzar sincronizacion exacta entre dos pilotos independientes no esta en el alcance de ninguno de los tres issues (#979, #980, #981).

## Referencias

- Issue #976: protocolo, corpus, umbrales y formato de evidencia (`docs/testing/lsp-experiment-protocol.md`).
- Issue #978 (PR #1002): retiro de la dependencia del MCP de Rider de los agentes publicados -- baseline textual de ambos pilotos.
- Issue #979 (PR #1011): piloto Claude Code, `docs/testing/lsp-pilot-claude.md` -- fuente del resultado `no evaluable` y de los cuatro gates de preflight citados en este ADR.
- Issue #980 (PR #1014): piloto OpenCode, `docs/testing/lsp-pilot-opencode.md` -- fuente del preflight en verde (gates 1-3 con invocacion real de la tool), del gate 4 no concluyente, del entorno verificado y de las dos limitaciones operativas citadas en este ADR.
- MEF-ADR-0050 (principio de neutralidad de runtime): fuente del criterio de capacidad neutral separada de `read` que el punto 3 fijaria si se adoptara.
- MEF-ADR-0049 (arquitectura neutral runtime/proveedor): precedente de mapeos por runtime y origen de `src/internal/contract/opencode-permissions.json`, cuya asimetria `read`->`lsp` cita el punto 3.
- MEF-ADR-0019 (publicado vs interno): los follow-ups del punto 5 declaran explicitamente a que lado pertenece cada uno.
- MEF-ADR-0030 (esquema de identificacion de ADRs): fija el numero `MEF-ADR-0052` (verificado libre: `docs/adr/` llegaba a `MEF-ADR-0051` antes de este ADR).

## Control de cambios

- 2026-09-07: creacion como `aceptado` (issue #981). Sintetiza la evidencia de #979 (piloto Claude Code, `no evaluable` por plugin/binario ausentes en el entorno, no por inviabilidad del mecanismo) y #980 (piloto OpenCode, no ejecutado -- issue abierto sin reporte a esta fecha); fija `evidencia insuficiente` para las seis combinaciones runtime x rol evaluables por #976, sin comparar cifras absolutas entre runtimes y sin extrapolar el bloqueo de uno al otro (seccion "Decision", puntos 1-2); deja fijado el criterio de capacidad neutral separada de `read` para una adopcion futura, sin dispararlo (punto 3); mantiene el fallback textual post-#978 y prohibe cargar configuracion/schema de LSP en cualquier agente publicado como efecto de este ADR, dejando los roles no probados explicitamente fuera y registrando que el `lsp: allow` heredado de `read` en los adaptadores internos de OpenCode preexiste a los pilotos y no se toca aqui (punto 4); y enumera cuatro follow-ups por componente y lado sin ejecutarlos ni crear un issue contenedor (punto 5).
- 2026-09-07: enmienda con la evidencia real de #980 (PR #1014, `docs/testing/lsp-pilot-opencode.md`). La version original registro que el piloto OpenCode "nunca comenzo" porque su reporte no estaba en `main`: la etapa `writer` del pipeline interno lo habia escrito y habia pasado los guards, pero el watchdog la mato por timeout antes del commit, asi que el ADR se redacto sobre un `main` que no lo contenia. La conclusion de sintesis **no cambia** -- las seis combinaciones siguen en `evidencia insuficiente`, con el corpus en cero pares --, pero si la causa registrada para OpenCode: el preflight si corrio y los tres gates de mecanismo (servidor C# built-in, feature flag, permiso) quedaron **en verde** con invocacion real de la tool `lsp`, con el gate 4 de frescura no concluyente. Se reescriben en consecuencia la seccion "Resultado de #980", las tres filas de OpenCode del punto 1, el tradeoff de indexacion y la senal de madurez del punto 2, el follow-up 2 del punto 5 (de "ejecutar desde cero" a "correr el corpus"), las alternativas a y b, dos consecuencias positivas y una negativa, y la referencia a #980. La revision del mismo PR ajusto despues tres afirmaciones de esta enmienda a lo que la evidencia sostiene: el cuelgue de la sonda del gate 4 ocurrio en el arranque de `opencode run` -- mismo punto del log que la consulta de control `C1`, que era una sesion nueva sin edicion previa --, no al continuar sesion tras una edicion ni esperando al proveedor; los gates 2 y 3 quedaron confirmados en conjunto, sin control negativo del feature flag; y las filas de Claude Code del punto 1 pasan a decir "fallan 1-3" en vez de "falla en gate 3", para no contradecir la tabla de gates de la seccion de #979.
