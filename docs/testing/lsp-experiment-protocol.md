# Protocolo del experimento multi-runtime de LSP en agentes C# (issue #976)

Este documento fija el **protocolo y el corpus** de un experimento A/B: si la navegacion
semantica (LSP) reduce contexto/tokens o mejora calidad frente a busqueda textual en los
agentes publicados de Mefisto que trabajan sobre C#. **No ejecuta ningun piloto** -- lo
ejecutan #979 (Claude Code) y #980 (OpenCode) sobre este mismo protocolo; #981 sintetiza
la decision. La hipotesis se expresa como capacidad semantica neutral (MEF-ADR-0050): el
servidor, la configuracion, el tool schema y el wire format quedan fijados por runtime, y
por eso **solo son validos los deltas texto-vs-LSP dentro del mismo runtime** -- ninguna
cifra absoluta de Claude Code se compara contra OpenCode, ni aqui ni en #979/#980/#981.

## Que este documento NO decide

- No corre ningun par texto/LSP: eso es #979 y #980.
- No decide adopcion de LSP en la doctrina de ningun agente: eso es #981.
- No prueba `test-writer`, `smoke-test-writer` ni las variantes de proyecciones
  (`projection-test-writer`, `projections-scaffolder`, `projection-implementer` en su
  rol read-side). Un resultado favorable en los tres roles de este protocolo **no**
  se extrapola por si solo a esos roles no probados.
- No reintroduce el MCP de Rider (#978 lo retira del baseline textual antes de este
  experimento) ni bundlea `csharp-lsp` o cambia `opencode.json`/permisos como efecto
  colateral de medir.

## Consumidor y SHA de referencia

El corpus corre sobre `Bitakora.ControlAsistencia` (consumidor de origen de la
investigacion). Como este issue no ejecuta nada, **no fija aqui un hash literal** --
fija la regla que hace reproducible el SHA entre pilotos:

