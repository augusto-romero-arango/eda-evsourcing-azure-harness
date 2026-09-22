# Protocolo de certificacion TDD multi-runtime (`/mefisto:implement`)

Este protocolo define, sin ejecutarla, la certificacion reproducible del
pipeline `/mefisto:implement` (`scripts/tdd-pipeline.sh`) sobre ambos runtimes,
apoyado en el corte ya certificado de `/mefisto:tooling`
([`opencode-consumer-cutover.md`](./opencode-consumer-cutover.md), veredicto
`PASA` de #1066). Ese corte demostro instalacion, identidad e infraestructura
de discovery compartidas entre Claude Code y OpenCode; este documento no las
repite, las reutiliza como prerrequisito y agrega la superficie propia de TDD:
dos rutas de agentes (write-side y `tipo:projection`), fase roja/verde, Stage
2b condicional, coverage gate (Stage 4) y clausura del ciclo.

Redactar este documento no ejecuta ninguna corrida ni declara `/mefisto:implement`
soportado bajo ambos runtimes. Bloquea el veredicto final #1411 hasta que las
corridas write-side y read-side descritas aqui se ejecuten y su evidencia se
reconcilie, igual que #1066 reconcilio #1180 y #1181 para `/mefisto:tooling`.

No sustituye a [`opencode-dogfooding.md`](./opencode-dogfooding.md), que
certifica exclusivamente el dogfooding interno historico y no se modifica por
este issue.

## Invariantes y prerrequisitos (CA-1)

Este protocolo reutiliza integramente el consumidor privado y persistente
`augusto-romero-arango/mefisto-consumer-certification` ya usado por #1180/#1181
y la mecanica de instalacion certificada en "Instalacion Claude Code a scope de
usuario" e "Instalacion y proyeccion OpenCode" de
`opencode-consumer-cutover.md`. No se repite esa mecanica aqui; se fija el
invariante que las cuatro corridas de este protocolo comparten con ella:

- El baseline es el mismo **consumidor completo** de #1180 (onboarding `LISTO`,
  CI OIDC verde, Azure dedicado operativo), en un estado limpio verificado por
  `git status --porcelain=v1` antes y despues de cada corrida.
- Antes de cualquiera de las cuatro corridas existe **una unica release
  candidata** instalada en ambos runtimes, verificada por
  `diagnose-installation-identity.sh` con `status=aligned` y el mismo
  `<version>`/`<commit-fuente>` en Claude y OpenCode. Una identidad distinta de
  `aligned`, o distinta entre las cuatro corridas, bloquea el protocolo antes de
  crear ningun fixture.
- Queda **prohibido** instalar o referenciar Mefisto desde un checkout, un
  worktree, un enlace simbolico o una ruta absoluta del repositorio de Mefisto:
  la unica instalacion valida es la release publicada (marketplace para Claude
  Code, `install.sh install <version>` con checksum verificado para OpenCode),
  igual que exige "Preflight del consumidor ajeno" en el corte anterior.
- Registra los mismos parametros inmutables de esa tabla
  (`<tag-certificable>`, `<version>`, `<commit-fuente>`, `<checksum-opencode>`,
  `<sha-baseline-inicial>`/`<sha-baseline-final>`, versiones de CLI) antes de
  crear los cuatro issues fixture.

La superficie de discovery adicional que este protocolo ejercita, no cubierta
por #1180, es: el comando `/mefisto:implement`, los seis agentes de TDD
(`test-writer`, `implementer`, `smoke-test-writer`, `reviewer`,
`projection-test-writer`, `projection-implementer`), el Agent Skill
`projections` que los agentes de la ruta read-side precargan via `skills:`
-- su `SKILL.md` y los recursos de Nivel 3 `modelos-marten.md`,
`read-apis.md`, `naming.md` y `config-test.md` (MEF-ADR-0033) -- y
`scripts/tdd-pipeline.sh` como entrypoint distinto de `tooling-pipeline.sh`.
El resto de la mecanica de instalacion, identidad y proyeccion es identica a
la ya certificada y no se vuelve a descubrir.

## Fixtures write-side/read-side (CA-2)

Se crean **cuatro issues fixture independientes**, todos desde el planner
**publicado** del consumidor (nunca desde el planner interno de Mefisto ni con
`gh -R`, MEF-ADR-0019), todos con labels `dom:certificacion` y `estado:listo`
explicitos, y ninguno depende de que otro PR fixture se fusione:

| Fixture | Runtime | `tipo:` | Agentes forzados |
|---|---|---|---|
| write-side Claude | Claude Code | `tipo:feature` | `test-writer` -> `implementer` -> `smoke-test-writer` -> `reviewer` |
| write-side OpenCode | OpenCode | `tipo:feature` | `test-writer` -> `implementer` -> `smoke-test-writer` -> `reviewer` |
| read-side Claude | Claude Code | `tipo:projection` | `projection-test-writer` -> `projection-implementer` -> `smoke-test-writer` -> `reviewer` |
| read-side OpenCode | OpenCode | `tipo:projection` | `projection-test-writer` -> `projection-implementer` -> `smoke-test-writer` -> `reviewer` |

Los cuatro se crean **abiertos e independientes**, los cuatro parten del mismo
`<sha-baseline-inicial>` -- el baseline se restaura a ese SHA antes de cada una
de las cuatro corridas, que es lo que hace que ninguna dependa del PR de otra --
y cada uno cumple el Definition of Ready de la columna correspondiente
(`docs/adr/mef-adr-0011-definition-of-ready.md`): CAs deterministas, seccion
`## Modelo de eventos` (write-side) o `## Necesidad de lectura` +
`## Endpoints / rutas` + `## Capas de test esperadas` (read-side), y `##
Dependencias` declarando `Ninguna`. La validacion programatica de
`/mefisto:implement` (seccion "Validacion en `/implement`" del mismo ADR) es la
misma que corre en produccion; este protocolo no la relaja ni la duplica.

### Eleccion del dominio certificable

Antes de redactar los cuatro fixtures se registra `<dominio-certificable>`:
un dominio ya scaffoldeado del baseline con Function App existente y su
proyecto `tests/<namespacePrefix>.<dominio-certificable>.SmokeTests` ya creado.
`<namespacePrefix>` es el valor de la clave homonima de
`.mefisto/harness.config.json` del consumidor -- el mismo que `tdd-pipeline.sh`
lee como `HARNESS_NAMESPACE_PREFIX` para resolver el proyecto SmokeTests del
dominio en Stage 2b, de modo que el placeholder de este protocolo y la deteccion
real del pipeline no pueden divergir.

Esa eleccion es la que deja **Stage 0 explicitamente fuera de alcance** (CA-3):
ninguna de las cuatro corridas ofrece ni acepta scaffold de dominio, porque el
directorio `src/<namespacePrefix>.<dominio-certificable>/` ya existe antes de
lanzar `/mefisto:implement`.

La corrida write-side registra ademas `<aggregate-certificable>` y
`<comando-certificable>`: un aggregate del mismo `<dominio-certificable>` y uno
de sus comandos HTTP ya existentes, elegidos porque el campo sobre el que se
agrega la regla de validacion ya viaja en ese comando.

La corrida read-side elige ademas `<evento-certificable>`/`<vista-certificable>`:
un evento y su read model **ya materializados en el baseline**, nunca el
resultado del PR write-side (que este protocolo descarta sin merge, seccion
"Fail-closed y limpieza" mas abajo). Esto evita que la corrida read-side
dependa de una corrida distinta para tener contenido que leer.

### Templates de fixture

Cada template deja placeholders para los valores ya registrados arriba
(`<namespacePrefix>`, `<dominio-certificable>`, `<aggregate-certificable>`,
`<comando-certificable>` en write-side; `<evento-certificable>`,
`<vista-certificable>` en read-side), para la identidad de la release
(`<tag-certificable>`, `<version>`, `<commit-fuente>`), para `<run-id>` (mismo
formato `YYYYMMDD-HHMMSS-<tag-certificable>` del corte anterior) y para el
runtime de la fila. Las cuatro corridas usan la misma forma,
solo el `tipo:`, el runtime y el contenido determinista cambian.

#### Template: write-side (Claude u OpenCode)

````markdown
# Certificar TDD write-side bajo <runtime> (<run-id>)

## Contexto

