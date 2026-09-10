# Protocolo de certificacion del consumidor multi-runtime

Este protocolo materializa el gate de corte vertical de
[MEF-ADR-0053](../adr/mef-adr-0053-distribucion-multi-runtime-consumidores.md),
seccion 6. Su antecedente, `opencode-dogfooding.md`, certifica exclusivamente el
lado interno; no sustituye esta certificacion de consumidor publicado.

No se ejecuta durante la redaccion de este documento. Requiere que exista una
release candidata y el repositorio fixture descrito abajo. La primera candidata
prevista es el patch posterior a `v0.37.0`, pero cada corrida registra el tag
efectivo: nunca sustituye ese valor por `latest` ni lo infiere desde un cache.

## Invariantes y prerrequisitos

El consumidor persistente, privado y dedicado es
`augusto-romero-arango/mefisto-consumer-certification`. No representa un
producto real. Se crea, se onborda y se gestiona desde ese repositorio; Mefisto
solo conserva este protocolo. Conforme a MEF-ADR-0019, los issues y PRs fixture
se crean desde el consumidor y no se usa el planner interno para gestionar otro
repositorio.

El baseline versionado debe ser un **consumidor completo**, no un fixture
minimo. Antes de certificar, su evidencia privada demuestra:

- `AGENTS.md`, `CLAUDE.md`, `.mefisto/harness.config.json` y `.gitignore`
  conformes al contrato del harness;
- el informe de `/mefisto:onboard` en estado `LISTO`, sin `FALTA` ni `NO
  VERIFICADO`;
- CI verde que use OIDC hacia Azure, recursos Azure dedicados operativos y
  secretos declarados por nombre, sin client secret persistente ni valores de
  secretos; y
- los labels requeridos por el consumidor, incluidos `tipo:tooling`,
  `dom:certificacion` y `estado:listo` para las corridas posteriores.

La provision y el diagnostico ocurren **desde el clone de ese consumidor**. No
se admite como instalacion ni como evidencia un checkout, worktree, enlace
simbolico, copia parcial o ruta absoluta del repositorio de Mefisto. Esto evita
que el cwd, una fuente mutable o un cache local reemplacen la release versionada
(MEF-ADR-0053, decisiones 2 y 6).

Antes de instalar o abrir issues se registra este conjunto de parametros
inmutables:

| Parametro | Como se obtiene o valida |
|---|---|
| `<tag-certificable>` | tag Git exacto `v<version>` de la candidata publicada |
| `<version>` | SemVer del manifiesto de ambos adaptadores; coincide con el tag sin `v` |
| `<commit-fuente>` | SHA completo de 40 hexadecimales en ambos `mefisto-manifest.json` |
| `<checksum-opencode>` | digest SHA-256 de la linea canonica de `mefisto-opencode-v<version>.tar.gz.sha256` y resultado de `shasum -a 256 -c` |
| `<sha-baseline-inicial>` / `<sha-baseline-final>` | `git rev-parse HEAD` antes de cada corrida y despues de su limpieza; deben ser iguales |
| `<version-claude>`, `<version-opencode>`, `<version-herdr>` | salidas completas de `claude --version`, `opencode --version` y `herdr --version`; no se sustituyen por la version de Mefisto |

La identidad se confirma antes de crear corridas con el
`diagnose-installation-identity.sh` distribuido. Su JSON debe ser `aligned` y
debe contener el mismo `version` y `commit` para `claude` y `opencode`; cualquier
otro estado es una divergencia, no un permiso para continuar.

## Certificacion de instalacion y discovery (#1180)

Esta seccion certifica exclusivamente el baseline, la instalacion real y el
discovery de una release publicada. Termina antes de crear los dos issues
fixture, abrir Herdr o invocar `/mefisto:tooling`; esas corridas E2E pertenecen
a #1181. Los valores entre angulos son outputs de los prerrequisitos, no valores
que se puedan anticipar, inferir desde `latest` ni sustituir por un checkout.

### Estado de la corrida

**Bloqueada antes de instalar (2026-09-10T01:12:39Z).** La identidad de GitHub
efectiva para esta corrida ejecuto consultas de solo lectura por nombre exacto:

