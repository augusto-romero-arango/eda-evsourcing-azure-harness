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
`projection-test-writer`, `projection-implementer`) y `scripts/tdd-pipeline.sh`
como entrypoint distinto de `tooling-pipeline.sh`. El resto de la mecanica de
instalacion, identidad y proyeccion es identica a la ya certificada y no se
vuelve a descubrir.

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
  real.
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

## Referencias

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
- MEF-ADR-0050: toda operacion nace neutral a runtime; este protocolo verifica
  la misma operacion (`/mefisto:implement`) bajo ambos adaptadores.
- MEF-ADR-0053, seccion 6: gate reproducible de corte vertical que este
  protocolo extiende de `/mefisto:tooling` a `/mefisto:implement`.