Certificar `/mefisto:implement` (`tipo:feature`) sobre la release
`<tag-certificable>` (`<version>`, commit fuente `<commit-fuente>`) desde una
instalacion publicada real en este consumidor.

## Modelo de eventos

El aggregate `<aggregate-certificable>` y el comando
`<comando-certificable>` ya existen en `<dominio-certificable>`. Este fixture
NO crea aggregate, comando ni evento nuevos: agrega una regla de validacion
determinista y acotada sobre un campo existente de `<comando-certificable>`
(por ejemplo, un rango o formato adicional) que hoy no esta cubierta por
ningun test.

`<comando-certificable>` ya expone su endpoint HTTP y este fixture no lo
introduce ni lo modifica: conserva verbo, ruta y codigo de exito sin cambio,
asi que la fila "Contrato HTTP del comando" del DoR queda *No aplica*. Esta
constancia va aqui, dentro de `## Modelo de eventos`, y no bajo un encabezado
propio: MEF-ADR-0011 fija que esa fila es la unica de la tabla que no nombra
una seccion del body.

## Criterios de aceptacion

- CA-1: existe exactamente un test rojo nuevo que ejercita la regla de
  validacion descrita, sobre el aggregate `<aggregate-certificable>`.
- CA-2: la implementacion hace pasar ese test sin modificar ningun test
  existente ni el contrato HTTP del comando.
- CA-3: el diff toca al menos un archivo bajo
  `src/<namespacePrefix>.<dominio-certificable>/.../Function/`, de modo que
  Stage 2b se ejecuta contra el proyecto SmokeTests ya existente del dominio.
- CA-4: `tests/<namespacePrefix>.<dominio-certificable>.SmokeTests` gana un
  caso nuevo para la regla de validacion.
- CA-5: todos los tests (unitarios y de compilacion de smoke tests) pasan al
  cierre del pipeline.

## Impacto en archivos

- Modifica: el aggregate/handler de `<comando-certificable>` y su Function en
  `src/<namespacePrefix>.<dominio-certificable>/`.
- Modifica: los tests correspondientes en
  `tests/<namespacePrefix>.<dominio-certificable>.Tests/` y en el proyecto
  SmokeTests del dominio.
- No crea proyectos nuevos ni toca otro dominio.

## Dependencias

- Ninguna.
````

#### Template: read-side (Claude u OpenCode)

````markdown
# Certificar TDD read-side bajo <runtime> (<run-id>)

## Contexto

Certificar `/mefisto:implement` (`tipo:projection`) sobre la release
`<tag-certificable>` (`<version>`, commit fuente `<commit-fuente>`) desde una
instalacion publicada real en este consumidor.

## Necesidad de lectura

El evento `<evento-certificable>` y su read model `<vista-certificable>` ya
estan materializados en el baseline por el worker de proyecciones. Este
fixture agrega un campo derivado adicional a `<vista-certificable>`, calculado
a partir de datos que `<evento-certificable>` ya trae, sin registrar un evento,
aggregate ni proyeccion nuevos. Lifecycle: `Async` (sin excepcion, hereda el de
`<vista-certificable>`).

## Endpoints / rutas

La Function GET que ya expone `<vista-certificable>` conserva su ruta; el
fixture solo amplia el payload de respuesta con el campo nuevo. No se verifica
colision de nombres porque no se crea ninguna Function.

## Capas de test esperadas

- Unit tests de `Create`/`Apply` de la proyeccion `<vista-certificable>` que
  cubren el campo derivado nuevo.
- Config-test del worker sin cambios (no se agrega proyeccion ni store
  nuevos).
- Test de composicion de la Function GET que verifica el campo nuevo en la
  respuesta.

## Criterios de aceptacion

- CA-1: existe al menos un test rojo nuevo sobre `Create`/`Apply` de
  `<vista-certificable>` para el campo derivado.
- CA-2: la implementacion hace pasar ese test sin modificar tests ni el
  contrato de la Function GET existente.
- CA-3: el diff toca la carpeta de la Function GET de `<vista-certificable>`
  (patron `Obtener*/FunctionEndpoint.cs` o `Listar*/FunctionEndpoint.cs`), de
  modo que Stage 2b se ejecuta contra el proyecto SmokeTests ya existente del
  dominio.
- CA-4: `tests/<namespacePrefix>.<dominio-certificable>.SmokeTests` gana un
  caso que verifica el campo nuevo end-to-end.
- CA-5: todos los tests pasan al cierre del pipeline.

## Impacto en archivos

- Modifica: la proyeccion `<vista-certificable>` y su Function GET en
  `src/<namespacePrefix>.<dominio-certificable>/`.
- Modifica: los tests de proyeccion y el proyecto SmokeTests del dominio.
- No crea proyeccion, store ni Function nuevos.

## Dependencias

- Ninguna.
````

## Rutas de agentes forzadas y alcance del pipeline (CA-3)

