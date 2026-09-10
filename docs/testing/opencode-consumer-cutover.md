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
| checksum OpenCode | linea SHA-256 canonica de `mefisto-opencode-v<version>.tar.gz.sha256` y resultado de su validacion |
| SHA baseline | `git rev-parse HEAD` antes de crear cada issue y el SHA final tras limpiar |
| Claude Code, OpenCode y Herdr | salida de `claude --version`, `opencode --version` y `herdr --version` |

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

1. **Preparar baseline.** Clonee el repositorio fixture, haga checkout del SHA
   baseline elegido, ejecute el diagnostico de onboarding y compruebe que el
   árbol esta limpio. Registre remoto, SHA y URL; no cree enlaces hacia Mefisto.
2. **Instalar la misma release.** En Claude Code instale/actualice Mefisto a
   `<version>` en scope `user` usando el marketplace publicado y recargue la
   sesion (`/reload-plugins`); confirme el tag y manifiesto de la distribucion
   cargada. En OpenCode ejecute el instalador publicado, no una copia del repo:

   ```bash
   mefisto-opencode install <version>
   mefisto-opencode project
   mefisto-opencode status
   ```

   El instalador descarga `mefisto-opencode-v<version>.tar.gz`, valida su
   SHA-256 contra el `.sha256` del release y activa solo una release valida e
   inmutable. Guarde el digest y el resultado, no el tarball ni datos de auth.
3. **Alinear identidad.** Desde la raiz del consumidor ejecute el diagnostico
   de la release instalada, proporcionando la raiz Claude observada y el
   `active` OpenCode cuando no sean los defaults:

   ```bash
   <ruta-clausurada>/diagnose-installation-identity.sh \
     --claude-root <raiz-clausurada> \
     --opencode-root <raiz-opencode-activa>
   ```

   `status=aligned`, `version=<version>` y `commit=<commit-fuente>` son
   precondiciones fail-closed. La ruta Claude es la de la instalacion cargada,
   no una ruta de checkout; obtengala del marker canonico de release o de la
   propia sesion despues del reload.
4. **Discovery separado.** En cada runtime descubra y registre, sin crear el
   issue ni ejecutar tooling: comandos, agentes, Agent Skills, scripts/runner,
   permisos, hooks y MCP. Para Claude use las pantallas/listados del plugin y
   sus markers de hook; para OpenCode inspeccione los listados CLI y las rutas
   globales proyectadas (`commands`, `agents`, `skills`, `plugins`). Registre
   tambien que `microsoft-learn` aparece como MCP bundleado. Discovery prueba
   disponibilidad, no ejercita una tool MCP ni un hook ajeno al flujo.
5. **Workspace Herdr.** Una vez por baseline alineado, ejecute la invocacion
   real distribuida:

   ```bash
   <raiz-clausurada>/scripts/herdr-workspace.sh <ruta-del-consumidor>
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

   Espere su PR real, URL y checks terminales. El comando despacha
   transitivamente `tooling-writer` y `tooling-reviewer`; no se invocan esos
   agentes como comandos directos.
7. **Fila OpenCode.** Con el baseline restaurado al SHA inicial, cree el issue
   OpenCode y anote su URL. Desde la sesion OpenCode instalada ejecute
   directamente:

   ```text
   /mefisto:tooling <issue-opencode>
   ```

   Espere su PR real, URL y checks terminales. Tambien aqui writer y reviewer
   son transitivos, no ejecuciones manuales.
8. **Comparar.** Compare ambos PRs contra el template correspondiente, sus
   checks, eventos, metricas, sesiones, logs y marcador de identidad. Deben
   concordar en tag, version, commit fuente, baseline, alcance determinista y
   resultado; runtime, modelo, IDs, timestamps y URLs son deliberadamente
   distintos.

Los agentes de tooling tienen `skill` y MCP denegados. Por ello `projections`,
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
| identidad | runtime, modelo reportado, `<tag-certificable>`, `<version>`, `<commit-fuente>`, checksum OpenCode |
| baseline | remoto, SHA inicial/final, estado limpio y hash de los archivos baseline |
| trazabilidad GitHub | URLs de issue y PR por runtime, SHA de rama y checks/conclusiones |
| Herdr | workspace, filas, labels, IDs de pane y runtime de cada pane |
| artefactos | rutas relativas a logs, metricas, sesiones, eventos, summaries y markers de release |
| veredicto | pasa/falla/bloqueado, divergencias y URL del bug si existe |

No copie salida raw, stderr, headers, auth stores ni tokens. En su lugar,
registre para cada archivo de salida inspeccionado un resultado de ausencia con
conteo de coincidencias y hash del archivo, aplicando al menos estos centinelas
(sensibles a mayusculas cuando corresponda):

```text
prompt|question|confirm|approve
raw|stderr
authorization:|cookie:|set-cookie:|x-api-key:|header
auth.json|credentials|api[_-]?key|access[_-]?token|refresh[_-]?token
Bearer[[:space:]]+|sk-[A-Za-z0-9]{16,}
```

Una coincidencia implica redaccion local antes de persistir evidencia y abre una
divergencia si no puede demostrarse que es solo el nombre del centinela. Nunca se
abre, copia ni sube el contenido de un auth store: cada runtime conserva sus
credenciales, conforme a MEF-ADR-0025.

## Veredicto, fallos y limpieza

La ejecucion es fail-closed. Falla y bloquea el veredicto cualquier desalineacion
de identidad, checksum, baseline, discovery requerido, fila/pane Herdr,
contenido de fixture, PR/check, observabilidad correlacionable, prompt no
atendido o centinela no redactable. Cree un issue `tipo:bug` en Mefisto con el
manifiesto sanitizado, el paso fallido, hashes, URLs y diferencia observada; no
migre ningun comando adicional mientras ese bug siga abierto. El protocolo solo
certifica `/mefisto:tooling`.

Tras capturar la evidencia, cierre sin merge ambos PRs fixture y sus issues,
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