| Comando sanitizado | Resultado sanitizado |
|---|---|
| `gh issue view 1179 --json state,url` | #1179 esta `CLOSED`: el protocolo requerido ya existe. |
| `gh api repos/augusto-romero-arango/mefisto-consumer-certification` | HTTP 404: el consumidor privado no es accesible para la identidad efectiva; no se pudo obtener URL, visibilidad, SHA baseline ni evidencia de onboarding, CI o Azure. |
| `gh release list --repo augusto-romero-arango/eda-evsourcing-azure-harness --limit 5` | La release mas reciente observable es `v0.37.0`; no existe una release posterior certificable. |
| `gh release view v0.38.0 --repo augusto-romero-arango/eda-evsourcing-azure-harness` | No existe esa release; `v0.38.0` se consulto solo como nombre exacto, no se adopto como candidata. |

Faltan, por tanto, los dos prerrequisitos operacionales de #1180. No se
descargaron assets, no se modificaron instalaciones y no se intento discovery.
Esto no es un veredicto de certificacion ni una divergencia del producto: la
corrida no comenzo. #1180 debe permanecer abierto y repetirse desde el inicio
cuando el consumidor completo sea accesible y `/mefisto-release patch` haya
publicado la primera version posterior a `v0.37.0`. No se abre un bug por la
ausencia de esos prerrequisitos; cualquier fallo que aparezca despues de
satisfacerlos sigue el regimen fail-closed de esta seccion.

### Preflight del consumidor ajeno

Desde un clone nuevo de
`augusto-romero-arango/mefisto-consumer-certification`, privado y persistente,
registre la URL remota, su visibilidad privada y `<sha-baseline-inicial>`. El
arbol debe estar limpio antes y despues del preflight. Con comandos de
metadatos, no copiando su contenido, demuestre que:

1. el clone no es checkout ni worktree de Mefisto (`git worktree list` no
   referencia una raiz Mefisto y `git rev-parse --show-toplevel` es la raiz del
   consumidor);
2. no hay enlaces simbolicos versionados ni rutas absolutas hacia Mefisto en el
   arbol o su configuracion de harness; y
3. existe evidencia enlazable del onboarding `LISTO` sin ocurrencias de
   `FALTA`/`NO VERIFICADO`, del workflow CI verde que autentica a Azure por OIDC,
   y de la infraestructura Azure dedicada operativa.

La evidencia del punto 3 solo conserva URLs, nombres de recursos o secretos y
estados sanitizados. No incorpora IDs de suscripcion/tenant, outputs sensibles,
valores de secretos, cabeceras ni credenciales. Si el baseline cambia durante
el preflight, se restaura o se vuelve a clonar antes de continuar; no se
"arregla" desde este repositorio ni se gestiona con `gh -R`.

### Verificacion de la release efectiva

La publicacion mediante `/mefisto-release patch`, posterior a la integracion de
#1179, es un prerrequisito y no un paso ejecutado desde el consumidor. Conserve
el registro que produce: `<tag-certificable>`, `<commit-etiquetado>`,
`<commit-fuente>` y las URLs de los dos assets OpenCode. Antes de instalar,
consulte el tag y release publicados por su nombre exacto `v<version>` y
registre respuestas sanitizadas que prueben todos estos predicados:

| Predicado fail-closed | Evidencia requerida |
|---|---|
| Version publicable | `<version>` es SemVer y es estrictamente posterior a `0.37.0`; `<tag-certificable>` es exactamente `v<version>`. |
| Procedencia Git | El commit del tag tiene un unico padre y ese padre es exactamente `<commit-fuente>`; el tag apunta a `<commit-etiquetado>`. |
| Identidad Claude | El `plugin.json` de la distribucion marketplace declara `name=mefisto` y `<version>`; su `mefisto-manifest.json` declara `runtime=claude`, la misma `<version>` y `<commit-fuente>`. |
| Identidad OpenCode | El manifiesto del artefacto OpenCode declara identidad `opencode`, `<version>` y `<commit-fuente>` (y su minimo de runtime). |
| Assets | Las URLs del mismo tag descargan `mefisto-opencode-v<version>.tar.gz` y `mefisto-opencode-v<version>.tar.gz.sha256`; se registran ambas URLs y el SHA-256 publicado. |

