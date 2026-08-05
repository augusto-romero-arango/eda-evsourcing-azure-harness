---
fecha: 2026-08-03
hora: 23:50
sesion: mefisto-planner
tema: Refinamiento de #458 (.dockerignore del build context del worker de proyecciones)
---

## Contexto

Sesion abierta con la pregunta "que refinar a continuacion". Backlog: 1 issue `estado:listo`
(#430, 7 dias sin entrar a batch) y 5 drafts. Verificado que **ninguno esta bloqueado**: las
dependencias de ordenacion de los cinco ya estan cerradas (#436, #433, #453, #457, #452).

Este planner recomendo **#483** (los 7 hallazgos del primer read-side real) por ser el unico que
corrige doctrina **activa y equivocada** en vez de una ausencia -- `skills/projections/modelos-marten.md:8`
dirige hoy a N2 con `Identities` para un caso que verificadamente no puede expresarse asi, y
MEF-ADR-0035:76 invita a agregar un `PackageReference` innecesario. El usuario eligio **#458**,
el mas barato de los cinco (un solo punto abierto). Queda #483 como el candidato siguiente.

## Descubrimientos

**El hallazgo que cambio el issue (verificado por ejecucion, Docker 28.5.1, no por lectura):**

Los patrones de `.dockerignore` **no son los de `.gitignore`**. Probado sobre un contexto con
`src/App/bin/leak.txt` y `src/App/obj/leak.txt`:

| `.dockerignore` | Resultado |
|---|---|
| `bin/` + `obj/` | los dos `leak.txt` **ENTRAN** al contexto |
| `**/bin/` + `**/obj/` | excluidos; `keep.cs` preservado |

Un patron sin `**/` solo casa en la **raiz** del contexto, y en el layout del marco no hay ningun
`bin/`/`obj/` en la raiz (viven bajo `src/` y `tests/`). Consecuencia: implementar este issue
copiando los patrones del `.gitignore` raiz de `infra-base-scaffolder` -- la tentacion natural, y
lo que sugeria la lista de candidatos del borrador -- **produce un archivo inerte**: contexto
sigue en 1330 MB, build sigue verde, nadie se da cuenta. Es la misma forma de falla silenciosa
que #452 (pin enmascarado hasta el `dotnet build`) y que el `partial` de MEF-ADR-0035 seccion 2.
Por eso el contenido quedo byte-fijo (CA-2) y los `**/` son criterio de aceptacion propio (CA-3),
no un detalle de estilo.

**Otros hechos verificados en el repo:**

- El marco **no emite** ningun `Directory.Build.props`, `Directory.Packages.props` ni
  `nuget.config` (grep vacio en `agents/`, `scripts/`, `commands/`). Refuerza "exclusiones, nunca
  allowlist" con un argumento mas fuerte que el sample de Microsoft: hoy no hay archivo raiz de
  MSBuild que una allowlist dejaria fuera, pero un scaffolder futuro que emita uno romperia el
  build en silencio.
- Sin `SourceLink` ni `GitVersioning` en el marco, y el Dockerfile no corre `git` (el SHA entra
  por `--build-arg SOURCE_REVISION_ID`, issue #462) -> **excluir `.git/` es seguro**.
- `agents/*` ya esta en el blocklist publicado (`scripts/_pipeline-common.sh:609`) y en la
  allowlist interna (`.claude/scripts/_mefisto-common.sh:75`) -> **no aplica el corte en dos PRs
  de MEF-ADR-0019 seccion E**.
- El `.gitignore` raiz del marco es incompleto para este proposito por otra razon ademas de los
  patrones: no lista `.terraform/` ni `*.tfstate` (viven en el `.gitignore` **del entorno**,
  Paso 2.5) ni `node_modules/`.

## Decisiones

1. **Eje C amplio.** El punto abierto "que excluir exactamente" se reformulo en **tres ejes con
   exigencia distinta**: A-correccion (`bin/`, `obj/` -- si falta uno el build *puede fallar*),
   B-secretos (MEF-ADR-0025 -- si falta uno una credencial queda en la capa del builder), y
   C-rendimiento (si falta uno el build es mas lento pero *correcto*). Solo el eje C requeria
   decision. Se eligio amplio, incluyendo `node_modules/` y `.idea/` que el marco no crea, por
   **asimetria de costos**: una linea que no casa con nada es inerte (costo cero); omitirla cuesta
   los 512 MB por build medidos. El precio es ruido documental, pagado con un comentario.
2. **Retrofitable, no greenfield-only** -- corrige el borrador, que heredaba el alcance de #452.
   La analogia no transfiere: #452 modificaba un archivo **existente** (retrofit exigia
   sobrescribir); el `.dockerignore` esta **ausente** (crearlo no pisa nada). Razon de fondo: el
   caso a arreglar es por definicion el **repo maduro** -- un greenfield nace sin `bin/`, sin
   `obj/` poblado y sin `.terraform/`; los 1330 MB aparecen tras semanas de uso. Greenfield-only
   arreglaria justo el caso donde el problema no duele. El efecto 2 (divergencia local-vs-CI)
   tampoco se puede cerrar greenfield-only: por definicion requiere artefactos previos.
3. **El gate del `.dockerignore` debe ser independiente del gate del Dockerfile** (CA-1). Modo de
   falla concreto: el Paso 2 abre con `test -f Dockerfile && echo "EXISTE (omitir)"`; si el
   artefacto nuevo se anida ahi, **exactamente los consumidores que sufren el problema nunca lo
   reciben**. Precedente exacto en la linea 189 de ese agente: *"Gatear el paso completo dejaria
   esos dos huecos abiertos para siempre"*.
4. **Contenido byte-fijo**, misma regla 12 de `infra-base-scaffolder` (issue #241). La lista no
   depende de ningun token -- `<RootNamespace>` no aparece en ella.
5. **Excluir artefactos, nunca proyectos.** No se excluyen `src/` ni `tests/` aunque el Dockerfile
   compile el `.csproj` del worker directo. Razon nueva: el hueco abierto del read-side (los tipos
   de evento de la proyeccion viven hoy en el assembly del Function App, MEF-ADR-0034 seccion 5,
   sin dueno segun la sesion del 2026-07-31) implica que el worker **puede llegar a referenciar**
   `src/<RootNamespace>.<Dominio>`; una exclusion por "que proyectos no necesita el build"
   romperia en silencio cuando eso se resuelva.
6. **Dueno confirmado: `projections-scaffolder`** (no `infra-base-scaffolder`, que corre siempre y
   emitiria el archivo en repos sin Dockerfile). Consecuencia aceptada y anotada: dos agentes
   escriben dos archivos-lista en la raiz con contenido solapado y nada los sincroniza.
7. **Calibracion registrada en el issue**: retrofitable != arreglado. Nadie re-corre
   `/scaffold-projections` sin motivo; el valor es acumulativo. Y para `Bitakora` el beneficio
   inmediato es **nulo** (ya lo cubre en su #260): esto es para el proximo BC con proyecciones.

## Descartado

- **Derivar la lista del `.gitignore` raiz del marco**: produce un archivo inerte (ver
  Descubrimientos) y esa lista es ademas incompleta para este proposito.
- **Allowlist con `*` + reinclusiones**: el build necesita `global.json` (issue #452) y los
  `.csproj`/`.cs` de `Projections`/`ReadModels`.
- **Excluir `tests/` y los `src/` no-worker** (decision 5).
- **`Dockerfile.dockerignore` junto al Dockerfile**: tiene precedencia sobre el de la raiz, lo que
  lo vuelve un modo de falla silenciosa; se eligio la raiz y el caveat de precedencia quedo
  documentado **dentro** del archivo generado.
- **Meter la deteccion del hueco en `/onboard`** para convertir "retrofitable" en "arreglado":
  otro componente, romperia la regla de un componente principal por issue. Precedente de dejarlo
  aparte en la sesion del 2026-07-31 (*"Retro-cablear dominios ya scaffoldeados: candidato a issue
  propio de `/onboard`, no se abrio"*).
- **Label `bug`**: es un artefacto faltante, no una regresion; coherente con `changelog.d/458.added.md`.

## Preguntas abiertas

- **Defecto detectado de paso: abierto como #485** (ver "Correcciones posteriores" al final de esta
  nota, donde se rectifica el diagnostico inicial y la decision de donde dejarlo).
- Si del patron de #452/#453/#457/#458 sale doctrina (**que artefactos perifericos debe emitir un
  scaffolder de worker**) en vez de cuatro parches sueltos. Los cuatro ya estan resueltos o listos;
  la pregunta la heredaba el borrador y sigue sin dueno.
- ~~**#430 lleva 7 dias en `estado:listo` sin entrar a ningun batch**~~ -- **resuelto durante la
  sesion**: PR #484 se mergeo a las 04:32 del 2026-08-04 y cerro el issue automaticamente
  (`CLOSED COMPLETED`, con `Closes #430` correctamente declarado). Este planner llego a afirmar
  despues que seguia abierto, **contradiciendo su propio listado**, que ya no lo incluia. Error de
  lectura, no de datos.

## Referencias

Issues refinados: **#458** -- de `estado:borrador` a `estado:listo`, retitulado de "Emitir el
.dockerignore del worker de proyecciones desde projections-scaffolder" a "Emitir el .dockerignore
del **build context** desde projections-scaffolder" (el titulo anterior inducia a la ubicacion
descartada: junto al worker en vez de la raiz del build context).

Issues creados: **#485** (creado `estado:borrador`, refinado a `estado:listo` en la misma sesion) -- Alinear el trato de `pipeline-state/` con
MEF-ADR-0017 en el scaffold y en tooling-pipeline.
Issues cerrados: ninguno.

Fuente de campo: consumidor `augusto-romero-arango/Bitakora.ControlAsistencia`, issue #260
(`estado:listo`), que trae las mediciones (1330 MB / 39.131 archivos).
Verificacion propia: ejecucion local con Docker 28.5.1 (2026-08-03) del comportamiento de los
patrones `**/` en `.dockerignore`; probe desechable, ya limpiado.

## Correcciones posteriores (misma sesion)

El usuario pregunto por que el hallazgo de `pipeline-state/` se habia quedado anotado dentro del
body de #458 en vez de tener issue. Al justificar la decision aparecieron **tres errores propios**,
dos de metodo y uno de diagnostico:

1. **Error de metodo: grep truncado tratado como exhaustivo.** El primer
   `grep -rn "pipeline-state" agents/ scripts/ commands/ docs/adr/ | head -10` se llevo el cupo con
   los 8 hits de `agents/test-writer.md` y `scripts/tooling-pipeline.sh`, y de ahi se concluyo que
   no habia mas sitios. Falso: `scripts/tdd-pipeline.sh:442` tambien lo usa -- **es quien lee la
   senal**. La conclusion central se sostuvo (el `.gitignore` byte-fijo no lista el directorio,
   `grep -c` = 0, y nadie lo agrega despues), pero la enumeracion de sitios era incompleta.
   **Leccion**: no truncar con `head` un grep cuyo resultado se va a tratar como censo.

2. **Error de diagnostico: se culpo al sitio equivocado.** La anotacion original decia que
   `agents/test-writer.md:255` afirmaba algo falso. Al leer MEF-ADR-0017 completo resulto que su
   seccion Decision declara literalmente *"**Gitignore**: `pipeline-state/` se ignora en
   `.gitignore`. La senal es estado transitorio del pipeline, no debe versionarse"* y *"**No se
   commitea la senal**"*. Es decir, `test-writer.md` **cita fielmente el ADR**; el defecto es que
   la clausula no se implemento. Los sitios en falta son otros dos, verificados:
   `agents/infra-base-scaffolder.md` Paso 2c (no la implementa) y `scripts/tooling-pipeline.sh`
   lineas 459-461/524 (la **contradice**, incluyendo `pipeline-state/` en su `git add`).
   `scripts/tdd-pipeline.sh:612-613` cumple (su `auto_commit_if_needed` solo agrega `tests/ src/`).
   **Leccion**: antes de declarar que un agente afirma algo falso, leer el ADR que ese agente cita.

3. **Error de criterio: "documentarlo dentro de #458" era la peor de las tres opciones.** Un issue
   se cierra y se archiva; un hallazgo enterrado en el body de un issue cerrado no lo vuelve a leer
   nadie. Si merece arreglo, merece issue propio; si no, no merece nada. El limbo elegido era la
   unica opcion que garantizaba perderlo. Rectificado: se abrio **#485** y la nota dentro de #458 se
   reemplazo por una referencia de una linea a ese numero.

Lo que **si** se sostuvo del razonamiento original: la razon para no meterlo en el *alcance* de #458.
Son componentes distintos, y sobre todo sus alcances son **opuestos** -- el `.dockerignore` es un
archivo ausente (creable en un repo existente, de ahi la decision 7 de arriba), mientras el
`.gitignore` raiz ya existe y es byte-fijo con "NUNCA sobrescribir", asi que su correccion es
greenfield-only por construccion. Mezclarlas habria metido dos decisiones de alcance contradictorias
en un mismo issue.

**Calibracion del impacto de #485** (para no inflarlo al refinar): bajo. La senal vive en el
worktree, que es efimero; no contiene secretos; y en el carril TDD nada se commitea hoy. Lo que
justifica el issue es la divergencia entre un ADR aceptado y el codigo, no un dano medible.

## Segunda parte: refinamiento de #485 (misma sesion)

El usuario pidio refinar el draft recien creado. **El diagnostico cambio tres veces mas**, y el
issue final se parece poco al draft. Todo verificado, nada de memoria.

### Descubrimientos

- **La clausula del ADR es mas fuerte de lo que decia el draft.** MEF-ADR-0017 no solo decide que
  el directorio se gitignorea (`:53`): **enumera la accion** en su lista de implementacion (`:96`,
  *"`.gitignore`: se anade `pipeline-state/`"*) y ademas **apoya una mitigacion en ella** (`:115-116`:
  *"mas visible para quien inspecciona el directorio. Mitigacion: gitignored"*). La mitigacion
  declarada no existe.
- **El incumplimiento es total, no parcial**: ni el `.gitignore` del **propio repo Mefisto** lo lista
  (dato nuevo -- el draft solo miraba el del consumidor), ni el byte-fijo que emite
  `infra-base-scaffolder`. El harness incumple en casa la clausula que publica.
- **`git add <dir-ignorado>` sale con exit 1** -- verificado en repo desechable; no es un no-op
  silencioso. Eso hacia temer que implementar el gitignore rompiera el auto-commit de tooling.
  **No lo rompe**: el bucle de `tooling-pipeline.sh:461-463` lleva `2>/dev/null || true`, que traga
  el exit 1 y neutraliza ahi el `set -euo pipefail` de la linea 14. Por eso los tres sitios se
  pueden corregir en un solo PR, sin orden forzado.
- **El acoplamiento real estaba en otra linea de la que sospechaba el draft.** No es el `git add`
  (`:461`, que queda inerte) sino los `git status --porcelain` de `:459`/`:526`/`:548`: `git status`
  **no reporta ignorados**, y `:526`/`:548` alimentan `HAS_UNSTAGED`, que dispara el abort *"El
  writer no genero ningun cambio"*. Un agente de tooling que produjera **solo** una senal ahi haria
  abortar el pipeline diciendo que no produjo nada. Latente: censo completo confirma que el unico
  agente que escribe ahi es `test-writer.md`, del carril TDD.
- **La pregunta abierta del draft quedo respondida por el historial.** `git log -S` sobre esas
  lineas: entraron con `8918853` (*"feat(scope-gate): sanear /tooling publicado y restringirlo al
  consumidor"*, 2026-05-15), el commit que enumero las rutas del consumidor -- respaldadas por
  **MEF-ADR-0019:37**. No fue copia-paste: fue una allowlist deliberada. Lo que nunca fue decision
  es el versionado -- el auto-commit **reusa una misma lista de directorios para dos propositos**
  (detectar cambios con `git status` y anadirlos con `git add`), y `pipeline-state/` se arrastro al
  segundo por venir en la misma lista.
- **Sospecha propia refutada por verificacion**: se penso que `.gitignore` (raiz) no estaria en la
  allowlist interna y que aplicaria el corte en dos PRs de MEF-ADR-0019 seccion E. **Falso**:
  `_mefisto-common.sh:79` lo incluye en la fila de gobierno del repo
  (`README.md|CHANGELOG.md|CLAUDE.md|.gitignore`). No aplica el corte. Verificar antes de escribir
  el caveat evito meter una restriccion inexistente en el issue.

### Decisiones

1. **Conservar la allowlist de escritura y documentar el acoplamiento** (opcion 1 de tres ofrecidas
   al usuario, elegida por el). Razon: dos ADRs abrieron esa puerta a proposito -- MEF-ADR-0019:37
   lista la ruta como escribible por los skills publicados, y MEF-ADR-0017:107 la declara *"un buen
   punto de extension futuro para otras senales o metadata del pipeline"*. Cerrarla para eliminar un
   riesgo latente costaria enmendar un ADR; un comentario junto al gate cuesta tres lineas.
2. **`agents/test-writer.md` no se toca**: cumple, y su cita del ADR es correcta.
3. **MEF-ADR-0017 no se enmienda**: ya dice lo correcto; solo faltaba ejecutarlo. El acoplamiento se
   documenta **donde se lee** (junto al gate que lo sufre), no en el ADR -- lo que ademas evita el
   fragmento `changelog.d/<issue>.adr-index.md`.
4. **No se parte** pese a tocar tres archivos en dos lados: es la misma correccion (una entrada de
   lista) de la misma clausula del mismo ADR, ninguno depende de otro, cada uno es verificable solo,
   y partirlo produciria un issue de una linea. Eje homogeneo declarado en el issue.
5. **Greenfield-only para el consumidor, como deuda declarada**: el `.gitignore` raiz ya existe y es
   byte-fijo con "NUNCA sobrescribir" (regla 12, issue #241), asi que `Bitakora` no recibe la linea
   por ninguna via automatica. Es el **inverso exacto** del alcance de #458, y la confirmacion de
   que separar los dos issues fue correcto.
6. **Label `bug`**: es una clausula de ADR incumplida, no una mejora (coherente con
   `changelog.d/485.fixed.md`), aunque el impacto medible sea nulo hoy.

### Descartado

- **Quitar `pipeline-state/` de las allowlists de escritura de `/tooling`**: enmendaria
  MEF-ADR-0019:37.
- **Enmendar MEF-ADR-0017 para acotar la clausula al carril TDD**: invierte una decision aceptada
  sin evidencia de que alguien necesite versionar una senal.
- **Quitar las menciones de los tres `git status`**: funcionalmente equivalente a dejarlas (git
  status no ve ignorados). Se dejan **y se comentan**: el comentario es donde vive el valor.
- **Abrir issue para el retrofit de consumidores existentes** (fila en `/onboard`): impacto nulo;
  queda como pregunta abierta.

### Preguntas abiertas de esta parte

- Si el retrofit del `.gitignore` en consumidores ya scaffoldeados merece una fila en `/onboard`.
  Es el **segundo** hallazgo de la sesion que apunta a lo mismo (el primero fue el de #458), y el
  tercero contando la nota del 2026-07-31 sobre dominios ya scaffoldeados. **Empieza a parecer un
  patron con dueno propio, no tres notas suelas.**
- El auto-commit de `tooling-pipeline.sh` reusa una sola lista de directorios para detectar y para
  anadir. Este issue corrige el sintoma en una entrada; si esa doble funcion vuelve a morder,
  separarla en dos listas es candidato a issue propio.
