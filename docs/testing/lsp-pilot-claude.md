# Piloto Claude Code del experimento LSP en agentes C# (issue #979)

Ejecuta, para el brazo **Claude Code** unicamente, el protocolo fijado por
`docs/testing/lsp-experiment-protocol.md` (issue #976). No compara cifras
absolutas contra OpenCode (#980); esa comparacion no existe en ningun punto
de este documento ni de la sintesis posterior (#981). El baseline textual
asume #978 ya mergeado (retira la preferencia por el MCP de Rider de
`implementer`, `projection-implementer` y `reviewer`).

## Veredicto

**NO EVALUABLE.** El preflight de disponibilidad (CA-1) falla en el primer
gate: el plugin oficial `csharp-lsp` no esta instalado en el entorno donde
corre este piloto, pese a que el marketplace que lo distribuye si esta
configurado. Sin el plugin instalado no hay tool `LSP` que declarar en
ninguna corrida `claude -p`, asi que ningun par texto-vs-LSP de los tres
casos del protocolo puede ejecutarse. Siguiendo la regla de parada del
protocolo (seccion "Preflight y reglas de parada" de #976) y CA-1 de este
issue, el piloto **termina aqui, sin fingir cifras** para ningun campo del
formato de evidencia.

| CA (#979) | Estado | Nota |
|---|---|---|
| CA-1 | pasa (preflight ejecutado; concluye `no evaluable`) | version de Claude Code, version declarada del plugin, ausencia del binario, SHA del consumidor y la consulta de control, todos documentados abajo con evidencia reproducible |
| CA-2 | no evaluable | cero pares corridos: no hay tool LSP que exponer en el brazo LSP de ningun caso |
| CA-3 | no evaluable | no hay filas de evidencia que reportar; la tabla de metricas del protocolo queda vacia por diseno, no rellenada con datos ficticios |
| CA-4 | no evaluable | no hay edicion dentro de un brazo LSP cuya frescura verificar |
| CA-5 | pasa (conclusion `no evaluable` para los tres roles, sin generalizar) | ver "Conclusion por rol" abajo |
| CA-6 | pasa | `changelog.d/979.added.md` creado; ningun frontmatter ni doctrina de agente cambia como consecuencia de este piloto |

## Preflight (CA-1)

### Entorno verificado

| Item | Valor | Como se verifico |
|---|---|---|
| Fecha | 2026-09-07 | -- |
| Claude Code | `2.1.263` | `claude --version` |
| Modelo de esta sesion | Sonnet 5 (`claude-sonnet-5`) | header de sistema de la sesion que ejecuta este piloto |
| Marketplace `claude-plugins-official` | configurado | `claude plugin marketplace list` -> `claude-plugins-official` (fuente `anthropics/claude-plugins-official`) |
| Plugin `csharp-lsp` | **no instalado** | `claude plugin list` no muestra ninguna entrada `csharp-lsp@claude-plugins-official`; el unico plugin de ese marketplace instalado es `azure@claude-plugins-official` (`Status: disabled`) |
| Version declarada de `csharp-lsp` | `1.0.0` | `marketplace.json` del marketplace oficial, `plugins[] | select(name == "csharp-lsp")` -- `{"name":"csharp-lsp","version":"1.0.0","source":"./plugins/csharp-lsp", ...}`, coincide con **[1]** |
| Binario `csharp-ls` | **no encontrado** | `which csharp-ls` -> sin resultado; el plugin instala el servidor via `dotnet tool install --global csharp-ls` o Homebrew **[2]**, ninguno de los dos se ejecuto |
| .NET SDK | `10.0.201` (>= 6.0 requerido por el plugin) | `dotnet --version` -- el SDK no es el gate que falla |
| SHA del consumidor | `21757bd2d6c0b261443158c4aec25e83e7f6597c` | reverificado hoy con `gh api repos/augusto-romero-arango/Bitakora.ControlAsistencia/commits/21757bd2d6c0b261443158c4aec25e83e7f6597c --jq .sha`: sigue siendo alcanzable, mismo valor que fijo #976 |

### Consulta de control (`claude -p` headless)

El protocolo exige confirmar disponibilidad con una consulta pequeña dentro
de `claude -p`, no solo verificar la instalacion (los reportes **[3]**/**[4]**
del tracker distinguen interactivo de headless). Ese paso queda **subsumido**
por el resultado anterior: sin el plugin instalado, ninguna sesion `claude -p`
de este entorno declara la tool `LSP` en su configuracion de herramientas --
no hay nada que consultar todavia. Ejecutar la consulta de control solo tiene
sentido una vez que el gate de instalacion pase; hacerlo ahora produciria un
"LSP no respondio" indistinguible de "LSP nunca estuvo cargado", que es
precisamente la ambiguedad que el preflight de dos gates separados (CA-1)
existe para evitar.

### Por que este piloto no instala el plugin por su cuenta

Instalar `csharp-lsp@claude-plugins-official` cambia configuracion de plugins
a nivel de usuario/maquina (`claude plugin install`), fuera del arbol del
repo y fuera del alcance de esta corrida (una etapa headless del pipeline
publicado de tooling, sin turno humano que confirme un cambio de entorno
compartido). Con el plugin no disponible en el entorno donde el pipeline
publicado corre hoy, la respuesta correcta del protocolo es exactamente esta:
`no evaluable`, no una instalacion improvisada a mitad de una corrida
documentada como medicion.

## Casos, brazos y formato de evidencia (CA-2, CA-3, CA-4)

Los tres casos de #976 (`planner` / analisis de impacto, `implementer` /
cambio sobre test rojo, `reviewer` / revision de diff transversal) quedan sin
ejecutar. La tabla de evidencia que #976 fija con cabecera comun

```
caso | rol | brazo | pos | rep | tokens_in | tokens_out | costo | wall_clock_s | tool_calls | reintentos | build | tests | hallazgos_mayores | oraculo | cache
```

no tiene filas en este documento: no existe ninguna repeticion del brazo LSP
que reportar (el brazo texto tampoco se corrio de forma aislada, porque un
par requiere ambos brazos y el protocolo no acepta pares incompletos). Ningun
valor de esta tabla se rellena por extrapolacion, promedio ni suposicion.

La verificacion de frescura tras una edicion (CA-4 de este issue, seccion
"Preflight" de #976) tampoco aplica: requiere una edicion real dentro de un
brazo LSP en curso, y ese brazo nunca arranco.

## Conclusion por rol (CA-5)

Para los tres roles del corpus (`planner`, `implementer`, `reviewer`) el
resultado es **`no evaluable`**, siguiendo literalmente la regla de #976:
*"Si el reemplazo no es posible (el mecanismo LSP no esta disponible de forma
estable), el rol concluye `no evaluable` y queda fuera de la sintesis de
#981"*. Aqui el mecanismo LSP no esta disponible desde el primer gate, antes
de cualquier repeticion, asi que los tres roles heredan la misma conclusion
sin necesidad de evaluarlos por separado.

Este resultado:

- **No se generaliza** a `test-writer`, `smoke-test-writer` ni las variantes
  de proyecciones (`projection-test-writer`, `projections-scaffolder`,
  `projection-implementer` en su rol read-side) -- #976 ya los excluye del
  corpus y este piloto no aporta evidencia a favor ni en contra para ellos.
- **No se compara** con OpenCode (#980): ese piloto corre su propio preflight
  sobre su propio mecanismo (servidor C# + feature flag + permiso) y llega a
  su propia conclusion, independiente de esta.
- **No decide adopcion de LSP** en ningun agente publicado: esa decision es
  de #981, y de todas formas requeriria evidencia favorable que este piloto
  no produjo.
- **Es especifico de este entorno en esta fecha**, no una afirmacion sobre el
  plugin `csharp-lsp` en abstracto: el plugin existe, esta versionado
  (`1.0.0`) y documentado por el marketplace oficial **[1]**; lo que falta es
  la instalacion local del binario que respalda, no evidencia de que el
  plugin sea inviable en principio.

## Que sigue (backlog, no ejecutado en este piloto)

Para que un piloto Claude Code futuro deje de terminar en `no evaluable`:

1. Instalar el binario: `dotnet tool install --global csharp-ls` (o
   `brew install csharp-ls` en macOS) **[2]**.
2. Instalar y habilitar el plugin: `claude plugin install
   csharp-lsp@claude-plugins-official`, y reiniciar la sesion de Claude Code
   para que el plugin cargue (los plugins se resuelven al arrancar la
   sesion, no en caliente).
3. Repetir el preflight de este documento -- version de `csharp-ls` resuelta
   en tiempo de ejecucion, consulta de control dentro de `claude -p` headless
   (incluidos los subagentes que invoque cada etapa, que es donde **[3]**
   reporta la poda) y verificacion de frescura tras una edicion -- **antes**
   de contar cualquier par como valido.
4. Solo con los cuatro gates del preflight en verde, ejecutar los 3 casos x 3
   pares que fija #976, con worktrees limpios del SHA congelado y
   contrabalanceo de orden, y llenar la tabla de evidencia con datos reales.

Este piloto no repite instalaciones a mitad de camino ni sustituye la
verificacion futura por la de hoy: cada corrida reverifica los cuatro gates
desde cero, tal como exige el preflight del protocolo.

## Fuentes

- **[1]** `anthropics/claude-plugins-official`, `.claude-plugin/marketplace.json`
  -- entrada `csharp-lsp`, version `1.0.0`, fuente `./plugins/csharp-lsp`.
  Verificado por fetch HTTP el 2026-09-07.
  https://github.com/anthropics/claude-plugins-official
- **[2]** `anthropics/claude-plugins-official`, `plugins/csharp-lsp/README.md`
  -- instalacion del servidor via `dotnet tool install --global csharp-ls` o
  Homebrew, requisito de .NET SDK 6.0+. Verificado por fetch HTTP el
  2026-09-07.
  https://github.com/anthropics/claude-plugins-official/tree/main/plugins/csharp-lsp
- **[3]** `anthropics/claude-code#84125` (abierto) -- "LSP tool is pruned from
  all subagent tool sets in interactive sessions (present in the parent, and
  in subagents under -p)". Senal de riesgo de terceros, no fuente normativa;
  citada aqui porque fija por que la consulta de control (paso 3 del
  backlog) debe correr dentro de las etapas headless reales del pipeline,
  subagentes incluidos, y no solo en la sesion padre.
  https://github.com/anthropics/claude-code/issues/84125
- **[4]** `anthropics/claude-code#79744` (abierto) -- "Interactive LSP client
  never sends didChange after Edit-tool writes -- server buffers stay frozen
  at first-query content (headless `-p` syncs correctly)". Misma naturaleza:
  senal de riesgo, no normativa; motiva la verificacion de frescura del paso
  3 del backlog en vez de asumirla.
  https://github.com/anthropics/claude-code/issues/79744
- `docs/testing/lsp-experiment-protocol.md` (issue #976) -- protocolo, corpus,
  formato de evidencia y umbrales que este documento intenta ejecutar.
- `docs/testing/opencode-dogfooding.md` (issue #874) -- precedente de reporte
  parcial con evidencia reproducible en vez de datos fabricados cuando una
  certificacion no puede completarse en el entorno disponible.