Las consultas deben dirigirse al tag/release exacto (por ejemplo, la vista y API
de GitHub del tag y de sus assets), nunca a `latest`. Un cache de plugin, un
checkout local o un manifiesto ya instalado pueden corroborar una instalacion,
pero no completan esta verificacion de release. Si falta uno de los predicados,
no se instala ni se sustituye el dato por una candidata supuesta.

### Instalacion Claude Code a scope de usuario

Registre el argv sanitizado y las versiones efectivas de CLI y plugin. Instale
o actualice desde el marketplace al scope `user` con el identificador publicado,
despues reinicie Claude Code o ejecute `/reload-plugins`. En una **sesion nueva**
capture la raiz realmente cargada, no la raiz mas reciente de su cache, y
compruebe:

- `mefisto-manifest.json` de esa raiz declara `runtime=claude`, `<version>` y
  `<commit-fuente>`;
- `.mefisto/pipeline/.plugin-root` nombra exactamente esa raiz cargada; y
- el mirror legacy autorizado `.claude/pipeline/.plugin-root`, cuando exista,
  nombra la misma raiz y no una version mas nueva del cache.

Un marker ausente, una raiz que sea checkout/worktree o una identidad distinta
es fallo. La certificacion no reescribe markers a mano: la sesion y su hook
`record-active-release` son quienes los producen.

### Instalacion y proyeccion OpenCode

Registre `opencode --version` y confirme que la version efectiva es al menos
1.18.29. En un directorio temporal, descargue ambos assets por sus URLs exactas,
valide el checksum **antes** de extraer o ejecutar el bootstrap y ejecute
`./install.sh install <version>`, el entrypoint empaquetado. Ese comando instala
y activa la release. Despues, mediante el launcher instalado, ejecute en este
orden:

```bash
<mefisto-opencode> project
<mefisto-opencode> status
<mefisto-opencode> diagnose
```

`status` debe identificar la release activa y su commit; la raiz de datos debe
contener `releases/<version>/` sin enlaces ni permisos de escritura y un unico
puntero `active` hacia ella. `project` debe informar la raiz global efectiva de
OpenCode, preservar configuracion ajena y mostrar las capacidades ausentes como
`DEGRADACION VISIBLE`; en macOS se registran separadamente la raiz de datos de
Mefisto y la raiz de configuracion OpenCode, salvo overrides XDG explicitamente
declarados. No se inspecciona ni registra el auth store de OpenCode.

### Matriz de discovery y alineacion

Discovery es una observacion de runtime, no una inspeccion de archivos ni una
ejecucion anticipada del pipeline. Registre el comando equivalente realmente
ejecutado y su resultado sanitizado. Claude usa los listados de comandos,
agentes, Skills, hooks y MCP de una sesion nueva; OpenCode usa `opencode debug
config`, `opencode agent list` y la proyeccion global efectiva. La matriz debe
quedar completa:

| Superficie | Claude Code | OpenCode |
|---|---|---|
| Comando y agentes tooling | `/mefisto:tooling`, `tooling-writer`, `tooling-reviewer` | `/mefisto:tooling`, `tooling-writer`, `tooling-reviewer` |
| Clausura y permisos | clausura exacta enumerada abajo; solo `read`, `edit`, `shell` | misma clausura adaptada; solo `read`, `edit`, `shell` |
| Skills | `projections`, `comment-cleanup` | `mefisto-projections`, `mefisto-comment-cleanup` |
| Observabilidad y MCP | hooks/plugin de observabilidad y `microsoft-learn` bundled | plugin de observabilidad y `microsoft-learn` bundled |
| Externo | `terraform` identificado como dependencia externa | `terraform` identificado como dependencia externa |

Los agentes tooling no cargan Skills ni MCP: su ausencia en esos agentes es el
resultado esperado, no una degradacion. Las Skills y MCP se certifican por la
fila propia de discovery. La clausura exacta que ambos runtimes deben descubrir
en la distribucion instalada es:

```text
scripts/_pipeline-common.sh
scripts/tmux-pipeline.sh
scripts/herdr-pipeline.sh
scripts/stream-watch.sh
scripts/tooling-pipeline.sh
src/runtime/mefisto-run-agent.sh
src/runtime/lib/mefisto-runtime.sh
src/runtime/lib/mefisto-models.sh
src/runtime/lib/mefisto-process.sh
src/runtime/lib/runtime-claude.sh
src/runtime/lib/runtime-claude.jq
src/runtime/lib/runtime-opencode.sh
src/runtime/lib/runtime-opencode.jq
src/runtime/contract/models.validate.jq
```