Los cuatro fixtures fuerzan por diseno la ruta de agentes de su columna: el
`tipo:` del issue determina en `tdd-pipeline.sh` si `STAGE1_AGENT`/`STAGE2_AGENT`
resuelven a `test-writer`/`implementer` (write-side) o a
`projection-test-writer`/`projection-implementer` (read-side, issue #371).
`smoke-test-writer` y `reviewer` son comunes a ambas rutas.

En las cuatro corridas:

- **Stage 1 (fase roja)** debe terminar con tests que fallan por la razon
  correcta (no por error de compilacion), confirmando que el `test-writer` o
  `projection-test-writer` escribio solo tests y stubs, nunca implementacion
  real. En la ruta read-side el gate 1b admite ademas la señal `no-red`
  (`pipeline-state/no-red-signal.md`, honrada solo cuando `STAGE1_AGENT =
  projection-test-writer`), pero el camino esperado de estos dos fixtures
  sigue siendo el rojo: su template exige un test nuevo que falle sobre
  `Create`/`Apply` de `<vista-certificable>` (CA-1 del template read-side),
  asi que la fase roja es alcanzable. Una señal `no-red` solo es aceptable si
  cumple las condiciones acotadas de
  `src/published/agents/projection-test-writer.md` -- el issue no crea ni
  modifica ninguna clase de proyeccion -- y queda justificada en el archivo
  señal y en el summary del stage; sin esa justificacion es `NO PASA`, y si
  aparece en una sola de las dos corridas espejo es ademas una diferencia que
  hay que explicar.
- **Stage 2 (fase verde)** debe terminar con todos los tests pasando, sin que
  el `implementer`/`projection-implementer` haya tocado ningun archivo de
  test.
- **Stage 2b (smoke tests, condicional)** **debe ejecutarse** en las cuatro
  corridas: la eleccion de `<dominio-certificable>` (Function App existente +
  proyecto SmokeTests existente) y el CA-3 de cada template (diff que toca
  `Function/` o la Function GET) son las dos precondiciones que
  `tdd-pipeline.sh` evalua para no saltarlo (`AGENT_ST_RES=skipped` seria una
  divergencia, no un resultado aceptable de este protocolo).
- **Stage 3 (reviewer, fase refactor)** debe dejar todos los tests pasando y
  no introducir cambios funcionales fuera del alcance declarado.
- **Stage 4 (coverage gate) debe emitir un resultado** -- uno de los tres que
  `tdd-pipeline.sh` sabe producir en `AGENT_CG_RES`: `passed` (cobertura sobre
  el umbral), `gaps` (umbral no alcanzado; el gate advierte y continua, no
  aborta) o `skipped` con motivo explicito (sin `dotnet-coverage`, sin archivos
  de logica que evaluar, o medicion no concluyente). Nunca ausencia de
  registro. `AGENT_CG_RES` queda en el manifiesto de cada corrida
  independientemente del valor; `gaps` es un resultado registrable, no un fallo
  del protocolo, y solo abre divergencia si difiere entre las dos corridas
  espejo del mismo fixture sin causa atribuible a runtime/modelo.
- **Stage 0 (scaffold de dominio) queda explicitamente fuera de alcance**: la
  eleccion de `<dominio-certificable>` con Function App ya existente asegura
  que ninguna corrida ofrece ni ejecuta scaffold. Este protocolo no certifica
  la ruta de scaffold de `/mefisto:implement`.

## Lanzamiento real desde Herdr (CA-4)

Se ejecutan **dos corridas espejo**, siguiendo el patron ya probado por
#1179/#1181: una para el par write-side (Claude arriba, OpenCode abajo) y otra
para el par read-side (misma disposicion), cada una montada con
`herdr-workspace.sh <ruta-del-consumidor>` igual que en "Workspace Herdr" del
corte anterior -- identidad `aligned`, `MEFISTO_RUNTIME` y `--kind` heredados
por fila, pools de panes separados.

Desde cada pane de ejecucion se invoca directamente, sin pipeline anidado:

```text
/mefisto:implement <issue-write-side-claude>
/mefisto:implement <issue-write-side-opencode>
/mefisto:implement <issue-read-side-claude>
/mefisto:implement <issue-read-side-opencode>
```

Ninguna invocacion agrega `--variant` (no produce PR, no sirve a este gate) ni
fija proveedor o modelo: las cuatro corridas dejan que cada runtime resuelva su
perfil neutral (`fast`/`balanced`/`deep`) automaticamente, igual que la fila
Claude de #1181. Esto **se desvia deliberadamente** de la fila OpenCode del
corte anterior, que si pasaba `--models 'writer=...,reviewer=...'`: aqui la
seleccion automatica es parte de lo que se certifica, asi que fijar el modelo
enmascararia justo la diferencia de adaptador que MEF-ADR-0050 exige dejar
visible. Si una corrida no arranca sin `--models`, eso es un `NO PASA` con bug
en Mefisto, no una licencia para agregar el flag. Registra por cada stage de cada corrida: perfil neutral
solicitado, modelo efectivo, origen de la seleccion (automatica o heredada),
runtime y `<version>`/`<commit-fuente>` de la release activa. La espera de
agentes y checks de CI quedan fuera de la estimacion activa de quien ejecuta el
protocolo, igual que documenta la nota tecnica del issue.

Cada una de las cuatro invocaciones debe producir un **PR real**, con
`Closes #<issue-correspondiente>`, cambios limitados exactamente al alcance
declarado en su template (los archivos de `## Impacto en archivos`, nunca
otro dominio ni archivos del propio Mefisto) y el comentario de cierre del
pipeline con los summaries de cada stage.

## Manifiesto de evidencia sanitizado (CA-5)

Por cada una de las cuatro corridas se preserva un manifiesto redactado y
correlacionado por issue/stage/session, con el mismo regimen de redaccion que
"Manifiesto de evidencia y redaccion" y sus centinelas en
`opencode-consumer-cutover.md` (reutilizados sin modificacion). Contiene:

| Campo | Contenido |
|---|---|
| Identidad | issue, PR, `<sha-baseline-inicial>`/`<sha-baseline-final>` de esa corrida, `<tag-certificable>`, `<version>`, `<commit-fuente>` |
| Ventana temporal | inicio/fin de la corrida completa y de cada stage, con zona horaria |
| Argv | invocacion exacta de `/mefisto:implement <issue>` sin variables ni valores sensibles |
| Identidad de ejecucion | runtime, perfil neutral por stage, modelo efectivo/origen, session id (hash) |
| Stages y gates | resultado de Stage 1/2/2b/3/4 con el vocabulario real del pipeline (`passed`/`blocked`/`failed` en 1/2/3, `passed`/`skipped` + motivo en 2b, `passed`/`gaps`/`skipped` + motivo en 4), explicitamente marcando Stage 0 como no ejecutado |
| Checks | conclusiones de los checks requeridos del PR, o `NO_APLICAN` con el motivo (igual criterio que #1181 cuando el workflow no cubre las rutas tocadas) |
| Summaries | los summaries de cada agente copiados al cuerpo del PR |
| Streams y logs | streams neutrales redactados por stage, `events.log` y `pipeline-history.jsonl` correlacionados por issue/stage/session |
| Metricas | las de `compute_stage_metrics` por stage, ya cosechadas por `tdd-pipeline.sh` |
| Veredicto | pasa/falla/bloqueado de esa corrida individual |

La evidencia versionada conserva unicamente indices, URLs y veredictos
(equivalente al "Expediente minimo" del corte anterior); prompts, system
prompts, salida raw, `stderr`, inputs de herramientas y transcripts completos
de sesion quedan **fuera** de cualquier artefacto versionado o adjunto
publico, conforme al mismo catalogo de centinelas (`prompt`, `raw`, `stderr`,
`tool_input`, cabeceras de auth, `auth.json`/credentials, tokens `Bearer`/`sk-`)
ya definido en `opencode-consumer-cutover.md`. No se define un catalogo nuevo
de centinelas para este protocolo: se reutiliza el existente sin variacion.

## Fail-closed y limpieza (CA-6)

La certificacion es fail-closed, con el mismo regimen que "Veredicto, fallos y
limpieza" del corte anterior, extendido a las cuatro corridas:

- **Cualquier stage omitido inesperadamente** (por ejemplo, Stage 2b saltado
  en una corrida donde el diff si toca `Function/`, o Stage 4 sin registro)
  produce `NO PASA` para esa corrida.
- **Identidad divergente** entre las cuatro corridas (version, commit fuente o
  estado distinto de `aligned` en cualquier punto) produce `NO PASA` para todo
  el protocolo, no solo para la corrida afectada.
- **Un recurso inaccesible** (issue, PR, check, log o sesion no consultable)
  se marca `BLOQUEADO`, nunca se completa por inferencia.
- **Un recurso de doctrina ausente** en un runtime -- el Agent Skill
  `projections`, uno de sus recursos de Nivel 3 o un ADR citado, no visible
  para el agente que lo precarga -- produce `NO PASA` para la corrida
  afectada; nunca se continua con el alcance reducido.
- **Una diferencia no explicada** entre corridas espejo (write-side
  Claude/OpenCode o read-side Claude/OpenCode) que no sea atribuible a
  runtime/modelo -- por ejemplo, una ruta de agentes distinta a la forzada por
  su `tipo:` -- produce `NO PASA`.

Cualquiera de estos casos crea un issue `tipo:bug` en Mefisto, enlaza la
evidencia sanitizada de la corrida afectada y se declara dependencia del
veredicto final #1411, que permanece bloqueado hasta su cierre.

Tras capturar la evidencia (haya `PASA` o `NO PASA`), la limpieza es
obligatoria y corre igual en ambos casos:

1. Cierra los **cuatro PRs sin merge** y elimina sus ramas remotas.
2. Cierra los **cuatro issues fixture** como `not planned` desde el consumidor,
   con un comentario que enlace la certificacion.
3. Retira los cuatro worktrees de las corridas y comprueba que no queda
   ninguno.
4. Restaura el baseline y comprueba que `<sha-baseline-final>` coincide
   exactamente con `<sha-baseline-inicial>` y que el arbol queda limpio.
5. Restaura la instalacion Claude/OpenCode previa si alguna corrida cambio la
   release activa, conservando en el manifiesto los punteros/version previos
   para poder verificar esa restauracion.

La limpieza es idempotente: repetirla sobre PR/issue ya cerrados, ramas
ausentes o un arbol ya restaurado no altera el resultado. Este protocolo no
certifica ninguna otra capacidad del catalogo publicado ni migra un comando
adicional.

## Resultado write-side (#1435)

Punto de registro de la evidencia de las dos corridas write-side reales
(Claude y OpenCode) exigidas por #1435, sobre los templates de "Fixtures
write-side/read-side (CA-2)" y el lanzamiento de "Lanzamiento real desde Herdr
(CA-4)". No redefine el protocolo: fija el formato con el que se consigna su
resultado, identico al de "### Estado de la corrida" de "Certificacion de
instalacion y discovery (#1180)" y "Matriz de corridas e issues fixture
(#1181)" en `opencode-consumer-cutover.md`.

### Estado de la corrida

**EJECUTADA (2026-09-21, America/Bogota UTC-05:00) -- par write-side `PASA`.**
Sesion operada en vivo sobre el consumidor privado
`augusto-romero-arango/mefisto-consumer-certification`, run-id
`20260921-073646-v0.38.2` (intento 2). El intento 1 (run-id
`20260921-062538-v0.38.2`, fixtures #28-#31, PRs #32/#33) queda **descartado**
como evidencia de paridad: su celda write OpenCode dio `NO PASA` porque los
fixtures se crearon con el template literal de "Templates de fixture", que no
incluye `## ADRs aplicables`, seccion que `agents/implementer.md` (1b) exige y
ante cuya ausencia escribe `blockage-report.md`. El implementer OpenCode actuo
conforme a su doctrina; el de Claude se aparto de ella. Por decision humana el
intento 2 repitio las cuatro celdas sobre la misma release y el mismo baseline
con fixtures creados por el planner publicado con su doctrina completa
(incluida `## ADRs aplicables`), conservando la regla semver de
`EtiquetaRelease`, el campo derivado `IdentificadorCertificacion` y bodies
byte-identicos por par espejo. Esa es la unica desviacion frente a los
templates de este protocolo y se declara aqui para la auditoria del veredicto.

El expediente sanitizado completo vive en el consumidor, ignorado por Git, en
`.mefisto/pipeline/certification/tdd-v0.38.2/` (`coordination.md`,
`write-claude.md`, `write-opencode.md`, `sentinels.md`, `final-handoff.md`;
intento 1 en `intento-1/`). Estas tablas solo conservan indices, URLs y
veredictos, conforme a "Manifiesto de evidencia sanitizado (CA-5)".

| Campo | Valor verificado |
|---|---|
| Release e identidad | `v0.38.2` (publicada 2026-09-21T11:15:57Z), version `0.38.2`, commit fuente `6c2319c5a91aef844d5f71468ecb43d6f72a1cfe`, digest OpenCode `78eee7c04875c534d2c7c0bed4eddf77f6c8b227346bf78d5cd6bd81fdd83459` verificado por el launcher contra el `.sha256` publicado; `diagnose-installation-identity.sh` en `aligned` en ambos runtimes antes de cada celda; `pipeline-history.jsonl` registra identity `0.38.2/6c2319c5` en ambas corridas. Instalacion previa (rollback): `0.38.1` / `a48e6870` en ambos runtimes. |
| Baseline | `<sha-baseline-inicial>` = `<sha-baseline-final>` = `9f49d6a59fa96f7e5a49b0139fa27ae9c2353d35`; `main` limpio, 0/0 frente a `origin/main`, un solo worktree antes y despues de cada corrida. |
| Fixtures | [#34](https://github.com/augusto-romero-arango/mefisto-consumer-certification/issues/34) (Claude) y [#35](https://github.com/augusto-romero-arango/mefisto-consumer-certification/issues/35) (OpenCode), `tipo:feature`, `dom:certificacion`, `estado:listo`, creados por el planner publicado 0.38.2; bodies byte-identicos (sha256/12 `00cc3913a679`, 26170 bytes). |
| Discovery | Claude (tras `/reload-plugins`, cache 0.38.2) y OpenCode (release 0.38.2 proyectada; hook de arranque registra `harness=0.38.2 commit=6c2319c` en `sessions.jsonl`): `/mefisto:implement`, `test-writer`, `implementer`, `smoke-test-writer`, `reviewer` y `scripts/tdd-pipeline.sh` presentes antes de lanzar. |
| PRs | [#38](https://github.com/augusto-romero-arango/mefisto-consumer-certification/pull/38) (`Closes #34`, +51/-5, 4 archivos) y [#39](https://github.com/augusto-romero-arango/mefisto-consumer-certification/pull/39) (`Closes #35`, +52/-5, 4 archivos): mismos cuatro archivos (validator, test del validator y dos SmokeTests), dentro del alcance del fixture; summaries de cada stage en el cuerpo y comentario de cierre. |
| Stages | Ambas: Stage 0 no ejecutado; Stage 1 rojo funcional (46 tests / 1 fallido, "Fase roja confirmada (exit 2)"); Stage 2 verde tocando solo `RegistrarSolicitudCertificacionValidator.cs` (46/46 + 16/16); Stage 2b ejecutado (smoke `400` nuevo + migracion de fixtures); Stage 3 `success`; Stage 4 `passed`, gaps=0. Un unico terminal por stage. |
| Checks | `NO_APLICAN` en #38 y #39: el unico workflow del consumidor sobre `pull_request` es `infra-cd.yml`, filtrado a `infra/**`, y los fixtures no tocan `infra/`; `deploy-certificacion.yml`/`deploy-projections.yml` solo corren sobre `push` a `main` y `smoke-tests.yml` es programado/manual. `statusCheckRollup` vacio en ambos PRs. |
| Diferencias de adaptador | Modelos resueltos automaticamente, sin `--models` ni `--variant`: Claude `claude-sonnet-5` (1/2/2b, `balanced`) y `claude-opus-5` (3, `deep`); OpenCode `openai/gpt-5.6-terra` (1/2/2b) y `openai/gpt-5.6-sol` (3). Stage 3: Claude sin cambios, OpenCode refactor de anclaje estricto del patron (1+1 lineas). Duracion 10 vs 16 min. Incidente operativo no atribuible al pipeline TDD: el primer despacho OpenCode no arranco ningun stage porque `herdr-pipeline.sh` reutilizo un pane cuyo shell rechazo el comando (`zsh: bad pattern: [200~cd`); el relanzamiento fue limpio y conserva el terminal unico. |
| Centinelas | 0 coincidencias en los cuatro patrones (salida cruda/interaccion, cabeceras de auth, auth store/credenciales, tokens de portador/prefijo corto) sobre todo el expediente, incluido `intento-1/` (`sentinels.md`, 2026-09-21T08:56:30-05:00). |
| Limpieza | PRs #38/#39 (y #32/#33 del intento 1) cerrados sin merge con ramas remotas eliminadas; issues #34/#35 (y #28-#31) cerrados `not planned` con comentario que enlaza el expediente; cero worktrees de fixtures. Por decision humana se conserva 0.38.2 instalada (paso a ser la release vigente) en lugar de restaurar 0.38.1. |

| CA de #1435 | Resultado | Sintesis |
|---|---|---|
| CA-1 preflight y fixtures | PASA | `/mefisto:onboard` `LISTO` (17 OK / 0 FALTA), Azure dedicado operativo, identidad `aligned` 0.38.2/6c2319c5, baseline `9f49d6a` fijado; fixtures #34/#35 byte-identicos. |
| CA-2 discovery en Herdr | PASA | Workspace Herdr con filas `planner`/`ejecucion` por runtime y pools separados; discovery viva de ambos adaptadores antes de lanzar. |
| CA-3 corrida Claude | PASA | `/mefisto:implement 34`, sesion `20260921-075322`, 07:53:22-08:03:25; PR #38; stages 1/2/2b/3 `success`, Stage 4 `passed` gaps=0. |
| CA-4 corrida OpenCode | PASA | `/mefisto:implement 35`, sesion `20260921-080923`, 08:09:23-08:25:44; PR #39; stages 1/2/2b/3 `success`, Stage 4 `passed` gaps=0. |
| CA-5 expediente correlacionado | PASA | `write-claude.md`/`write-opencode.md` correlacionan issue/PR/stage/session (hash) con artefactos neutrales (`events.log`, logs por stage, metrics, `pipeline-history.jsonl`) identificados por sha256/12. |
| CA-6 centinelas y limpieza | PASA | Centinelas 0; limpieza ejecutada 2026-09-21T08:58:07-05:00 y baseline restaurado; intento 1 descartado y declarado arriba. |

## Resultado read-side (#1436)

Punto de registro de la evidencia de las dos corridas read-side reales
(Claude y OpenCode) exigidas por #1436, sobre los templates de "Fixtures
write-side/read-side (CA-2)" y el lanzamiento de "Lanzamiento real desde Herdr
(CA-4)". Parte del mismo `<sha-baseline-inicial>` del par write-side y nunca
del PR write-side descartado (seccion "Eleccion del dominio certificable"), y
no depende de que ese PR se fusione. Las dos corridas read-side se lanzan
secuencialmente entre si -- nunca en paralelo con el par write-side ni entre
Claude y OpenCode -- para no compartir el worker de proyecciones en vuelo
(MEF-ADR-0034), igual que fija la nota tecnica del issue. No redefine el
protocolo: fija el formato con el que se consigna su resultado, identico al de
"### Estado de la corrida" de "Resultado write-side (#1435)" arriba y de
"Certificacion de instalacion y discovery (#1180)"/"Matriz de corridas e
issues fixture (#1181)" en `opencode-consumer-cutover.md`.

### Estado de la corrida

**EJECUTADA (2026-09-21, America/Bogota UTC-05:00) -- par read-side `PASA`.**
Mismo run-id (`20260921-073646-v0.38.2`, intento 2), release, identidad y
baseline que el par write-side; las dos corridas read-side se lanzaron
secuencialmente, despues del par write-side y sin solaparse entre si. En el
intento 1 no llegaron a ejecutarse (fail-closed tras la celda write OpenCode,
ver "Resultado write-side (#1435)"). Expediente sanitizado en el consumidor:
`.mefisto/pipeline/certification/tdd-v0.38.2/read-claude.md` y
`read-opencode.md`.

| Campo | Valor verificado |
|---|---|
| Release e identidad | `v0.38.2`, `0.38.2`, commit fuente `6c2319c5a91aef844d5f71468ecb43d6f72a1cfe`, digest OpenCode `78eee7c04875c534d2c7c0bed4eddf77f6c8b227346bf78d5cd6bd81fdd83459`; `aligned` en ambos runtimes antes de cada celda, identica a la del par write-side. |
| Baseline | `9f49d6a59fa96f7e5a49b0139fa27ae9c2353d35` al inicio y al cierre, arbol limpio; ningun PR fixture se fusiono, asi que las corridas read-side parten del baseline y no del PR write-side. |
| Fixtures | [#36](https://github.com/augusto-romero-arango/mefisto-consumer-certification/issues/36) (Claude) y [#37](https://github.com/augusto-romero-arango/mefisto-consumer-certification/issues/37) (OpenCode), `tipo:projection`, `dom:certificacion`, `estado:listo`; bodies byte-identicos (sha256/12 `bbad87d1d822`, 30486 bytes); `<evento-certificable>` `SolicitudCertificacionRegistrada` y `<vista-certificable>` `DetalleSolicitudCertificacion` (`SingleStreamProjection` Async) ya materializados en el baseline; campo derivado `IdentificadorCertificacion` = `EtiquetaRelease@Runtime`. |
| Discovery | `/mefisto:implement`, `projection-test-writer`, `projection-implementer`, `smoke-test-writer`, `reviewer` y el Skill `projections` con `SKILL.md`, `modelos-marten.md`, `read-apis.md`, `naming.md` y `config-test.md` presentes en ambos runtimes (en OpenCode como `mefisto-projections`). |
| PRs | [#40](https://github.com/augusto-romero-arango/mefisto-consumer-certification/pull/40) (`Closes #36`, +70/-10, 5 archivos) y [#41](https://github.com/augusto-romero-arango/mefisto-consumer-certification/pull/41) (`Closes #37`, +68/-15, 5 archivos): mismos cinco archivos (proyeccion, read model, `ObtenerDetalleSolicitudCertificacion/FunctionEndpoint.cs`, test de proyeccion y smoke del GET). |
| Stages | Ambas: Stage 0 no ejecutado; Stage 1 rojo real sobre `Create` (Projections.Tests 17 / 2 fallidos, los mismos dos en ambas), sin señal `no-red`; Stage 2 verde tocando proyeccion y Function GET sin tocar tests (45/45 + 17/17); Stage 2b ejecutado sobre la Function GET; Stage 3 `success`; Stage 4 `passed`, gaps=0. Un unico terminal por stage. |
| Checks | `NO_APLICAN` en #40 y #41, mismo motivo que el par write-side. |
| Diferencias de adaptador | Mismos modelos automaticos por runtime que el par write-side. Stage 3: ambos reviewers solo compactaron comentarios (MEF-ADR-0044), en archivos distintos (Claude: endpoint, read model y test; OpenCode: proyeccion y smoke). Duracion 13 vs 14 min. Recursos del Skill `projections` visibles en ambos runtimes; sin reduccion de stages, gates ni alcance. |
| Centinelas | Cubiertas por el mismo barrido del expediente (`sentinels.md`): 0 coincidencias. |
| Limpieza | PRs #40/#41 cerrados sin merge con ramas remotas eliminadas; issues #36/#37 (y #30/#31) cerrados `not planned` desde el consumidor; cero worktrees; baseline restaurado. |

| CA de #1436 | Resultado | Sintesis |
|---|---|---|
| CA-1 preflight y fixtures secuenciales | PASA | Mismo preflight que el par write-side; fixtures #36/#37 byte-identicos, lanzados uno tras otro. |
| CA-2 discovery read-side en Herdr | PASA | Agentes de proyeccion y Skill `projections` con sus recursos de Nivel 3 visibles en ambos runtimes. |
| CA-3 corrida Claude | PASA | `/mefisto:implement 36`, sesion `20260921-082706`, 08:27:06-08:39:43; PR #40; stages 1/2/2b/3 `success`, Stage 4 `passed` gaps=0. |
| CA-4 corrida OpenCode | PASA | `/mefisto:implement 37`, sesion `20260921-084136`, 08:41:36-08:55:17; PR #41; stages 1/2/2b/3 `success`, Stage 4 `passed` gaps=0. |
| CA-5 expediente correlacionado | PASA | `read-claude.md`/`read-opencode.md` correlacionan issue/PR/stage/session (hash) con los artefactos neutrales por sha256/12. |
| CA-6 centinelas y limpieza | PASA | Centinelas 0; limpieza ejecutada 2026-09-21T08:58:07-05:00; baseline `9f49d6a` restaurado. |

## Veredicto final del corte TDD multi-runtime (#1411)

Esta seccion audita, sin repetir ejecuciones, los dos expedientes de corrida
exigidos por el protocolo de #1434: "Resultado write-side (#1435)" y
"Resultado read-side (#1436)" arriba. No redefine el protocolo ni sus
templates; solo emite el veredicto documental fail-closed conforme a la
seccion "Fail-closed y limpieza (CA-6)" del protocolo y al CA-4 de #1411.

### Estado auditado de los dos expedientes

| Expediente | Estado registrado | Celdas con evidencia real | Fixtures creados | PRs reales |
|---|---|---|---|---|
| #1435 (write-side) | `PENDIENTE DE EJECUCION` | 0/2 (Claude, OpenCode) | Ninguno | Ninguno |
| #1436 (read-side) | `PENDIENTE DE EJECUCION` | 0/2 (Claude, OpenCode) | Ninguno | Ninguno |

Ambos issues fixture-madre se cerraron como `COMPLETED` en el rastreador de
Mefisto, pero esa clausura corresponde a la redaccion del punto de registro
("Resultado write-side (#1435)"/"Resultado read-side (#1436)") descrita en sus
propios PRs (#1462, #1463) -- ninguno de los dos ejecuto la sesion en vivo que
el protocolo exige. Las tablas de identidad y de CA-1..CA-6 de ambas secciones
permanecen con todas sus celdas vacias: no registran `<sha-baseline-inicial>`,
`<tag-certificable>`, `<version>`, `<commit-fuente>`, `<checksum-opencode>`,
issue de fixture, PR, session id, stage ni check alguno.

### Identidad comun de release (CA-1 de #1411)

CA-1 exige fijar un `<sha-baseline-inicial>`, `<tag-certificable>`, `<version>`,
`<commit-fuente>` y `<checksum-opencode>` comunes a #1435 y #1436, y confirmar
identidad `aligned` en ambos runtimes con `diagnose-installation-identity.sh`.
Ninguna corrida registro ninguno de esos cinco valores, de modo que no hay
identidad que confirmar ni release que comparar entre los dos expedientes.

Esa ausencia tampoco se rellena por inferencia: reutilizar la release que
certifico `/mefisto:tooling` en #1066, leer la version del checkout de
desarrollo o derivarla del cache de plugins instalado produciria una identidad
que ninguna corrida verifico. La seccion "Invariantes y prerrequisitos (CA-1)"
del protocolo y MEF-ADR-0031 rechazan exactamente esa sustitucion, y este
veredicto la rechaza tambien.

### Matriz 2x2 auditada (CA-2 de #1411)

Sin identidad `aligned` ni corridas lanzadas, la matriz write-side/read-side x
Claude/OpenCode se audita dimension por dimension y arroja el mismo resultado
en las cuatro celdas. La columna "Esperado por el protocolo" conserva lo que
cada celda deberia haber evidenciado, para que #1464 pueda completarla sin
reconstruir el criterio.

| Dimension exigida por CA-2 | Esperado por el protocolo | write-side Claude | write-side OpenCode | read-side Claude | read-side OpenCode |
|---|---|---|---|---|---|
| Agentes efectivos | write-side: `test-writer` -> `implementer` -> `smoke-test-writer` -> `reviewer`; read-side: `projection-test-writer` -> `projection-implementer` -> `smoke-test-writer` -> `reviewer` | sin invocacion | sin invocacion | sin invocacion | sin invocacion |
| Discovery vs. invocacion | discovery listado en Herdr antes de lanzar **y** invocacion efectiva durante la corrida, distinguidos entre si | ninguno de los dos observado | ninguno de los dos observado | ninguno de los dos observado | ninguno de los dos observado |
| Acceso a conocimiento / Skill | ADRs alcanzables y, read-side, Skill `projections` con sus recursos Nivel 3 cargado y usado (MEF-ADR-0033/0034/0035) | sin evidencia | sin evidencia | sin evidencia | sin evidencia |
| Fase roja o `no-red` (Stage 1) | fase roja real; `no-red` solo con la justificacion acotada de "Rutas de agentes forzadas y alcance del pipeline (CA-3)" | stage no ejecutado | stage no ejecutado | stage no ejecutado | stage no ejecutado |
| Stage 2b | ejecutado sobre la Function del fixture, nunca `skipped` | stage no ejecutado | stage no ejecutado | stage no ejecutado | stage no ejecutado |
| Reviewer (Stage 3) | veredicto del reviewer con un unico terminal | stage no ejecutado | stage no ejecutado | stage no ejecutado | stage no ejecutado |
| Coverage gate (Stage 4) | resultado del gate consignado, sin remediacion ejercida | stage no ejecutado | stage no ejecutado | stage no ejecutado | stage no ejecutado |
| PR y checks | PR real con `Closes #<issue>` y checks requeridos verdes o `NO_APLICAN` justificado | sin issue fixture y sin PR | sin issue fixture y sin PR | sin issue fixture y sin PR | sin issue fixture y sin PR |
| Limpieza | PR cerrado sin merge, rama eliminada, issue fixture cerrado desde el consumidor, cero worktrees, baseline restaurado | nada que limpiar | nada que limpiar | nada que limpiar | nada que limpiar |

### Observabilidad (CA-3 de #1411)

No aplica: sin corridas lanzadas no existe issue/PR/session de fixture que
correlacionar, ni stages, agentes, perfiles, modelos efectivos/origen,
version, commit fuente, metricas, summaries o history que comparar entre
celdas. La comparacion de observabilidad exigida por CA-3 de #1411 no puede
ejecutarse sobre evidencia inexistente sin violar MEF-ADR-0031.

### Centinelas y limpieza

No aplica por el mismo motivo: sin evidencia persistida no hay artefactos
sobre los que correr el barrido de centinelas de "Manifiesto de evidencia y
redaccion" (`opencode-consumer-cutover.md`), y sin corridas lanzadas no hay
PRs, ramas, issues fixture ni worktrees que limpiar. Ningun centinela dio
positivo porque no hay contenido que escanear; esto no se registra como un
`PASA` de esa fila, sino como no ejecutada.

### Veredicto

**NO PASA (2026-09-17).** Las cuatro celdas de la matriz write-side/read-side
x Claude/OpenCode carecen de evidencia real. #1435 y #1436, aunque cerrados
como completados, dejaron sus secciones "Resultado write-side (#1435)" y
"Resultado read-side (#1436)" en `PENDIENTE DE EJECUCION`: sin fixtures
creados en el consumidor, sin sesiones Herdr operadas en vivo y sin PRs
reales. Fabricar una identidad, matriz u observabilidad para satisfacer CA-1
a CA-3 de #1411 sin esa operacion violaria MEF-ADR-0031; este veredicto se
sostiene sobre la ausencia constatada, no sobre datos inferidos desde el
protocolo o desde certificaciones anteriores.

Conforme al CA-4 de #1411, esta ausencia de evidencia:

- No otorga soporte parcial ni total de `/mefisto:implement` bajo ningun
  runtime ni ruta: `README.md` mantiene `/implement` fuera del alcance
  certificado en su seccion "Soporte OpenCode: alcance certificado".
- Abre el issue
  [#1464](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1464)
  (`bug`, `tipo:tooling`, `estado:listo`) como dependencia de este veredicto,
  documentando la ejecucion pendiente de las cuatro corridas reales sobre una
  release nueva.
- Exige repetir integramente el par write-side (#1435) y el par read-side
  (#1436) -- las cuatro corridas, no un subconjunto, porque ninguna se llego a
  ejecutar -- sobre la release vigente al momento de reabrir la
  certificacion, siguiendo el protocolo ya fijado por #1434 sin modificarlo.

Este `NO PASA` no contradice a "Resultado write-side (#1435)"/"Resultado
read-side (#1436)", que anticipan que "mientras no haya corrida no hay defecto
que reportar" y que #1411 "sigue bloqueado por ausencia de evidencia". Ese
razonamiento describe la ausencia de un **defecto tecnico** del harness
-- ninguna corrida fallo, porque ninguna se lanzo -- y por eso este veredicto
no es el `BLOQUEADO` de "Fail-closed y limpieza (CA-6)", que presupone una
corrida lanzada con un recurso inaccesible. El bug #1464 no reporta un fallo
observado del pipeline: rastrea la operacion en vivo faltante y hereda la
dependencia que esas dos secciones declaraban sobre #1411. Ambas quedan
intactas como punto de registro vacio; quien ejecute #1464 las completa con
evidencia real sin tocar el protocolo de #1434.

**Alcance de lo que este veredicto juzga.** Cubre unicamente las rutas
write-side y `tipo:projection` normales de `/mefisto:implement`.
`--scaffold-domain`, `--from-stage`, `--variant` y la remediacion de coverage
no ejercida quedan explicitamente fuera: no se juzgan aqui y tampoco quedaran
certificados cuando #1464 reponga la evidencia, salvo que un protocolo
posterior los incorpore. Como ninguna celda pasa, ninguna ruta de
`/mefisto:implement` queda certificada bajo Claude ni bajo OpenCode: no hay
soporte parcial que declarar, y menos aun presentarlo como completo.

Este veredicto cierra #1411: su CA-4 se cumple emitiendo `NO PASA` con causa
documentada, en vez de dejar el issue abierto indefinidamente a la espera de
una operacion en vivo que excede el alcance de un stage de escritura
automatizado -- la misma razon que dejo a #1435/#1436 en `PENDIENTE DE
EJECUCION`. `/mefisto:implement` permanece sin certificar para consumidores
publicados bajo ningun runtime hasta que el bug
[#1464](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1464)
se cierre con las cuatro corridas reales documentadas y un nuevo issue de
veredicto las reconcilie.

## Bloqueo estructural de la ejecucion automatizada (#1464)

Esta seccion registra por que el intento de resolver
[#1464](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1464)
a traves de `/mefisto:tooling` (el pipeline no-interactivo de tooling interno
de Mefisto) tampoco produjo las cuatro corridas reales que exige ese bug, para
no repetir el error que ya audito "Veredicto final del corte TDD
multi-runtime (#1411)": cerrar un issue declarandolo resuelto sin la sesion en
vivo que su propio criterio de aceptacion exige.

CA-1 a CA-3 de #1464 exigen, en este orden: fijar una release candidata e
identidad `aligned` verificadas contra Claude Code y OpenCode instalados de
verdad; crear cuatro issues fixture **desde el planner publicado del
consumidor privado** `augusto-romero-arango/mefisto-consumer-certification`
(nunca con `gh -R` cross-repo desde Mefisto, MEF-ADR-0019); lanzar las cuatro
corridas reales desde paneles Herdr operando runtimes instalados en ese
consumidor; y esperar PRs reales con checks de CI verdes sobre su Azure
dedicado. Ninguna de esas cuatro operaciones es alcanzable por un stage de
escritura no-interactivo como este: no tiene credenciales ni alcance sobre el
repositorio privado del consumidor, no puede operar sesiones Herdr en vivo (un
proceso con paneles tmux que un humano dirige) y no puede esperar minutos u
horas a que un pipeline de CI ajeno resuelva. Esto no es una limitacion nueva:
es exactamente lo que anticipa la seccion "Notas tecnicas" del propio #1464 y
lo que ya cerro #1411 con su `NO PASA` -- "una operacion en vivo que excede el
alcance de un stage de escritura automatizado".

En consecuencia, este documento **no completa** las tablas de "Resultado
write-side (#1435)" ni "Resultado read-side (#1436)": ambas permanecen
`PENDIENTE DE EJECUCION`, y la matriz auditada de "Veredicto final del corte
TDD multi-runtime (#1411)" permanece sin cambios. Rellenar esas tablas sin la
sesion real violaria MEF-ADR-0031 de la misma forma que #1435/#1436 ya lo
hicieron al cerrarse como `COMPLETED` sin evidencia -- el defecto que este
mismo bug existe para corregir.

CA-1 a CA-5 de #1464 quedan pendientes de una sesion operada por un humano con
acceso al consumidor privado y a Herdr, siguiendo integramente el protocolo ya
fijado arriba ("Invariantes y prerrequisitos (CA-1)" a "Fail-closed y limpieza
(CA-6)") sin modificarlo. Quien opere esa sesion:

1. Ejecuta el preflight de "Invariantes y prerrequisitos (CA-1)" sobre una
   release candidata vigente al momento de la corrida (no la ya usada por
   #1180/#1181), fijando `<sha-baseline-inicial>`, `<tag-certificable>`,
   `<version>`, `<commit-fuente>` y `<checksum-opencode>` comunes con
   identidad `aligned` verificada.
2. Crea los cuatro issues fixture de "Fixtures write-side/read-side (CA-2)"
   desde el planner publicado del consumidor y lanza las cuatro corridas desde
   Herdr conforme a "Lanzamiento real desde Herdr (CA-4)", sin `--variant` ni
   override de modelo.
3. Rellena directamente las tablas de "Resultado write-side (#1435)" y
   "Resultado read-side (#1436)" con la evidencia real correlacionada por
   issue/PR/stage/session, y ejecuta la limpieza de "Fail-closed y limpieza
   (CA-6)".
4. Abre el nuevo issue de veredicto (equivalente a #1411) que audita esa
   evidencia real y emite `PASA` o `NO PASA`; ese issue cierra #1464 al
   resolverse, conforme al CA-5 del bug.

Este bug permanece **abierto** hasta que esa sesion humana ocurra: ningun PR
generado por `/mefisto:tooling` sobre #1464 resuelve sus criterios de
aceptacion, precisamente porque ninguno puede ejecutar la operacion en vivo
que exigen. Esto obliga a una accion explicita al mergear: el cuerpo de PR que
`src/internal/scripts/mefisto-tooling-pipeline.sh` genera incluye siempre
`Closes #<issue>`, de modo que GitHub cerrara #1464 al fusionar el PR de esta
seccion aunque la evidencia siga ausente. Quien mergee debe **reabrir #1464**
inmediatamente despues; el unico cierre valido de este bug es el issue de
veredicto del paso 4, conforme a su CA-5. Cerrarlo por el `Closes` automatico
repetiria literalmente el defecto que #1411 audito en #1435/#1436.

### Sesion humana ejecutada (2026-09-21)

La sesion operada en vivo que exige esta seccion ocurrio el 2026-09-21 sobre
la release `v0.38.2`: pasos 1 a 3 cumplidos y consignados en "Resultado
write-side (#1435)" y "Resultado read-side (#1436)" (matriz 2x2 del intento 2,
PRs #38-#41 del consumidor, cuatro `PASA` individuales). El paso 4 es
[#1487](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1487),
el issue de veredicto que audita esa evidencia; #1464 sigue abierto hasta que
#1487 se resuelva. El PR que registra esta evidencia usa `Refs #1464`, nunca
`Closes`.

## Veredicto final del corte TDD multi-runtime (#1487)

Esta seccion audita, sin repetir ejecuciones, la sesion operada por un humano
el 2026-09-21 sobre la release `v0.38.2` ("Sesion humana ejecutada
(2026-09-21)" de la seccion anterior) contra las tablas ya rellenas de
"Resultado write-side (#1435)" y "Resultado read-side (#1436)" arriba. No
redefine el protocolo de #1434 ni sus templates; emite el veredicto documental
fail-closed que exige el CA-4 de "Fail-closed y limpieza (CA-6)" del protocolo
y que "Bloqueo estructural de la ejecucion automatizada (#1464)" dejo
pendiente en su paso 4.

### Identidad comun de release (CA-1 de #1487)

Las cuatro celdas comparten los mismos cinco valores de identidad, tomados sin
variacion de las tablas "Campo | Valor verificado" de #1435 y #1436:

| Parametro | write-side Claude (#34) | write-side OpenCode (#35) | read-side Claude (#36) | read-side OpenCode (#37) |
|---|---|---|---|---|
| `<tag-certificable>` | `v0.38.2` | `v0.38.2` | `v0.38.2` | `v0.38.2` |
| `<version>` | `0.38.2` | `0.38.2` | `0.38.2` | `0.38.2` |
| `<commit-fuente>` | `6c2319c5a91aef844d5f71468ecb43d6f72a1cfe` | idem | idem | idem |
| `<checksum-opencode>` (digest OpenCode) | `78eee7c04875c534d2c7c0bed4eddf77f6c8b227346bf78d5cd6bd81fdd83459` | idem | idem | idem |
| Identidad (`diagnose-installation-identity.sh`) | `aligned` | `aligned` | `aligned` | `aligned` |

`v0.38.2` es posterior a `v0.37.16` (la release que certifico `/mefisto:tooling`
en #1181), conforme exige "Invariantes y prerrequisitos (CA-1)" del protocolo.
Las cuatro corridas comparten ademas `<sha-baseline-inicial>` =
`9f49d6a59fa96f7e5a49b0139fa27ae9c2353d35`, identico entre el par write-side y
el par read-side. No hay identidad divergente que juzgar.

### Matriz 2x2 auditada (CA-2 de #1487)

| Dimension | write-side Claude | write-side OpenCode | read-side Claude | read-side OpenCode |
|---|---|---|---|---|
| Issue fixture | [#34](https://github.com/augusto-romero-arango/mefisto-consumer-certification/issues/34) | [#35](https://github.com/augusto-romero-arango/mefisto-consumer-certification/issues/35) | [#36](https://github.com/augusto-romero-arango/mefisto-consumer-certification/issues/36) | [#37](https://github.com/augusto-romero-arango/mefisto-consumer-certification/issues/37) |
| PR (`Closes`) | [#38](https://github.com/augusto-romero-arango/mefisto-consumer-certification/pull/38) (`Closes #34`) | [#39](https://github.com/augusto-romero-arango/mefisto-consumer-certification/pull/39) (`Closes #35`) | [#40](https://github.com/augusto-romero-arango/mefisto-consumer-certification/pull/40) (`Closes #36`) | [#41](https://github.com/augusto-romero-arango/mefisto-consumer-certification/pull/41) (`Closes #37`) |
| Session id | `20260921-075322` | `20260921-080923` | `20260921-082706` | `20260921-084136` |
| Stage 1 (fase roja) | rojo funcional, 46 tests/1 fallido | rojo funcional, misma cifra | rojo real sobre `Create`, 17/2 fallidos | rojo real, mismos 2 fallidos |
| Stage 2 (fase verde) | verde, 46/46 + 16/16 | verde, misma cifra | verde, 45/45 + 17/17 | verde, misma cifra |
| Stage 2b (smoke tests) | ejecutado | ejecutado | ejecutado | ejecutado |
| Stage 3 (reviewer) | `success` | `success` | `success` | `success` |
| Stage 4 (coverage gate) | `passed`, gaps=0 | `passed`, gaps=0 | `passed`, gaps=0 | `passed`, gaps=0 |
| Checks | `NO_APLICAN` | `NO_APLICAN` | `NO_APLICAN` | `NO_APLICAN` |
| Stage 0 (scaffold) | no ejecutado | no ejecutado | no ejecutado | no ejecutado |

Ninguna celda permanece en `PENDIENTE DE EJECUCION`: las cuatro tienen issue de
fixture, PR con `Closes`, session id y resultado de Stage 1/2/2b/3/4
verificables en las tablas de #1435 y #1436. Stage 2b nunca aparece `skipped`
en ninguna de las cuatro filas de esas tablas. Stage 0 esta explicitamente
marcado "no ejecutado" en ambas, conforme a la eleccion de
`<dominio-certificable>` con Function App y proyecto SmokeTests ya existentes
("Eleccion del dominio certificable" del protocolo). El `NO_APLICAN` de checks
trae el mismo motivo explicito en las cuatro celdas: el unico workflow
`pull_request` del consumidor (`infra-cd.yml`) filtra a `infra/**` y ninguno de
los cuatro PRs toca esa carpeta; `statusCheckRollup` vacio en los cuatro.

### Observabilidad y limpieza (CA-3 de #1487)

El expediente sanitizado (`.mefisto/pipeline/certification/tdd-v0.38.2/` en el
consumidor, ignorado por Git: `coordination.md`, `write-claude.md`,
`write-opencode.md`, `read-claude.md`, `read-opencode.md`, `sentinels.md`,
`final-handoff.md`) correlaciona cada una de las cuatro celdas por
issue/PR/stage/session (hash), conforme registran las filas "Discovery" y
"Diferencias de adaptador" de #1435/#1436. El barrido de centinelas
(`sentinels.md`, cubriendo tambien `intento-1/`) dio **0 coincidencias** en los
cuatro patrones (salida cruda/interaccion, cabeceras de auth, almacenes de
auth/credenciales, tokens de portador/prefijo corto). `<sha-baseline-inicial>`
= `<sha-baseline-final>` = `9f49d6a59fa96f7e5a49b0139fa27ae9c2353d35` tanto en
el par write-side como en el par read-side, con el arbol limpio antes y
despues de cada corrida; la limpieza (PRs cerrados sin merge, ramas remotas
eliminadas, issues fixture `not planned`, cero worktrees) se ejecuto el
2026-09-21T08:58:07-05:00 en ambos pares.

### Desviacion de fixture: justificada, no evidencia de paridad (CA-4 de #1487)

El intento 2 (run-id `20260921-073646-v0.38.2`, fixtures #34-#37, unica
evidencia que este veredicto juzga) agrega a los cuatro fixtures una seccion
`## ADRs aplicables`, ausente en los templates literales de "Fixtures
write-side/read-side (CA-2)" del protocolo. Esa adicion **no es una desviacion
que invalide la evidencia**: corrige un defecto de los templates frente a la
doctrina que ya rige la escritura real. `agents/implementer.md`, paso "1b. Leer
los ADRs aplicables del issue", exige que todo issue declare esa seccion antes
de escribir codigo y, si esta ausente o vacia, ordena al implementer detenerse
y reportar el gap en `blockage-report.md` en vez de continuar;
`agents/planner.md` (paso 7 de "Crear issues") exige igualmente que el planner
la enumere en cualquier issue que redacte. Los templates de este protocolo --
redactados antes de que esa exigencia se verificara contra una escritura real
-- simplemente no la incluyen: el defecto es del template (hallazgo no
bloqueante capturado en #1560), no de `tdd-pipeline.sh` ni de los agentes que
lo ejecutan.

Esto es exactamente lo que expuso el intento 1 (run-id
`20260921-062538-v0.38.2`, fixtures #28-#31, PRs #32/#33): sobre el template
literal sin `## ADRs aplicables`, el implementer de OpenCode aplico su
doctrina correctamente (se detuvo y reporto el gap) mientras el de Claude se
aparto de ella, produciendo una asimetria `NO PASA` en la celda write
OpenCode. Esa asimetria es indicio de un defecto de *fixture* -- el template no
cumplia la propia doctrina de Mefisto --, no de una diferencia entre runtimes:
por eso el intento 1 queda citado aqui unicamente como **antecedente
historico** de por que la seccion se agrego, y **nunca** como evidencia de
paridad ni de disparidad entre Claude y OpenCode. La unica evidencia que este
veredicto juzga para CA-1 a CA-6 del protocolo es el intento 2, sobre fixtures
que corrigen ese defecto y por eso produjeron las cuatro celdas `PASA` sin
bifurcacion de comportamiento entre agentes.

### Veredicto (CA-5 de #1487)

**PASA (2026-09-22), release `v0.38.2`.** Causa: las cuatro celdas de la matriz
write-side/read-side x Claude/OpenCode exigidas por #1435/#1436 tienen ahora
evidencia real y correlacionable -- fixture, PR con `Closes`, session id y
resultado de Stage 1/2/2b/3/4 -- con identidad de release identica y `aligned`
en las cuatro, observabilidad correlacionada por expediente, centinelas en
cero y baseline restaurado exactamente al mismo SHA en las dos corridas
gemelas. La unica desviacion frente a los templates del protocolo (la seccion
`## ADRs aplicables` agregada en el intento 2) se juzga arriba como
**desviacion justificada**, atribuible a un defecto de los templates y no del
pipeline certificado.

Conforme al CA-4 de #1411 y al CA-5 de #1464, este `PASA`:

- Otorga a `/mefisto:implement` (rutas write-side y `tipo:projection`) soporte
  certificado bajo Claude Code y bajo OpenCode, en el mismo alcance acotado que
  fijo "Alcance de lo que este veredicto juzga" en la seccion de #1411:
  unicamente esas dos rutas normales; `--scaffold-domain`, `--from-stage`,
  `--variant` y la remediacion de coverage no ejercida permanecen fuera de este
  veredicto y requieren un protocolo propio para certificarse.
- No abre ningun bug nuevo: no hay causa de `NO PASA` que reportar. Los
  hallazgos no bloqueantes del mismo expediente ya quedaron capturados como
  drafts independientes -- #1560, #1561, #1562, #1563 -- fuera del alcance de
  este veredicto.
- Cierra la dependencia que "Bloqueo estructural de la ejecucion automatizada
  (#1464)" declaraba sobre este issue de veredicto (su paso 4); #1464 se cierra
  a mano tras el merge del PR de este issue, con un comentario que enlace esta
  seccion, conforme al CA-5 de #1464 y a la advertencia de esa misma seccion
  sobre no cerrarlo por el `Closes` automatico de un PR de tooling.

**Alcance de lo que este veredicto juzga.** Igual que #1411, cubre unicamente
las rutas write-side y `tipo:projection` normales de `/mefisto:implement` sobre
la release `v0.38.2`. No certifica `--scaffold-domain`, `--from-stage`,
`--variant` ni la remediacion de coverage no ejercida; tampoco recertifica
`/mefisto:tooling`, ya `PASA` desde #1066.

## Referencias

- [#1487](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1487):
  issue de veredicto que audita la sesion humana de #1464 y emite `PASA` sobre
  las cuatro corridas reales de #1435/#1436; cierra #1464 al mergearse (a mano,
  no por `Closes` automatico).
- `docs/testing/opencode-consumer-cutover.md`: protocolo, consumidor y
  veredicto `PASA` (#1066) del corte `/mefisto:tooling` que este documento
  reutiliza como prerrequisito de instalacion, identidad y redaccion.
- MEF-ADR-0011: Definition of Ready por tipo de issue; fija las secciones
  criticas de los cuatro templates de fixture.
- MEF-ADR-0019: separacion publicado/interno; los issues y PRs fixture se
  gestionan exclusivamente desde el consumidor.
- MEF-ADR-0025: custodia de secretos por runtime; ningun manifiesto de este
  protocolo persiste credenciales, prompts o auth stores.
- MEF-ADR-0031: un gate exige evidencia ejecutable y repetible, no presencia
  de archivos generados.
- MEF-ADR-0033/MEF-ADR-0034/MEF-ADR-0035: Skill `projections` y doctrina
  read-side (recetas de proyeccion, read model canonico, read APIs
  tenant-scoped) que las corridas read-side deben descubrir y aplicar; el
  worker de proyecciones compartido de MEF-ADR-0034 es la razon de que las dos
  corridas read-side se lancen secuencialmente entre si.
- MEF-ADR-0050: toda operacion nace neutral a runtime; este protocolo verifica
  la misma operacion (`/mefisto:implement`) bajo ambos adaptadores.
- MEF-ADR-0053, seccion 6: gate reproducible de corte vertical que este
  protocolo extiende de `/mefisto:tooling` a `/mefisto:implement`.
- [#1464](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1464):
  bug abierto por el veredicto `NO PASA` de "Veredicto final del corte TDD
  multi-runtime (#1411)"; rastrea la ejecucion real de las cuatro corridas que
  #1435/#1436 dejaron `PENDIENTE DE EJECUCION`.