1. La preflight del primer piloto que arranca (hoy #979, salvo que #980 arranque antes)
   resuelve el SHA de referencia con `git rev-parse HEAD` sobre un checkout limpio de la
   rama por defecto del consumidor y lo registra en su propio reporte
   (`docs/testing/lsp-pilot-claude.md` o `docs/testing/lsp-pilot-opencode.md`).
2. Ese mismo SHA queda **congelado** para los tres casos, las tres repeticiones por
   caso y ambos brazos (texto/LSP) de ese piloto -- ninguna repeticion vuelve a
   resolver `HEAD` por su cuenta, ni siquiera si el consumidor avanza mientras el
   piloto esta en curso.
3. El segundo piloto en ejecutarse **hereda el mismo SHA** del primero (lo cita de su
   reporte), en vez de resolver uno propio. Si el SHA original ya no existe en el
   consumidor (rebase, borrado de rama), el segundo piloto lo declara en su preflight y
   detiene su ejecucion como `no evaluable` para ese caso -- no elige un SHA distinto en
   silencio, porque eso reintroduce una variable no controlada entre runtimes.

## Casos (tres roles, un oraculo independiente cada uno)

| # | Caso | Rol bajo prueba | Oraculo independiente |
|---|---|---|---|
| 1 | Analisis de impacto de un cambio propuesto sobre un simbolo con multiples consumidores conocidos | `planner` | Lista de archivos/simbolos afectados fijada **antes** de correr el experimento (construida por el operador con `dotnet build` tras el cambio real + referencias completas), nunca derivada de la propia respuesta del agente bajo prueba |
| 2 | Cambio de implementacion sobre un test ya rojo (fase verde TDD acotada) | `implementer` | `dotnet test` sobre la suite completa del proyecto tocado: verde en el test objetivo y sin regresion en el resto: autoridad unica, no la opinion del agente sobre si termino |
| 3 | Revision de un diff con impacto transversal conocido (p. ej. un cambio que toca un simbolo referenciado desde otro bounded context o desde una proyeccion) | `reviewer` | Lista predeclarada de hallazgos esperados (los que un review correcto debe levantar), fijada por el operador antes de exponer el diff al agente |

Los tres casos comparten una propiedad: el oraculo se fija **antes** de la corrida y es
independiente del artefacto que produce el propio agente bajo prueba (CA-1). Sin oraculo
independiente, un caso no entra al corpus.

### Simbolos candidatos para las consultas semanticas

Las consultas candidatas de los brazos LSP son `goToDefinition`, `goToImplementation`,
`hover` y busqueda de referencias, siempre sobre **simbolos especificos** del caso (una
clase, un metodo, un evento concreto). Quedan **fuera del corpus**, por riesgo de
respuestas no acotadas o ambiguas que contaminarian la medicion:

- `workspaceSymbol` vacio o ambiguo (sin un termino que resuelva a un unico candidato).
- Referencias sobre simbolos transversales de uso masivo (`Handle`, `Id`,
  `CancellationToken`): su conteo de referencias no es comparable entre repeticiones ni
  aporta señal sobre el caso concreto.

## Diseno experimental

- **Tres pares por runtime, por caso.** Un "par" es una repeticion completa: brazo
  texto + brazo LSP sobre el mismo caso, mismo runtime, mismo modelo, mismo prompt,
  mismo SHA (seccion anterior) y mismo estado inicial del worktree. Con 3 casos x 3
  pares x 2 runtimes, el corpus total son 18 pares (36 ejecuciones individuales).
- **Worktrees limpios.** Cada ejecucion individual (cada brazo de cada par) arranca de
  un worktree nuevo creado desde el SHA congelado -- nunca se reutiliza el worktree de
  una ejecucion anterior, para que ningun estado residual (cache tibia, archivos ya
  tocados) contamine la comparacion.
- **Contrabalanceo del orden.** Dentro de las 3 repeticiones de un mismo par
  (caso x runtime), se alterna que brazo corre primero: repeticion 1 texto->LSP,
  repeticion 2 LSP->texto, repeticion 3 texto->LSP (o el orden inverso, siempre
  alternando). Esto controla deriva sistematica entre repeticiones (carga de maquina,
  actualizaciones de proveedor a mitad de piloto) que de otro modo favoreceria siempre
  al brazo que corre segundo o siempre al que corre primero.
- **Variables congeladas dentro de cada par**: runtime, modelo, prompt, SHA, estado
  inicial. La **unica** variable que cambia entre los dos brazos de un par es la
  disponibilidad de LSP (ver "Brazos" abajo).
- **Ninguna comparacion de cifras absolutas entre runtimes.** El delta relevante es
  texto-vs-LSP calculado dentro de Claude Code y, por separado, dentro de OpenCode.
  #979 y #980 no confrontan sus numeros entre si; #981 sintetiza dos veredictos
  independientes, no un promedio cruzado.

## Brazos del experimento

### Brazo texto (baseline)

- Sin MCP de Rider (retirado del baseline por #978).
- Sin ninguna tool ni schema de LSP expuesto al agente -- no solo "sin usarlo": la
  capacidad no esta declarada en la config de esa corrida.
- Navegacion con `Glob`/`Grep`/`Read`; diagnostico con `dotnet build`/`dotnet test`,
  igual que el agente publicado hoy tras #978.

### Brazo LSP

- **Claude Code**: unicamente el plugin oficial `csharp-lsp` 1.0.0 del marketplace
  `anthropics/claude-plugins-official`, respaldado por `csharp-ls` **[1]**. Su
  disponibilidad en modo headless (`claude -p`, el modo real del pipeline publicado) se
  verifica en preflight, no se asume -- ver "Preflight" abajo.
- **OpenCode**: unicamente el mecanismo nativo -- servidor C# (requiere .NET SDK
  detectado) + `OPENCODE_EXPERIMENTAL_LSP_TOOL=true` (o el flag experimental global) +
  permiso `lsp: allow` **[2][3]**. Los tres gates (servidor, feature flag, permiso) se
  verifican por separado en preflight: son fallos independientes.
- **Doctrina dirigida**: en ambos runtimes, el brazo LSP recibe una instruccion explicita
  de preferir la consulta semantica sobre la consulta textual para los simbolos
  candidatos del caso. Esta doctrina es temporal para el experimento -- no se adopta en
  ningun agente publicado hasta que #981 lo decida.
- **Prohibido el doble-check automatico con grep.** Una vez que una consulta semantica
  concluye con una respuesta no vacia y no ambigua, el brazo LSP no repite la misma
  consulta con `grep` "por si acaso" -- esa repeticion automatica contaminaria el conteo
  de tool calls/tokens y anularia el propio efecto que el experimento mide. El fallback a
  texto solo esta permitido cuando la consulta LSP en si falla, expira o se degrada (ver
  reglas de parada).

## Formato de evidencia

Cada repeticion (brazo individual) registra, como minimo:

| Campo | Nota |
|---|---|
| Runtime, modelo, caso, brazo (texto/LSP), posicion en el par (1ro/2do) | identifica la fila de forma unica |
| Tokens de input y de output | del contrato neutral de metricas existente; no se amplia el schema |
| Costo | si el proveedor lo expone; un costo `0` de suscripcion no se interpreta como ausencia de consumo |
| Wall-clock | duracion total de la ejecucion |
| Tool calls por nombre | conteo desglosado, no solo el total |
| Reintentos | de la propia ejecucion (timeouts, errores transitorios) |
| Resultado de `dotnet build`/`dotnet test` | autoridad unica sobre correctud, nunca la opinion del agente |
| Hallazgos mayores | lista, comparada contra el oraculo independiente del caso |
| Resultado del oraculo | pasa/no pasa, segun la tabla de casos |
| Indexacion/cache fria vs caliente | anotada aparte de las metricas anteriores, nunca mezclada en los promedios de tokens/tiempo |

El **tamano bruto de cada respuesta** (payload de la consulta LSP o del grep) es
diagnostico opcional que se deriva de la traza solo cuando el runtime la expone -- no es
metrica portable ni motivo para ampliar el contrato neutral de metricas antes de que
#979/#980 demuestren que hace falta.

## Criterio de decision (por rol, predeclarado)

Para cada uno de los tres roles del corpus, la conclusion sigue dos pasos en orden. Son
umbrales de **gobierno del experimento** elegidos por Mefisto -- no una best practice
externa citable.

1. **No inferioridad de calidad (obligatorio primero).** El brazo LSP debe pasar el
   mismo oraculo independiente que el brazo texto en las 3 repeticiones, y no debe
   introducir ningun hallazgo mayor adicional que el brazo texto no tuviera. Si este
   paso falla, el rol queda rechazado para LSP sin mirar tokens ni tiempo.
2. **Beneficio neto (solo si el paso 1 aprueba).** La mediana de tokens de input de las
   3 repeticiones del brazo LSP es al menos **10% menor** que la del brazo texto, **o**
   la mediana de wall-clock es al menos **15% menor** -- en cualquiera de los dos casos,
   sin que la otra metrica (la que no mejoro) empeore mas de **10%**. Si ninguna de las
   dos condiciones se cumple, el resultado para ese rol es "no concluyente / sin
   adopcion", no un rechazo por calidad.

## Preflight y reglas de parada

Antes de contar cualquier par como valido, cada piloto (#979/#980) verifica y registra:

- Version del runtime, version del modelo y SHA del consumidor (fijados, ver seccion
  "Consumidor y SHA de referencia").
- **Disponibilidad del mecanismo LSP con una consulta pequena de control**, no solo su
  instalacion: Claude Code confirma que `csharp-lsp` responde dentro de `claude -p`
  headless (los issues abiertos del tracker `anthropics/claude-code#84125` y `#79744`
  son senales de riesgo, no fuentes normativas, y son exactamente la razon de verificar
  esto en preflight en vez de asumirlo **[4][5]**); OpenCode confirma servidor C#,
  feature flag y permiso como tres gates separados **[2][3]**.
- **Frescura tras una edicion**: dentro de una misma ejecucion, si el brazo LSP edita un
  archivo, la siguiente consulta semantica debe reflejar esa edicion antes de aceptarse
  como valida -- una respuesta que ignora una edicion reciente se registra como
  hallazgo, no se descarta en silencio.

**Regla de parada**: si el tool LSP, el servidor o la sincronizacion fallan en preflight o
a mitad de una repeticion, esa repeticion se marca `no evaluable` (nunca se fabrica una
cifra ni se sustituye por una corrida de otro runtime). `dotnet build`/`dotnet test`
siguen siendo la autoridad sobre correctud durante todo el experimento, incluso cuando el
oraculo del caso es distinto (ver tabla de casos).

## Fuera de alcance para #981 por adelantado

Si el resultado favorece LSP en alguno de los tres roles, #981 decide una capacidad
neutral separada de `read` para exponerlo en la doctrina: hoy el contrato interno mapea
`read` a LSP solo en OpenCode (`src/internal/contract/opencode-permissions.json`,
`capability_scalar.read` incluye `"lsp"`) y no en Claude Code. Esa asimetria es un
detalle de implementacion del contrato interno de hoy, no una doctrina a preservar --
#981 no debe heredarla por inercia.

## Fuentes

- **[1]** `anthropics/claude-plugins-official`, entrada `csharp-lsp` del marketplace y
  `plugins/csharp-lsp/README.md` -- plugin oficial 1.0.0 respaldado por `csharp-ls`.
  https://github.com/anthropics/claude-plugins-official/tree/main/plugins/csharp-lsp
- **[2]** "Tools" -- documentacion oficial de OpenCode, seccion LSP (experimental):
  requiere `OPENCODE_EXPERIMENTAL_LSP_TOOL=true` (o el flag experimental global) y
  permiso `lsp: allow`. https://opencode.ai/docs/tools/#lsp-experimental
- **[3]** "LSP" -- documentacion oficial de OpenCode: servidor C# incluido cuando hay
  .NET SDK, deshabilitado por defecto salvo configuracion explicita de la seccion `lsp`.
  https://opencode.ai/docs/lsp/
- **[4]** `anthropics/claude-code#84125` -- reporte abierto del tracker, senal de riesgo
  sobre LSP interactivo, no verificado para el modo headless `-p` que usa el pipeline
  publicado de Mefisto.
- **[5]** `anthropics/claude-code#79744` -- idem, reporta ademas una diferencia entre
  modo interactivo y `-p`, motivo directo de la verificacion de preflight de esta
  seccion.