El checkout principal y un worktree del consumidor deben resolver la misma
raiz Claude cargada y el mismo `active` OpenCode, y producir la misma matriz;
una diferencia por cwd es fallo.

Por ultimo, invoque `diagnose-installation-identity.sh` solamente con
`--claude-root <raiz-claude-cargada>` y
`--opencode-root <raiz-opencode-activa>`. Su JSON debe tener `status=aligned` y
ambos objetos deben declarar `<version>` y `<commit-fuente>` ya verificados. No
se permite que el diagnostico consulte checkout, cache, red, configuracion o
auth stores.

### Evidencia, centinelas y bloqueo

Anexe un manifiesto redactado con timestamp/zona horaria, argv sanitizados,
versiones de CLI, tag, ambos commits, SHA-256, rutas observadas, estados de
preflight/proyeccion/discovery y URLs de evidencia. Ejecute los centinelas de la
seccion "Manifiesto de evidencia y redaccion" sobre el reporte final y registre
conteo cero para prompts, raw, stderr, headers, auth stores, API keys y tokens;
nunca persista el contenido que coincida.

Cualquier fallo crea un issue `tipo:bug` en Mefisto, enlaza la evidencia
sanitizada, se añade como dependencia de #1180 y conserva #1180 abierto. No se
parchea el consumidor para simular paridad ni se repite sobre un baseline sucio.

## Matriz de corridas e issues fixture (#1181)

### Estado de la corrida

**Bloqueada antes de crear fixtures (2026-09-10).** La evidencia de #1180 no
certifico una instalacion: registro que el consumidor privado devolvia HTTP 404
para la identidad efectiva y que la release mas reciente observable seguia
siendo `v0.37.0`, cuando este protocolo exige una candidata posterior. Una
comprobacion de solo lectura al revisar #1181 reprodujo ambos resultados:

| Comando sanitizado | Resultado sanitizado |
|---|---|
| `gh issue view 1180 --json state,stateReason,url` | #1180 esta cerrado como `COMPLETED`, pero su evidencia publicada conserva el estado "Bloqueada antes de instalar"; cerrar el issue documental no convierte ese intento en una certificacion. |
| `gh release list --repo augusto-romero-arango/eda-evsourcing-azure-harness --limit 5` | La release mas reciente observable es `v0.37.0`; no hay una candidata posterior que pueda instalarse con identidad comun. |
| `gh api repos/augusto-romero-arango/mefisto-consumer-certification` | HTTP 404; no se pueden verificar baseline, fixtures ni ejecuciones con la identidad efectiva. |

Por ello no se crearon issues o PRs fixture, no se abrio Herdr y no se invoco
`/mefisto:tooling`. Hacerlo sin esos prerrequisitos inventaria la evidencia que
MEF-ADR-0031 y MEF-ADR-0053 exigen obtener de ejecuciones reales. Este estado no
es un fallo de runtime y no abre un bug: #1181 debe repetirse desde el inicio
cuando el consumidor sea accesible y exista una release certificable. El resto
de esta seccion conserva el procedimiento reproducible para esa repeticion; no
constituye un veredicto exitoso.

Se abren **dos issues distintos**, ambos en el consumidor, con labels
`tipo:tooling`, `dom:certificacion` y `estado:listo`: uno para Claude y uno para
OpenCode. Cada issue produce su propia rama y PR. Esa separacion hace comparables
las dos ejecuciones sin compartir worktree, logs, estado de pipeline ni commit
de salida. No se usa `--variant`: una variante conserva una rama local y no abre
PR, por lo que no ofrece la evidencia independiente requerida por el gate.

Defina `<run-id>` como `YYYYMMDD-HHMMSS-<tag-certificable>` normalizado (sin la
`v` inicial si se necesita un nombre de archivo portable). Las plantillas son
intencionalmente identicas salvo por runtime, ruta y contenido esperado.
Al crear cada uno se pasan los tres labels de forma explicita, por ejemplo con
`gh issue create --repo augusto-romero-arango/mefisto-consumer-certification
--label tipo:tooling --label dom:certificacion --label estado:listo --title
<titulo> --body-file <template-runtime.md>`. La salida de ese comando fija `<issue-claude>` o
`<issue-opencode>`; no se reutiliza un numero entre filas.

