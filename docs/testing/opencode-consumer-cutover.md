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

El baseline versionado minimo contiene:

- `AGENTS.md` conforme al contrato del harness;
- el puente `CLAUDE.md` con la unica linea `@AGENTS.md`;
- `.mefisto/harness.config.json`;
- `.gitignore` que excluye `.mefisto/pipeline/` sin excluir el config;
- CI minima que ejecuta los guards aplicables; y
- labels `tipo:tooling` y `estado:listo` (ademas de los labels que el
  onboarding requiera).

La provision y el diagnostico ocurren **desde el clone de ese consumidor**. No
se admite como instalacion ni como evidencia un checkout, worktree, enlace
simbolico, copia parcial o ruta absoluta del repositorio de Mefisto. Esto evita
que el cwd, una fuente mutable o un cache local reemplacen la release versionada
(MEF-ADR-0053, decisiones 2 y 6).

Antes de abrir issues se registra este conjunto de parametros inmutables:

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

## Matriz de corridas e issues fixture

Se abren **dos issues distintos**, ambos en el consumidor, con labels
`tipo:tooling` y `estado:listo`: uno para Claude y uno para OpenCode. Cada issue
produce su propia rama y PR. Esa separacion hace comparables las dos ejecuciones
sin compartir worktree, logs, estado de pipeline ni commit de salida. No se usa
`--variant`: una variante conserva una rama local y no abre PR, por lo que no
ofrece la evidencia independiente requerida por el gate.

Defina `<run-id>` como `YYYYMMDD-HHMMSS-<tag-certificable>` normalizado (sin la
`v` inicial si se necesita un nombre de archivo portable). Las plantillas son
intencionalmente identicas salvo por runtime, ruta y contenido esperado.
Al crear cada uno se pasan ambos labels de forma explicita, por ejemplo con
`gh issue create --repo augusto-romero-arango/mefisto-consumer-certification
--label tipo:tooling --label estado:listo --title <titulo> --body-file
<template-runtime.md>`. La salida de ese comando fija `<issue-claude>` o
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
3. **Alinear identidad.** Desde la raiz del consumidor ejecute el diagnostico
   de la release instalada, proporcionando la raiz Claude observada y el
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
   `commit=<commit-fuente>` son precondiciones fail-closed. La ruta Claude es la de la instalacion cargada,
   no una ruta de checkout; obtengala del marker canonico de release o de la
   propia sesion despues del reload.
4. **Discovery separado.** En cada runtime descubra y registre, sin crear el
   issue ni ejecutar tooling: comandos, agentes, Agent Skills, scripts/runner,
   permisos, hooks y MCP. Para Claude use `/help`, `/agents`, `/skills`,
   `/hooks` y `/mcp`, ademas del inventario de la raiz cargada. Para OpenCode
   use `opencode debug config`, `opencode agent list` y las rutas globales
   proyectadas (`commands`, `agents`, `skills`, `plugins`); compruebe tambien
   que el estado del proyector no reporte capacidades ausentes. Registre en
   ambos `tooling`, `tooling-writer`, `tooling-reviewer`, `projections`,
   `comment-cleanup`, los scripts del cierre, los permisos efectivos, el
   adaptador de hooks y `microsoft-learn`. Discovery prueba disponibilidad, no
   ejercita una tool MCP ni un hook ajeno al flujo. Si una version del runtime
   no ofrece alguno de esos listados, registre el comando de discovery
   equivalente realmente usado; no sustituya discovery por presencia de
   archivos.
5. **Workspace Herdr.** Una vez por baseline alineado, ejecute la invocacion
   real distribuida:

   ```bash
   <raiz-claude-instalada>/scripts/herdr-workspace.sh <ruta-del-consumidor>
   ```

   Compruebe la fila superior `planner [claude]`/`ejecucion [claude]`, la
   inferior `planner [opencode]`/`ejecucion [opencode]`, sus panes separados y
   `MEFISTO_RUNTIME` heredado. Herdr monta y enfoca; no sustituye las dos
   ejecuciones independientes de abajo.
