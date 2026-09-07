# Piloto OpenCode del experimento LSP en agentes C# (issue #980)

Ejecuta, para el brazo **OpenCode** unicamente, el protocolo fijado por
`docs/testing/lsp-experiment-protocol.md` (issue #976). No compara cifras
absolutas contra Claude Code (#979); esa comparacion no existe en ningun punto
de este documento ni de la sintesis posterior (#981). Tampoco certifica un
adaptador publicado OpenCode del pipeline de Mefisto: hoy el pipeline
publicado invoca `claude -p` directamente (MEF-ADR-0049), y este piloto es
investigacion manual y aislada, no soporte de instalacion para consumidores.

## Veredicto

**NO EVALUABLE (corpus en cero pares), con el preflight completo en verde.**
A diferencia de #979 (Claude Code), ningun gate del mecanismo LSP de OpenCode
fallo en este entorno: con `.NET SDK` detectado, la seccion `lsp` habilitada
en la config, `OPENCODE_EXPERIMENTAL_LSP_TOOL=true` y el permiso `lsp: allow`,
la tool `lsp` respondio con datos semanticos reales y correctos sobre un
archivo `.cs` de prueba. Sin embargo, este piloto corrio integramente dentro
del sandbox no interactivo de la etapa de tooling de Mefisto, no dentro de un
worktree de `Bitakora.ControlAsistencia` en el SHA congelado -- y ejecutar los
tres casos x tres pares del protocolo requiere operar sobre el codigo real del
consumidor, con ediciones reales y oraculos predeclarados por un operador
humano, exactamente lo que la nota tecnica del issue reserva como paso humano
posterior. Por tanto el corpus queda en **cero pares** y los tres roles
concluyen `no evaluable` por ausencia de repeticiones, no por indisponibilidad
del mecanismo.

| CA (#980) | Estado | Nota |
|---|---|---|
| CA-1 | pasa | version de OpenCode, modelo, SHA del consumidor y los tres gates (servidor C#, feature flag, permiso) probados por separado y en conjunto, con evidencia reproducible abajo |
| CA-2 | no evaluable | cero pares corridos: la materializacion de agentes publicados como config temporal de OpenCode y su ejecucion sobre el SHA congelado del consumidor son el paso humano que sigue a este piloto, no algo que la etapa headless de tooling de Mefisto pueda ejecutar sobre un repo ajeno |
| CA-3 | no evaluable | no hay filas de evidencia de pares que reportar; la tabla de metricas del protocolo queda vacia por diseno. Las consultas de control (no son pares) si reportan tokens, costo y duracion, ver abajo |
| CA-4 | parcial | se separa arranque/indexacion del contexto del LLM (ver gate 1) y se registra una consulta desincronizada/excesiva (intento de verificar frescura tras una edicion, abortado tras 10m48s sin respuesta); no hay edicion dentro de un brazo LSP real del corpus cuya frescura verificar todavia |
| CA-5 | pasa (conclusion `no evaluable` para los tres roles, sin generalizar) | ver "Conclusion por rol" abajo |
| CA-6 | pasa | `changelog.d/980.added.md` creado; ningun `opencode.json`, agente temporal ni cambio del consumidor se versiona en este repo -- toda la config de prueba vivio en `/tmp`, fuera del arbol de Mefisto y del consumidor |

## Preflight (CA-1)

El protocolo fija tres gates propios de OpenCode (servidor, feature flag,
permiso) mas la verificacion de frescura. Este piloto los evalua todos, no se
detiene en el primero porque **ninguno fallo**:

| # | Gate | Resultado |
|---|---|---|
| 1 | Servidor C# disponible (seccion `lsp` habilitada + .NET SDK detectado) | **pasa** (verificado con invocacion real de la tool, no solo con el log de registro) |
| 2 | Feature flag `OPENCODE_EXPERIMENTAL_LSP_TOOL=true` | **pasa** |
| 3 | Permiso `lsp: allow` | **pasa** |
| 4 | Frescura de las respuestas semanticas tras una edicion | **no concluyente** -- la consulta de verificacion no respondio en 10m48s y se aborto (ver abajo) |

### Entorno verificado

| Item | Valor | Como se verifico |
|---|---|---|
| Fecha | 2026-09-07 | -- |
| OpenCode | `1.18.29` | `opencode --version` |
| .NET SDK | `10.0.201` | `dotnet --version` (>= la version que el servidor `csharp` built-in de OpenCode requiere detectar, ver **[1]**) |
| Modelo de las consultas de control | `openai/gpt-5.4-mini` | unico proveedor con credenciales OAuth activas en este entorno (`opencode auth list` -> solo `OpenAI`); no hay Anthropic configurado, asi que este piloto **no** usa el mismo proveedor/modelo que #979 -- el protocolo no lo exige (compara texto-vs-LSP dentro de OpenCode, nunca cifras absolutas contra Claude Code) |
| Modelo de la etapa que redacta este reporte | `sonnet` (alias del frontmatter de la etapa del pipeline interno) | -- |
| `opencode.json` de Mefisto (raiz del repo) | solo `{"$schema": "..."}`, sin seccion `lsp` ni `permission` | lectura directa del archivo -- confirma que el repo de Mefisto **no** trae el mecanismo LSP habilitado por defecto, ni para su propio dogfooding interno |
| SHA del consumidor | `21757bd2d6c0b261443158c4aec25e83e7f6597c` | reverificado hoy con `gh api repos/augusto-romero-arango/Bitakora.ControlAsistencia/commits/21757bd2d6c0b261443158c4aec25e83e7f6597c --jq .sha`: sigue siendo alcanzable, mismo valor que fijo #976 |
| Baseline textual sin MCP de Rider (#978) | **mergeado y verificado** | `grep -rn "jetbrains\|Rider" agents/ commands/ skills/` no devuelve ninguna declaracion `mcp__jetbrains__*` ni prescripcion de ese servidor (el unico hit es un patron de `.gitignore` generado por `infra-base-scaffolder`) |

### Gate 1 -- servidor C#: config minima y limitacion de la CLI de debug

Con `"lsp": true` en un `opencode.jsonc` de prueba (sandbox `/tmp`, fuera del
arbol de Mefisto y del consumidor) y un proyecto `dotnet new console` minimo,
el log de arranque (`--print-logs --log-level DEBUG`) confirma que OpenCode
registra `csharp` entre los servidores habilitados:

```
message="enabled LSP servers" serverIds="... csharp ..."
```

Sin esa seccion (config con solo `$schema`, la que trae Mefisto hoy), esa
linea de log **no aparece en absoluto** -- el subsistema LSP queda inactivo
por completo, tal como documenta la fuente oficial **[1]**: "LSP is disabled
by default".

**Limitacion registrada, no omitida**: los comandos `opencode debug lsp
document-symbols/symbols/diagnostics` devolvieron `[]`/`{}` incluso con
`csharp` registrado -- se investigo con logs `DEBUG` y la traza muestra que
esos comandos crean una instancia y la destruyen (`disposing instance`) en el
mismo milisegundo del `init`, sin tiempo para que el servidor real spawee e
inicialice. Esa CLI de debug **no es un proxy fiable del gate 1** en este
entorno; el gate 1 solo quedo confirmado con la ruta real que usa el pipeline
(la tool `lsp` invocada dentro de una sesion de `opencode run`, ver abajo).

### Gates 2 y 3 -- feature flag y permiso: confirmados con invocacion real de la tool

Con `OPENCODE_EXPERIMENTAL_LSP_TOOL=true`, `"lsp": true` y
`"permission": {"lsp": "allow", ...}` (el resto de permisos en `deny` para
acotar la sesion a una consulta de solo lectura), una sesion real de
`opencode run` sobre el proyecto de prueba (`Saludador.Saludar`) invoco la
tool `lsp` con `operation: documentSymbol` y devolvio los simbolos reales del
archivo:

```
OcLspProbe.Program
Main()
OcLspProbe.Saludador
Saludar(string nombre)
```

Esto es evidencia mas fuerte que un log de registro o que la respuesta de un
modelo sobre si mismo: son datos semanticos correctos, verificables contra el
contenido real del archivo, producidos por la ruta exacta (`opencode run`,
tool `lsp`) que un agente real usaria.

| Consulta | Prompt (resumen) | Resultado | Sesion | Duracion (primer->ultimo evento) | Tokens (in/out/reasoning) | Costo USD |
|---|---|---|---|---|---|---|
| C1 | enumerar los nombres exactos de las tools disponibles (sin invocar ninguna) | **abortada**: sin respuesta tras 16 min, se aborto el proceso; se registra como consulta excesiva, no como evidencia de ausencia | -- | > 16 min (abortada) | -- | -- |
| C2 | responder SI/NO a si existe una tool llamada exactamente `lsp` | `SI` | `ses_f840fc201ffe3iKO6600lybURR` | 2419 ms | 3710 / 7 / 36 | 0 |
| C3 (gate 1+2+3 combinados) | usar la tool `lsp` para pedir los document symbols de `Program.cs` y reportar solo la lista | invoco `glob` y luego `lsp(documentSymbol)`; devolvio los 4 simbolos reales listados arriba | `ses_f8406e588ffea8CJ0WCrc8bzSC` | 7749 ms | 3738+267+765 / 49+45+28 / 43+26+69 (tres pasos) | 0 (los tres pasos) |

Un costo `0` USD es el costo de suscripcion/OAuth de este entorno, no ausencia
de consumo: los tokens reales quedan arriba (issue #976, formato de
evidencia).

`C1` es la unica consulta que no llego a completarse: se registra como dato
(una consulta de control puede quedar "excesiva o desincronizada" segun CA-4
de este mismo issue) y no invalida `C2`/`C3`, que corrieron en sesiones
independientes y si completaron con evidencia reproducible.

### Gate 4 -- frescura tras una edicion (no concluyente)

Sobre la misma sesion de `C3` (`ses_f8406e588ffea8CJ0WCrc8bzSC`), se edito
`Program.cs` fuera de la sesion (se agrego el metodo `Despedir`) y se pidio
`--session <id>` que repitiera la consulta de document symbols para confirmar
si la respuesta reflejaba la edicion. Ese intento **no respondio en 10 minutos
48 segundos** y se aborto (proceso con solo 8.19s de CPU acumulado en ese
lapso, seal de espera de red/API, no de computo local). No hay evidencia de
que la sincronizacion funcione ni de que falle: el gate 4 queda sin verificar
en este piloto.

Esto contrasta con `C3` (mismo modelo, sesion nueva, sin `--session`), que
completo en 7.7 segundos. La diferencia sugiere que continuar una sesion con
`--session` tras una edicion externa al archivo puede ser sustancialmente mas
lento (o quedarse colgado) en este entorno -- dato operativo relevante para
quien ejecute el corpus real: medir el wall-clock de continuar sesiones antes
de asumir que es comparable a una sesion nueva.

## Casos, brazos y formato de evidencia (CA-2, CA-3, CA-4)

Los tres casos de #976 (`planner` / analisis de impacto, `implementer` /
cambio sobre test rojo, `reviewer` / revision de diff transversal) quedan sin
ejecutar. No es porque el mecanismo LSP este roto -- el preflight de arriba lo
confirma disponible y funcional -- sino porque correr un caso real exige:

- Un worktree de `Bitakora.ControlAsistencia` en el SHA congelado, con
  simbolos reales (`multiples consumidores conocidos`, un test rojo real, un
  diff con impacto transversal real) que este piloto no tiene ni puede generar
  desde el sandbox de la etapa de tooling de Mefisto.
- Materializar cada agente publicado bajo prueba (`planner`, `implementer`,
  `reviewer`) como una configuracion temporal equivalente de OpenCode (CA-2):
  hoy no existe un generador automatico de ese lado -- el que existe
  (`generate-internal-adapters.sh`) opera sobre agentes **internos** de
  Mefisto, no sobre los publicados que un consumidor ejecuta -- asi que
  escribir esa equivalencia es trabajo manual de quien opere el piloto sobre
  el consumidor.
- Tres repeticiones por caso, contrabalanceo de orden y worktrees limpios: un
  volumen de ejecucion (18 pares, 36 corridas) muy por encima del turno
  "activo" de operador de 30 minutos que fija la revision de complejidad del
  issue, y del alcance de una etapa headless no interactiva.

La nota tecnica del issue es explicita en esto: *"La ejecucion y exportacion
de evidencia desde el consumidor son pasos humanos; el PR de Mefisto solo
incorpora el reporte sanitizado."* Este documento es ese reporte -- documenta
que el mecanismo esta listo para usarse, deja la receta de configuracion
verificada (arriba) y dos limitaciones concretas (CLI de debug no fiable como
proxy de gate 1, continuar sesion tras editar puede colgarse), pero no fabrica
pares que no se corrieron.

La tabla de evidencia queda con la cabecera comun que #976 fija -- para que
#981 la concatene sin normalizar nada a mano -- y **sin ninguna fila**:

| caso | rol | brazo | pos | rep | tokens_in | tokens_out | costo | wall_clock_s | tool_calls | reintentos | build | tests | hallazgos_mayores | oraculo | cache |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|

Las cifras de las tres consultas de control de arriba **no** son filas de este
corpus: miden disponibilidad y comportamiento del mecanismo, no un caso del
experimento, y no entran en ninguna mediana.

## Conclusion por rol (CA-5)

Para los tres roles del corpus (`planner`, `implementer`, `reviewer`) el
resultado es **`no evaluable`**, siguiendo la misma regla de #976 que aplico
#979, pero por un motivo distinto: aqui el mecanismo **si** esta disponible
desde el preflight; lo que falta es la ejecucion del corpus, que es un paso
humano fuera de esta etapa.

El criterio de decision de dos pasos de #976 se aplica asi:

1. **No inferioridad de calidad**: no evaluable. Exige que el brazo LSP pase
   el mismo oraculo independiente que el brazo texto en las 3 repeticiones;
   con cero repeticiones de ningun brazo no hay nada que comparar.
2. **Beneficio neto**: no se mira, porque no hay tres repeticiones validas por
   brazo sobre las que calcular ninguna mediana.

Este resultado:

- **No se generaliza** a `test-writer`, `smoke-test-writer` ni las variantes
  de proyecciones -- #976 ya los excluye del corpus.
- **No se compara** con Claude Code (#979): ese piloto corrio su propio
  preflight sobre su propio mecanismo y llego a `no evaluable` por un gate que
  fallo (plugin/binario ausentes); este piloto llega a `no evaluable` con
  todos los gates en verde. Ambos resultados son independientes y ninguno se
  lee como superioridad de un runtime sobre otro -- eso es precisamente lo que
  el protocolo prohibe.
- **No decide adopcion de LSP** en ningun agente publicado ni presenta el
  mecanismo experimental de OpenCode como contrato portable (MEF-ADR-0050):
  esa decision es de #981, y de todas formas requeriria el corpus real.
- **Es especifico de este entorno en esta fecha**: OpenCode `1.18.29`, .NET
  SDK `10.0.201`, modelo `openai/gpt-5.4-mini`. Un piloto futuro con otro
  modelo o version de OpenCode reverifica los cuatro gates desde cero.
- **No es determinista al 100%.** La consulta `C1` (enumerar tools) no
  completo en el mismo entorno donde `C2` (pregunta cerrada) y `C3` (uso real
  de la tool) si completaron con evidencia consistente entre si. La
  triangulacion entre `C2` y `C3` -- una respuesta declarativa del modelo mas
  una invocacion real con datos semanticos verificables -- es lo que sostiene
  la conclusion de gates 2 y 3, no ninguna de las dos por si sola.

## Que sigue (backlog, no ejecutado en este piloto)

Para que un piloto OpenCode futuro deje de terminar en `no evaluable` por
ausencia de corpus:

1. Crear un worktree de `Bitakora.ControlAsistencia` en el SHA congelado
   (`21757bd2d6c0b261443158c4aec25e83e7f6597c`), uno nuevo y limpio por cada
   una de las 18 ejecuciones individuales (nunca reutilizado entre
   repeticiones).
2. Para cada rol (`planner`, `implementer`, `reviewer`), escribir la
   configuracion temporal equivalente de OpenCode: un `opencode.jsonc` local
   al worktree con `"lsp": true` y el bloque `permission` de ese rol,
   traduciendo a mano las capacidades del agente publicado correspondiente
   (`agents/*.md`) al vocabulario de 17 claves de OpenCode -- sin commitear
   nada de eso al consumidor (CA-2). No usar `generate-internal-adapters.sh`:
   ese script es para agentes internos de Mefisto, no para los publicados que
   corren sobre el consumidor.
3. Brazo texto: `OPENCODE_EXPERIMENTAL_LSP_TOOL` sin exportar y
   `permission.lsp: deny` (los dos gates cerrados, no solo uno). Brazo LSP:
   los tres gates confirmados arriba, mas la doctrina dirigida temporal del
   protocolo (preferir consulta semantica sobre textual para los simbolos
   candidatos del caso).
4. Repetir el gate 4 (frescura) **dentro de la ejecucion real de cada
   repeticion del brazo LSP**, no como sonda aislada: cuando el brazo LSP edite
   un archivo con su propia tool `edit`, la siguiente consulta semantica debe
   reflejar esa edicion antes de aceptarla como valida. Medir tambien el
   wall-clock de esa continuacion -- este piloto encontro que continuar una
   sesion con `--session` tras una edicion externa puede tardar mucho mas que
   una sesion nueva, y esa asimetria de latencia es en si misma un dato del
   experimento (columna `wall_clock_s`), no solo un problema de tooling.
5. Ejecutar los 3 casos x 3 pares con contrabalanceo de orden y llenar la
   tabla de evidencia con datos reales; exportar las trazas y traerlas
   sanitizadas a este repo en un PR de seguimiento.

Cada corrida futura reverifica los cuatro gates desde cero: la verificacion de
hoy vale para hoy y para este entorno (OpenCode `1.18.29`, .NET SDK
`10.0.201`), y no sustituye la del piloto que finalmente mida el corpus.

## Fuentes

- **[1]** "LSP" -- documentacion oficial de OpenCode: LSP deshabilitado por
  defecto; la seccion `lsp` acepta `true` (habilita todos los servidores
  built-in) o un objeto por servidor (`command`, `extensions`, `env`,
  `initialization`, `disabled`); el servidor `csharp` se activa al detectar
  archivos `.cs`/`.csx` si hay .NET SDK instalado, sin configuracion adicional.
  Verificado por fetch HTTP el 2026-09-07.
  https://opencode.ai/docs/lsp/
- **[2]** "Tools" -- documentacion oficial de OpenCode, seccion `lsp`
  (experimental): requiere `OPENCODE_EXPERIMENTAL_LSP_TOOL=true` (o el flag
  experimental global `OPENCODE_EXPERIMENTAL=true`) y el permiso
  `"permission": {"lsp": "allow"}`; expone `goToDefinition`, `findReferences`,
  `hover`, `documentSymbol`, `workspaceSymbol`, `goToImplementation`,
  `prepareCallHierarchy`, `incomingCalls`, `outgoingCalls`. Verificado por
  fetch HTTP el 2026-09-07.
  https://opencode.ai/docs/tools/
- `src/internal/contract/opencode-permissions.json` -- mapping interno
  capacidad neutral -> permisos OpenCode (issue #862); confirma el vocabulario
  de 17 claves de permiso contra el binario `1.18.29` y que hoy solo los
  agentes **internos** de Mefisto (no los publicados bajo prueba en este
  piloto) declaran `lsp: allow` via `capability_scalar.read`. Pertenece al
  lado interno y no constituye un adaptador publicado (issue #980, contexto).
- `docs/testing/lsp-experiment-protocol.md` (issue #976) -- protocolo, corpus,
  formato de evidencia y umbrales que este documento intenta ejecutar.
- `docs/testing/lsp-pilot-claude.md` (issue #979) -- piloto hermano sobre
  Claude Code; mismo protocolo, mismo SHA de consumidor, conclusion
  independiente (`no evaluable` por gate de mecanismo ausente, no por corpus
  pendiente).
- `docs/testing/opencode-dogfooding.md` (issue #874) -- precedente de reporte
  parcial con evidencia reproducible en vez de datos fabricados cuando una
  certificacion no puede completarse en el entorno disponible.