### Template: Claude

````markdown
# Certificar tooling publicado bajo Claude (<run-id>)

## Contexto

Certificar la release `<tag-certificable>` (`<version>`, commit fuente
`<commit-fuente>`) desde una instalacion publicada real en este consumidor.

## Alcance

Crear exclusivamente `docs/testing/mefisto-certification/<run-id>-claude.md`.
No modificar otro archivo ni usar `--variant`.

## Contenido determinista

El archivo debe contener exactamente:

```text
runtime=claude
tag=<tag-certificable>
version=<version>
commit=<commit-fuente>
run=<run-id>
```

## Verificacion

Ejecutar `git diff --check` y verificar que el unico archivo versionado cambiado
sea `docs/testing/mefisto-certification/<run-id>-claude.md`, con las cinco lineas
exactas anteriores. El pipeline debe llegar a un PR real.

## Dependencias

- Ninguna.
````

### Template: OpenCode

````markdown
# Certificar tooling publicado bajo OpenCode (<run-id>)

## Contexto

Certificar la release `<tag-certificable>` (`<version>`, commit fuente
`<commit-fuente>`) desde una instalacion publicada real en este consumidor.

## Alcance

Crear exclusivamente `docs/testing/mefisto-certification/<run-id>-opencode.md`.
No modificar otro archivo ni usar `--variant`.

## Contenido determinista

El archivo debe contener exactamente:

```text
runtime=opencode
tag=<tag-certificable>
version=<version>
commit=<commit-fuente>
run=<run-id>
```

## Verificacion

Ejecutar `git diff --check` y verificar que el unico archivo versionado cambiado
sea `docs/testing/mefisto-certification/<run-id>-opencode.md`, con las cinco lineas
exactas anteriores. El pipeline debe llegar a un PR real.

## Dependencias

- Ninguna.
````

## Procedimiento reproducible

Ejecute las filas en este orden desde el clone limpio del consumidor. Sustituya
solo los placeholders documentados y capture el argv sanitizado de cada comando;
nunca capture variables de entorno completas.

1. **Preparar baseline.** Clonee el repositorio fixture, haga checkout de
   `<sha-baseline-inicial>` y compruebe `git status --porcelain=v1` vacio.
   Provisionar el repositorio y ejecutar directamente `/mefisto:onboard` en
   modo diagnostico son prerrequisitos hechos desde este clone antes de fijar el
   baseline; no forman parte del catalogo que migra este protocolo. Durante la
   certificacion no acepte la provision opt-in de labels o CI. Registre remoto,
   SHA y URL y no cree enlaces hacia Mefisto.
2. **Instalar la misma release.** Antes de actualizar, registre las raices y
   versiones activas para el rollback. El catalogo del marketplace y el GitHub
   Release deben exponer exactamente `<tag-certificable>`; si solo puede
   afirmarse que es `latest`, aborte. En Claude Code puede ejecutar directamente
   `/mefisto:upgrade` desde la instalacion anterior, sin poda, seguido de
   `/reload-plugins`; para un bootstrap registre el marketplace como documenta
   `README.md` y ejecute `claude plugin install
   mefisto@augusto-romero-arango-harness --scope user`. Despues del reload,
   defina `<raiz-claude-instalada>` como la raiz
   autocontenida realmente cargada y confirme su `mefisto-manifest.json`.

   Para el primer bootstrap OpenCode, ejecute desde un directorio temporal la
   secuencia publicada; no ejecute ningun archivo antes de validar el checksum:

   ```bash
   VERSION=<version>
   BASE="https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/releases/download/v$VERSION"
   curl -fL "$BASE/mefisto-opencode-v$VERSION.tar.gz" -o "mefisto-opencode-v$VERSION.tar.gz"
   curl -fL "$BASE/mefisto-opencode-v$VERSION.tar.gz.sha256" -o "mefisto-opencode-v$VERSION.tar.gz.sha256"
   shasum -a 256 -c "mefisto-opencode-v$VERSION.tar.gz.sha256"
   mkdir mefisto-opencode-release
   tar -xzf "mefisto-opencode-v$VERSION.tar.gz" -C mefisto-opencode-release
   ./mefisto-opencode-release/install.sh install "$VERSION"
   ```

   Elimine el directorio temporal cuando haya registrado
   `<checksum-opencode>`. Si ya existe una instalacion verificada, use su punto
   de entrada absoluto `<mefisto-opencode>` (el instalador no crea un comando en
   `PATH`) para actualizar y proyectar:

   ```bash
   <mefisto-opencode> install <version>
   <mefisto-opencode> project
   <mefisto-opencode> status
   ```

   El instalador descarga `mefisto-opencode-v<version>.tar.gz`, valida su
   SHA-256 contra el `.sha256` del release y activa solo una release valida e
   inmutable. Guarde el digest y el resultado, no el tarball ni datos de auth.