6. **Fila Claude.** Cree el issue con el template Claude desde el consumidor y
   anote su URL. Desde la sesion Claude instalada ejecute directamente:

   ```text
   /mefisto:tooling <issue-claude>
   ```

   Esta invocacion directa es el smoke interactivo de la fila; el pipeline que
   lanza ejecuta en print mode headless. Espere su PR real, URL y checks
   terminales y confirme que los hooks naturales de inicio, cambios y cierre
   dejaron eventos correlacionables con la sesion. El comando despacha
   transitivamente `tmux-pipeline.sh`, `tooling-pipeline.sh`, el runner neutral,
   `tooling-writer` y `tooling-reviewer`; no invoque directamente ninguno de
   esos scripts o agentes.
7. **Fila OpenCode.** Con el baseline restaurado al SHA inicial, cree el issue
   OpenCode y anote su URL. Desde la sesion OpenCode instalada ejecute
   directamente:

   ```text
   /mefisto:tooling <issue-opencode>
   ```

   Igual que en Claude, esta invocacion directa es el smoke interactivo y la
   escritura/revision ocurren headless. Espere su PR real, URL y checks
   terminales; confirme eventos de los hooks naturales correlacionables con la
   sesion. `tmux-pipeline.sh`, `tooling-pipeline.sh`, el runner neutral, writer y
   reviewer son transitivos, no ejecuciones manuales.
8. **Comparar.** Compare ambos PRs contra el template correspondiente, sus
   checks, eventos, metricas, sesiones, logs y marcador de identidad. Deben
   concordar en tag, version, commit fuente, baseline, alcance determinista y
   resultado; runtime, modelo, IDs, timestamps y URLs son deliberadamente
   distintos.

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
| Herdr | workspace, filas, labels, IDs de pane y runtime de cada pane |
| artefactos | rutas relativas a logs, metricas, sesiones, eventos, summaries y markers de release |
| veredicto | pasa/falla/bloqueado, divergencias y URL del bug si existe |

No copie prompts ni salida raw, stderr, headers, auth stores o tokens. En su
lugar, registre para cada artefacto inspeccionado su ruta relativa, SHA-256,
patron, conteo y veredicto, nunca la linea coincidente. Aplique como minimo estos
centinelas case-insensitive salvo donde el patron explicite caracteres:

```text
("|')?(prompt|question|confirmation|approval|raw|stderr)("|')?[[:space:]]*[:=]
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
manifiesto sanitizado, el paso fallido, hashes, URLs y diferencia observada; no
migre ningun comando adicional mientras ese bug siga abierto. El protocolo solo
certifica `/mefisto:tooling`.

La limpieza corre tambien tras un fallo parcial. Tras capturar la evidencia,
cierre sin merge ambos PRs fixture y sus issues,
elimine las ramas remotas si la politica del consumidor lo permite y restaure el
baseline a su SHA inicial. Compruebe limpieza e igualdad del baseline final. La
limpieza es idempotente: repetirla sobre PR/issue ya cerrados, ramas ausentes o
un árbol ya restaurado no debe alterar el resultado. Restaure la instalacion
Claude/OpenCode previa cuando la corrida hubiera cambiado su release activa;
conserve los punteros y versiones previos en el manifiesto para poder verificar
esa restauracion. No pode releases ni migre otro comando como parte de esta
certificacion.

## Referencias

- MEF-ADR-0053, secciones 2, 3 y 6: instalacion versionada, identidad comparable
  y gate reproducible del corte vertical.
- MEF-ADR-0019: separacion de repositorios y routing cross-repo limitado.
- MEF-ADR-0025: custodia de credenciales por runtime.
- MEF-ADR-0031: un gate requiere comandos y resultados repetibles, no archivos
  presentes.
- MEF-ADR-0050: el mismo comando publicado debe conservar la intencion neutral
  entre adaptadores.
- `docs/testing/herdr-workspace.md`: filas y labels canonicos del workspace.
- `src/published/scripts/install-opencode-release.sh`: contrato de instalacion,
  checksum y activacion OpenCode.