3. **Alinear identidad y preparar fixtures.** Desde la raiz del consumidor,
   ejecute el diagnostico de la release instalada proporcionando la raiz Claude
   observada y el
   `active` OpenCode cuando no sean los defaults:

   ```bash
   <mefisto-opencode> status
   <mefisto-opencode> package-root
   <raiz-opencode-activa>/diagnose-installation-identity.sh \
     --claude-root <raiz-claude-instalada> \
     --opencode-root <raiz-opencode-activa>
   ```

   La salida de `package-root` fija `<raiz-opencode-activa>`. En el JSON,
   `status=aligned` y `claude`/`opencode` con `version=<version>` y
   `commit=<commit-fuente>` son precondiciones fail-closed. La ruta Claude es la
   de la instalacion cargada, no una ruta de checkout; obtengala del marker
   canonico de release o de la propia sesion despues del reload. Desde el
   planner **publicado** del consumidor, cree los dos issues abiertos e
   independientes con los templates exactos de las secciones anteriores y los
   tres labels explicitos. Registre sus numeros, URLs y el mismo
   `<sha-baseline-inicial>` antes de abrir Herdr. No cree, cierre ni modifique
   esos fixtures con el planner interno de Mefisto ni con `gh -R`; los issues y
   PRs pertenecen exclusivamente al consumidor.
4. **Discovery separado.** En cada runtime descubra y registre, sin ejecutar
   tooling: comandos, agentes, Agent Skills, scripts/runner,
   permisos, hooks y MCP. Para Claude use `/help`, `/agents`, `/skills`,
   `/hooks` y `/mcp`, ademas del inventario de la raiz cargada. Para OpenCode
   use `opencode debug config`, `opencode agent list` y las rutas globales
   proyectadas (`commands`, `agents`, `skills`, `plugins`); compruebe tambien
   que el estado del proyector no reporte capacidades ausentes. Registre en
   ambos `/mefisto:tooling`, `tooling-writer`, `tooling-reviewer`, la clausura
   exacta enumerada en la matriz y los permisos efectivos. Registre
   `projections`/`comment-cleanup` en Claude frente a
   `mefisto-projections`/`mefisto-comment-cleanup` en OpenCode, el adaptador de
   hooks, `microsoft-learn` y `terraform` como dependencia externa. Discovery
   prueba disponibilidad, no
   ejercita una tool MCP ni un hook ajeno al flujo. Si una version del runtime
   no ofrece alguno de esos listados, registre el comando de discovery
   equivalente realmente usado; no sustituya discovery por presencia de
   archivos.
5. **Workspace Herdr.** Una vez por baseline alineado y con los dos issues
   abiertos, ejecute la invocacion
   real distribuida:

   ```bash
   <raiz-claude-instalada>/scripts/herdr-workspace.sh <ruta-del-consumidor>
   ```

   Compruebe identidad `aligned`, la fila superior
   `planner [claude]`/`ejecucion [claude]`, la inferior
   `planner [opencode]`/`ejecucion [opencode]`, sus pools de panes separados,
   `MEFISTO_RUNTIME` y el `--kind` heredados. La fila Claude inicia el planner
   con `mefisto:planner`; la OpenCode no usa `--agent`. Ninguna fila fija
   proveedor, modelo ni credenciales. Herdr monta y enfoca; no sustituye las
   dos ejecuciones independientes de abajo.
6. **Fila Claude.** Desde `ejecucion [claude]`, en la sesion Claude instalada,
   ejecute directamente:

   ```text
   /mefisto:tooling <issue-claude>
   ```

   No agregue `--models` ni `--variant`. Esta invocacion directa es el smoke
   interactivo de la fila; el pipeline que lanza ejecuta en print mode
   headless. Espere un PR real con `Closes #<issue-claude>`, comentario del
   pipeline y checks requeridos verdes. Confirme que los hooks naturales de
   inicio, cambios y cierre dejaron eventos correlacionables con la sesion. El
   comando despacha transitivamente `tmux-pipeline.sh`, `herdr-pipeline.sh`,
   `tooling-pipeline.sh`, el runner neutral, exactamente `tooling-writer` y
   `tooling-reviewer`; no invoque directamente ninguno de esos scripts o
   agentes.
7. **Fila OpenCode.** Con el baseline restaurado al SHA inicial, desde
    `ejecucion [opencode]` en la sesion OpenCode instalada, ejecute directamente:

   ```text
   /mefisto:tooling <issue-opencode> --models 'writer=<modelo-verificado>,reviewer=<modelo-verificado>'
   ```

   Los dos valores de `<modelo-verificado>` se obtienen del discovery efectivo
   de OpenCode, no se infieren ni se sustituyen por un alias. No use
   `--variant`. Igual que en Claude, esta invocacion directa es el smoke
   interactivo y la escritura/revision ocurren headless. Espere un PR real con
   `Closes #<issue-opencode>`, comentario del pipeline y checks requeridos
   verdes; confirme eventos de los hooks naturales correlacionables con la
   sesion. `tmux-pipeline.sh`, `herdr-pipeline.sh`, `tooling-pipeline.sh`, el
   runner neutral, writer y reviewer son transitivos, no ejecuciones manuales.
8. **Comparar y preservar.** Compruebe que cada PR cambia solo su archivo
   fixture de cinco lineas, contra el template correspondiente, y que ambos
   conservan tag, version, commit fuente, baseline y resultado. Runtime,
   modelo, IDs, timestamps y URLs son deliberadamente distintos. Compruebe que
   el pipeline copio los summaries al body de cada PR antes de retirar los
   worktrees; registre ademas el comentario del pipeline, commits y checks.

Los agentes de tooling exponen solo lectura, edicion y shell: tienen Agent
Skills y MCP denegados. Por ello `projections`,
`comment-cleanup` y `microsoft-learn` se comprueban solo por discovery separado
y no se fuerzan dentro de los issues fixture. Los hooks se descubren y se
observan en la sesion/pipeline que naturalmente los activa; no se llama un hook
como script directo. Esta distincion evita certificar una capacidad por una via
que el corte vertical no usa.

## Manifiesto de evidencia y redaccion

Guarde un manifiesto por `<run-id>` fuera del PR fixture o como artefacto privado
de su ejecucion. Debe contener solo metadatos y rutas observables:

| Campo | Requisito |
|---|---|
| timestamp y zona horaria | inicio/fin de cada paso y de cada runtime |
| argv sanitizado | programa, subcomando, flags y placeholders; sin variables ni valores sensibles |
| identidad | runtime, modelo reportado, `<tag-certificable>`, `<version>`, `<commit-fuente>`, `<checksum-opencode>` y las tres versiones de runtime |
| baseline | remoto, SHA inicial/final, estado limpio y hash de los archivos baseline |
| trazabilidad GitHub | URLs de issue y PR por runtime, SHA de rama y checks/conclusiones |
| Herdr | workspace, filas, labels, IDs de pane y runtime de cada pane; `.mefisto/pipeline/herdr-report-panes.txt` debe listar panes del mismo workspace con identidades `claude` y `opencode` |
| stages | por issue y stage: runtime, agente, perfil, modelo solicitado/efectivo, herencia, session id, resultado, version y commit fuente completos; Claude registra el camino heredado y OpenCode el override explicito |
| artefactos | rutas relativas y hash SHA-256 de streams neutrales redactados, logs derivados, metricas, `pipeline-history.jsonl`, sesiones, `events.log`, summaries y markers de release |
| veredicto | pasa/falla/bloqueado, divergencias y URL del bug si existe |

Durante writer/reviewer cada corrida conserva un unico pane de reporte de
`stream-watch.sh` filtrado por su issue. No se reutilizan ni mezclan panes,
streams, worktrees, ramas, status o logs entre los issues; esta corrida no agrega
una tercera fila ni una tercera ejecucion. La poda y reutilizacion posterior se
prueban por separado en `test-herdr-parallel.sh` y
`test-herdr-collapse-panes.sh`.

Verifique que cada stream neutral redactado tiene exactamente un terminal exitoso
y que `pipeline-history.jsonl` enlaza el PR correcto del mismo issue. No copie
prompts, system prompts, eventos `message`, inputs de tools, salida raw,
stderr, headers, auth stores, API keys o tokens. En su
lugar, registre para cada artefacto inspeccionado su ruta relativa, SHA-256,
patron, conteo y veredicto, nunca la linea coincidente. Aplique como minimo estos
centinelas case-insensitive salvo donde el patron explicite caracteres:

```text
("|')?(prompt|system[ _-]?prompt|question|confirmation|approval|raw|stderr|message|tool[ _-]?input)("|')?[[:space:]]*[:=]
(authorization|cookie|set-cookie|x-api-key)[[:space:]]*:
auth\.json|credentials|((api[_-]?key|access[_-]?token|refresh[_-]?token)[[:space:]]*[:=])
Bearer[[:space:]]+[A-Za-z0-9._~+/-]+=*|sk-[A-Za-z0-9]{16,}
```

Una coincidencia implica redaccion local antes de persistir evidencia y abre una
divergencia si no puede demostrarse que pertenece solo al propio reporte de
centinelas. La ausencia se demuestra por conteo cero sobre los artefactos ya
sanitizados, no afirmandola de memoria. Nunca se abre, copia ni sube el contenido
de un auth store: cada runtime conserva sus credenciales, conforme a
MEF-ADR-0025.

## Veredicto, fallos y limpieza

La ejecucion es fail-closed. Falla y bloquea el veredicto cualquier desalineacion
de identidad, checksum, baseline, discovery requerido, fila/pane Herdr,
contenido de fixture, PR/check, observabilidad correlacionable, prompt no
atendido o centinela no redactable. Cree un issue `tipo:bug` en Mefisto con el
manifiesto sanitizado, el paso fallido, hashes, URLs y diferencia observada;
añadalo como dependencia de #1181 y no migre ningun comando adicional mientras
siga abierto. Repita **ambas** corridas desde un baseline limpio sobre una
release nueva que contenga la correccion; una sola repeticion no restablece la
comparabilidad. El protocolo solo certifica `/mefisto:tooling`.

La limpieza corre tambien tras un fallo parcial. Tras capturar la evidencia,
cierre sin merge ambos PRs fixture y elimine sus ramas remotas; cierre ambos
issues como `not planned` con un comentario que enlace la certificacion. Retire
los worktrees de las dos corridas, restaure el baseline a su SHA inicial y
compruebe que no queda ninguno, que el arbol esta limpio y que
`<sha-baseline-final>` coincide con `<sha-baseline-inicial>`. La limpieza es
idempotente: repetirla sobre PR/issue ya cerrados, ramas ausentes o un árbol ya
restaurado no debe alterar el resultado. Restaure la instalacion
Claude/OpenCode previa cuando la corrida hubiera cambiado su release activa;
conserve los punteros y versiones previos en el manifiesto para poder verificar
esa restauracion. No pode releases ni migre otro comando como parte de esta
certificacion.

## Referencias

- MEF-ADR-0053, secciones 2, 3 y 6: instalacion versionada, identidad comparable
  y gate reproducible del corte vertical.
- MEF-ADR-0019: separacion de repositorios y routing cross-repo limitado.
- MEF-ADR-0022: baseline completo con CI hacia Azure autenticada por OIDC.
- MEF-ADR-0025: custodia de credenciales por runtime.
- MEF-ADR-0031: un gate requiere comandos y resultados repetibles, no archivos
  presentes.
- MEF-ADR-0050: el mismo comando publicado debe conservar la intencion neutral
  entre adaptadores.
- `docs/testing/herdr-workspace.md`: filas y labels canonicos del workspace.
- `src/published/scripts/install-opencode-release.sh`: contrato de instalacion,
  checksum y activacion OpenCode.
