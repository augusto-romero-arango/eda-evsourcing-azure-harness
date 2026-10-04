---
fecha: 2026-10-03
hora: "09:20"
sesion: mefisto-planner
tema: "Mapa de permisos OpenCode y autonomía desatendida en consumidores"
---

# Mapa de permisos para una operación desatendida de Mefisto

## Contexto

El mantenedor solicita analizar todas las interacciones de Mefisto en consumidores y eliminar los bloqueos accidentales de permisos: un lote no debe depender de que alguien apruebe una herramienta durante su ejecución. El objetivo operativo es una dark factory.

Durante el análisis reportó un caso vivo en Control Asistencia, usando la release 0.40.2: `/sequential` pidió aprobación al ejecutar `Grep "tipo:refactor|tdd-pipeline|tooling-pipeline|resolve.*pipeline"` sobre `~/Library/Application Support/mefisto/releases/0.40.2/scripts`. Leer el código de la release es una operación necesaria, no una excepción inesperada.

Base examinada: checkout de Mefisto en `b1983395acf4` (`chore(release): v0.40.2`), catálogo de 27 comandos neutrales y 22 agentes publicados, dos Agent Skills publicados, contratos, adaptadores, instalador/proyector, hooks, runner, pipelines y pruebas pertinentes. El análisis es del harness; no se inspeccionaron archivos, configuración sensible ni transcripts del consumidor. No se cambiaron permisos ni código.

Después de la primera entrega documental, el usuario pidió crear los issues. Se continuó con la misma identidad de sesión; el checkout había avanzado por trabajo ajeno a `e0343b31ef98`. Se revisó ese delta y se verificó que no cambiaba las causas de permisos examinadas. Los 15 issues creados y su preparación se registran más abajo. En esa fase no se adoptaron decisiones de arquitectura pendientes ni se implementó código; el refinamiento posterior de #1820 sí fijó las decisiones explícitas que constan en su apartado.

Identidad estable de sesión: `2026-10-03-0920-23-b1983395acf4-84937`. La inicialización compuesta fue denegada por la política interna; fecha, SHA y PID se obtuvieron mediante consultas individuales permitidas y se conservaron para el cierre. Ese incidente interno no se extrapola como política del consumidor.

## Descubrimientos

### 1. Cinco planos que deben funcionar juntos

1. **Entrada interactiva:** el agente que recibe `/mefisto:*`, antes de lanzar cualquier pipeline.
2. **Delegación:** `task`, el agente destino, sus Skills/MCP y las restricciones de sesión heredadas.
3. **Etapa headless:** una nueva invocación del runtime con su agente, configuración y cwd de worktree.
4. **Orquestación mecánica:** scripts que crean worktrees, ejecutan verificaciones, generan PRs, mergean, observan CI y limpian. Sus procesos hijos no son llamadas individuales a tools del LLM.
5. **Entorno y servicios:** sistema operativo, red, herramientas instaladas, autenticación, autorizaciones GitHub/Azure y reglas de CI.

Permitir una herramienta en un plano no autoriza automáticamente los demás. Un permiso OpenCode tampoco concede acceso a GitHub, ni satisface una confirmación deliberada escrita en el body de un comando.

### 2. Diagnóstico del caso de la release

**Confirmado en el harness:**

- `src/published/contract/opencode-permissions.json:5-16` ya permite el directorio de datos macOS y su equivalente Linux para agentes con `read` o `shell`; el arreglo viene de #1761, cerrado el 2026-10-02. Los 22 agentes publicados reciben esa excepción.
- `src/published/commands/sequential.md:1-9` no declara `agent` ni `capabilities`. Su salida `dist/opencode/commands/mefisto:sequential.md:1-4` solo declara `description`.
- El adaptador genera `permission` para `kind=agent`, no para comandos (`src/published/scripts/adapters/adapter-opencode.sh:530-545`). Ninguno de los 27 comandos actuales declara un agente de ejecución en su metadata; algunos delegan puntualmente desde su body.
- OpenCode documenta que un comando sin `agent` se ejecuta con el agente actual. Sus permisos efectivos, no los de un agente que el pipeline lanzará después, gobiernan el Grep inicial.
- El proyector instala enlaces a comandos/agentes/Skills/plugins; conserva la configuración del usuario y no configura los permisos generales de la sesión (`project-opencode-release.sh:161-201`, MEF-ADR-0053.2).
- El código oficial de `grep` pide permiso para el patrón de búsqueda y después comprueba `external_directory`. El candidato externo para este caso es el directorio absoluto terminado en `scripts/*`. Tener `grep: allow` no basta.

**Conclusión:** hay una brecha verificable de cobertura entre el comando iniciador y los agentes publicados. Es una explicación consistente con el prompt reportado, no una atribución forense definitiva: faltan el agente activo, versión efectiva de OpenCode, regla ganadora y estado de carga/proyección de esa sesión. No se debe concluir simplemente que «0.40.2 no incluye #1761», ni recomendar actualizar otra vez a la misma release.

La prueba de aceptación debe usar exactamente ese Grep desde `/sequential`, en una sesión nueva, sin aprobaciones recordadas, y repetir la lectura desde un agente delegado y una etapa headless.

### 3. Brechas adicionales

| ID | Hallazgo | Evidencia y alcance |
|---|---|---|
| F1 | La entrada de los comandos depende de permisos ajenos a Mefisto | Caso anterior; afecta no solo a `sequential`, también a comandos de scaffold, diagnóstico, documentación y mantenimiento. |
| F2 | Las rutas personalizadas de instalación están fuera de la excepción | El contrato de permisos documenta explícitamente que `XDG_DATA_HOME`/`XDG_CONFIG_HOME` no estándar quedan denegados. El instalador sí soporta esos overrides y `OPENCODE_CONFIG_DIR` (MEF-ADR-0053.2). |
| F3 | Dependencias y temporales necesarios no están representados | `test-writer.md:182-191` consulta NuGet y genera `/tmp/cosmos-testing-decompiled`; `reviewer.md:250-253` usa `/tmp/decompiled-critterstack`; `bug-investigator.md:117-132` consulta `~/.nuget/packages`. La lectura nativa de esos recursos no está en la lista externa. No se afirma que OpenCode inspeccione todos los argumentos de `ilspycmd`: el bloqueo puede aparecer al leer su salida. |
| F4 | Bash se autoriza por formas textuales incompletas | El mapping permite `${MEFISTO_PACKAGE_ROOT}/scripts/*` sin comillas ni asignación previa; el adaptador emite `MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/..."`. También existen resolutores que emiten `export MEFISTO_CONFIG_PATH`/`MEFISTO_INSTRUCTIONS_PATH` sin regla propia y `test-writer` usa `cut`, ausente del mapping. Debe contrastarse cada candidato que realmente evalúa el parser, no asumir que todos los nodos shell se tratan igual. |
| F5 | El simulador Bash no certifica el parser real | `test-opencode-bash-permissions.sh:38-55,125-129` quita asignaciones/redirecciones y solo extrae el preámbulo de release y bloques `test -f` de `test-writer`. El código oficial consultado en `shell.ts` usa `source(node)`, incluido `redirected_statement`, como candidato. Esa diferencia invalida tratar el simulador como equivalencia empírica del runtime. |
| F6 | La delegación depende del agente desde el que se invoque un comando | Los 22 agentes carecen de capacidad neutral `task` y reciben `task: deny`; comandos como `bitacora`, `bug`, `infra-base`, `scaffold-mcp` e `install-apim` sí solicitan delegación. Ejecutarlos desde un agente Mefisto puede fallar antes de invocar el destino. El contrato asume que la sesión primaria dispone de la tool (`contract/README.md:259-266`), pero eso no garantiza autorización y deja pendiente su verificación empírica. |
| F7 | No hay separación suficiente entre interacción humana y ejecución de etapas | Todos los agentes publicados declaran `mode: all`, que el mapping convierte en `question: deny`, incluso `planner` e `infra-bootstrap`. Este último, además, exige pedir al usuario que ejecute `infra-base` antes de seguir. Deshabilitar `question` no elimina las esperas expresadas en prosa. |
| F8 | La consulta de fuentes no está disponible uniformemente | Solo `bug-investigator` y `apim-gateway-scaffolder` declaran `web`; solo `planner` declara Microsoft Learn y `infra-writer` Terraform MCP. Hay agentes que deben reverificar paquetes/doctrina pero no tienen una vía web genérica. Hay que mapear la capacidad requerida por tarea, incluyendo alternativas locales válidas, no habilitar todos los MCP indiscriminadamente. |
| F9 | Hay instrucciones incompatibles con una release inmutable | `test-writer.md:201,220` pide actualizar el cheatsheet de la release e incluirlo con los tests. Debe conservar lectura y registrar el hallazgo en el consumidor o en un draft hacia Mefisto, no recibir permiso de escritura sobre la instalación. |
| F10 | La telemetría no permite afirmar cero denegaciones | `src/runtime/lib/runtime-opencode.jq:351-353,409` admite éxito de ejecución por exit 0 + texto y emite `denials: null`; `scripts/_pipeline-common.sh:777` convierte ese null en cero. El retry de tooling usa ese contador (`tooling-pipeline.sh:553-571`). Los gates posteriores pueden detectar otros fallos; no se afirma que todos los PRs incompletos se acepten, pero el contador no demuestra autonomía. |
| F11 | Salidas grandes del runtime necesitan un acceso específico | OpenCode guarda resultados truncados en `Global.Path.data/tool-output` y concede una excepción externa a ese árbol. Mefisto deniega `read` sobre `**/.local/share/opencode/**`; en layouts donde allí vive `tool-output`, puede impedir leer la salida aunque la excepción externa exista. La propuesta inicial de limitar por ejecución se precisó al refinar #1825: el mantenedor autorizó lectura del directorio global completo, nunca del auth store ni de los datos vecinos. |
| F12 | Cambiar permisos no retira gates humanos de producto | `fix-review.md:79-84,131-135` exige aprobar triaje y plan; scaffold, onboarding, auth, secrets, purge y mantenimiento tienen consentimientos propios. Para ejecución desatendida deben ser entradas/autorizaciones previas, o quedar fuera del lote hasta estar listos. |
| F13 | El entorno puede variar al pasar por multiplexores | #1740 ya registra contaminación de raíces de runtime/estado entre sesiones de un servidor tmux. Un nuevo perfil de permisos no debe depender de variables que el pane no recibe, ni de una release distinta de la que lanzó el lote. Reutilizar ese issue, no duplicarlo. |

### 4. Matriz de recursos y permisos objetivo

Esta matriz es una **propuesta de contrato**, no una configuración implementada ni una certificación. «Automático» significa sin `ask` durante una ejecución previamente autorizada. El alcance se resuelve en rutas reales por proyecto/corrida; no con acceso global al home.

| Recurso o interacción | Permisos/capacidades OpenCode | Autorización objetivo | Responsable y límites |
|---|---|---|---|
| Código, tests, docs, ADRs del consumidor, solución y configuración no sensible | `read`, `glob`, `grep`; listado si la versión lo expone | Lectura automática | Primario y agentes que necesitan contexto; excluir valores secretos. |
| Edición normal, archivos nuevos, renombres y eliminaciones del cambio | `edit` (OpenCode incluye write/patch) y operaciones shell correspondientes | Automática dentro del scope del issue | Writers/reviewers/scaffolders; no editar la instalación de Mefisto ni autorizar rutas externas arbitrarias. |
| `.mefisto/harness.config.json`, `AGENTS.md`, `.github`, `infra`, docs y archivos de proyecto | Lectura/escritura por función | Automática cuando el plan aprobado lo requiere | Conservar propiedades ajenas, fallback legacy de lectura y reglas de entrega por PR. No confundir una carpeta del consumidor con un artefacto del harness solo por su nombre. |
| Release cargada: scripts, ADRs, cheatsheet, agentes, comandos, Skills, plantillas y metadata | `read`, `glob`, `grep` + `external_directory` | Lectura automática para entrada, delegados y etapas | Refinado en #1825: grants sobre la raíz física fijada; active es una observación de deriva, no un alias estable. macOS con espacios, Linux y overrides XDG. Escritura denegada a agentes de desarrollo. |
| Proyección instalada de agentes/comandos/Skills | Lectura de metadata por el controlador | Comprobar ownership/alineación sin abrir el config root al modelo | Resolver `OPENCODE_CONFIG_DIR`/`XDG_CONFIG_HOME`; inspeccionar solo ledger/enlaces propios. Refinado en #1825: documentos/Skills se consultan en la release física, no en un directorio compartido con configuración ajena. |
| Scripts publicados de Mefisto | `bash` para sus invocaciones efectivas | Automática para las operaciones del perfil | Incluir rutas entre comillas, asignaciones, redirecciones y composición que realmente se generan. La identidad de la release no autoriza por sí sola todas sus operaciones administrativas. |
| Workspace principal, worktree de la etapa y metadatos Git compartidos | `bash`; `external_directory` cuando el acceso cruza el cwd reconocido | Automática sobre los recursos de la corrida | El orquestador registra worktrees y Git common dir. No permitir todos los repos hermanos. Lanzar cada etapa con su cwd correcto. |
| Logs, summaries, métricas, señales y checkpoints | Lectura/escritura/append | Automática en `.mefisto/pipeline` y señales de `pipeline-state` | Cada corrida/etapa debe tener ownership y rutas conocidas. `batch-stop` no mata procesos. |
| Temporales y decompilados | Lectura/escritura + shell | Automática en un directorio propio por corrida | Preferir `.mefisto/pipeline/tmp/<corrida>` y normalizar la doctrina que aún usa `/tmp`; no habilitar `/tmp/**` entero. |
| Salidas truncadas de herramientas | `read`, `grep` + excepción externa del runtime | Lectura de toda la carpeta global tool-output, por decisión expresa | Incluye otras sesiones/proyectos del mismo usuario y su riesgo de contenido sensible. Sin escritura ni acceso general a bases de sesiones, logs, tokens o auth stores. |
| NuGet, SDKs, herramientas y otros paquetes del proyecto | Lectura nativa externa de fuentes/metadata; procesos de restore/build con caches propias | Automática para dependencias y toolchain declarados | Cubrir caché NuGet efectiva, no solo `~/.nuget`; separar archivos de credenciales. El gestor de paquetes puede necesitar escritura en una caché del worker sin exponer sus credenciales al modelo. |
| Build, test, cobertura, formato, lint y generación | `bash` y binarios disponibles | Automática | .NET/func init/ilspycmd y comandos de verificación del tooling. Otros ecosistemas requieren declarar toolchain y validaciones, no autorizar nuevos binarios durante un lote. |
| Contenedores y servicios de prueba | Ejecución shell, daemon/socket y red del entorno | Automática si forman parte del perfil de pruebas | Hoy existe `validate-dockerfile.sh`, limitado a info/build. Testcontainers, ejecución de contenedores o emuladores son capacidades adicionales a certificar; no se presumen cubiertas. |
| Subagentes | `task` por nombre de agente y profundidad efectiva | Automática para destinos declarados | Cubrir primario, sesiones hijas, permisos de sesión, reanudación y límites `subagent_depth`; no asumir herencia total ni ilimitada. |
| Skills | `skill` por nombre adaptado | Automática | `mefisto-projections`, `mefisto-comment-cleanup` y recursos asociados; comprobar discovery y acceso, no solo frontmatter. |
| Documentación oficial, metadatos de paquetes y MCP de documentación | `webfetch`, `websearch`, tools MCP registradas | Automática según función | Resolver disponibilidad y permisos efectivos. Microsoft Learn bundleado; Terraform MCP externo. Leer documentación no autoriza mutaciones remotas. |
| Git local/remoto | Shell y autenticación Git | Automática en ramas/worktrees de trabajo | Fetch, diff, branch, commit, push y limpieza necesarios; las etapas no asumen el push/PR reservado al pipeline. Respetar branch protection y trabajo ajeno. |
| GitHub: issues, labels, PRs, comentarios, revisiones, merge | Shell `gh` + derechos del repositorio | Automática para operaciones autorizadas | Repositorio consumidor; excepción cross-repo publicada solo para crear drafts en Mefisto. No abrir privilegios administrativos por usar `gh`. |
| CI: consultar checks/runs/logs, esperar, relanzar lo autorizado | `gh` + autorización de Actions | Automática | Verificar disponibilidad real y permisos del token, sin leerlo ni registrarlo. No confundir un permiso de OpenCode con un permiso remoto. |
| IaC normal | Editar HCL, `terraform fmt`, `init -backend=false`, `validate`; observar CI | Automática | `plan` y `apply` reales permanecen en CI según MEF-ADR-0022/0025. No se necesita conceder Azure Owner al agente de programación. |
| Diagnóstico de despliegues, App Insights, DLQ y endpoints de dev | Scripts diagnósticos, red y autorización remota | Automática para operaciones de consulta o pruebas autorizadas | `azure-account-info.sh`, `appinsights-query.sh`, endpoints declarados, disponibilidad antes del lote. |
| Bootstrap, auth, registro de secretos, cambios de runtime y purga | Capacidades específicas de operación | Solo tras autorización previa del perfil/plan | Preparación o mantenimiento separados del desarrollo normal; no elevar derechos ni saltar un consentimiento porque un batch ya arrancó. Valores secretos permanecen fuera del contexto del modelo. |
| Organización y control | `todowrite`, política de `question`, watchdog/`doom_loop` | Sin interacción humana en etapas | Permitir organización inocua; planificación interactiva puede preguntar antes de admisión. Mantener límites de progreso/tiempo y clasificar el agotamiento, no desactivar el control de bucles sin reemplazo. |

La documentación oficial agrupa escritura bajo `edit`. La presencia de 17 claves en el mapping de Mefisto no demuestra que existan 17 controles independientes equivalentes: su semántica debe cotejarse con la versión certificada del runtime.

### 5. Cobertura por escenario: los 27 comandos y los 22 agentes

| Escenario | Comandos | Agentes y dependencias operativas |
|---|---|---|
| Captura y planificación | `draft`, `next-order` y uso interactivo del agente planner | `planner`; GitHub, directivas, ADRs de release, Skills, fuentes oficiales, glosario y cierre documental. El planner no es un comando publicado adicional. |
| TDD y refactor | `implement` | `test-writer`, `implementer`, `reviewer`, `smoke-test-writer`, `projection-test-writer`, `projection-implementer`; worktrees, toolchain, paquetes, tests, cobertura, documentación y Skills. |
| Tooling del consumidor | `tooling` | `tooling-writer`, `tooling-reviewer`; archivos/config/tests propios del consumidor y comandos de verificación recibidos por la etapa. No confundir con tooling interno. |
| Infraestructura | `infra`, `infra-base` | `infra-writer`, `infra-reviewer`, `infra-base-scaffolder`; `infra-bootstrap` para preparación greenfield; Terraform estático, Terraform MCP donde corresponde, GitHub/CI. |
| Scaffolding | `scaffold`, `scaffold-projections`, `scaffold-mcp` | `domain-scaffolder`, `projections-scaffolder`, `mcp-scaffolder`; código, tests, config, HCL, workflows y validaciones de contenedor cuando procedan. |
| Autenticación y secretos | `install-workos`, `install-apim`, `install-auth`, `seed-secret` | `workos-identity-scaffolder`, `apim-gateway-scaffolder`; delegación, composición por lectura de comandos, referencias declarativas, metadata de secrets/variables y pasos humanos de preparación actuales. |
| Investigación y operación | `bug`, `health-check`, `purge-store` | `bug-investigator`, `tooling-investigator`; logs locales/remotos, NuGet/decompilación, documentación, consultas Azure encapsuladas. La purga destructiva no pertenece implícitamente a este permiso de lectura. |
| Lotes y supervisión | `sequential`, `parallel`, `batch-stop`, `work-status` | Agente iniciador, scripts batch/parallel/tmux/Herdr, procesos headless y agentes de cada pipeline; leer release, enrutar, lanzar, observar, reanudar y detener la cola. |
| Revisión y entrega | `fix-review`, `merge` | Agente iniciador, `pr-sync` o script correspondiente; lectura de comentarios, cambios, build/test, commit/push/PR, sync y merge, checks y actualización de dependencias. |
| Conocimiento | `bitacora`, `eraser-diagram` | `historiador` y agente iniciador; field notes, docs, diagramas, rama/PR documental y merge. |
| Instalación y mantenimiento | `onboard`, `upgrade`, `runtimes` | Agente iniciador y scripts de diagnóstico/proyección/upgrade; privilegios distintos de escribir código. No actualizar la release bajo los pies de una corrida ni podar una release en uso. |

### 6. Qué prueban hoy las pruebas y qué no

- `test-opencode-external-directory.sh` prueba una simulación del mapping de un agente sintético con capacidades de lectura/escritura/shell. No ejecuta `/sequential` desde el agente primario de OpenCode ni prueba la configuración fusionada del consumidor.
- `test-opencode-bash-permissions.sh` prueba una porción del cuerpo de `test-writer`, no todas las invocaciones generadas, todos los resolutores ni todos los agentes.
- Los dos tests declaran que no ejecutan OpenCode real. Su existencia y sus assertions fueron examinadas; no se atribuye una ejecución satisfactoria en esta sesión.
- Se intentaron ambos tests con `TMPDIR` dirigido al directorio ignorado del repo; la política Bash interna denegó esas invocaciones antes de ejecutarlas. No se cambiaron permisos ni se ejecutó un runtime real para sortear esa denegación. Es evidencia adicional de fragilidad de la forma de invocación interna, no una reproducción del consumidor.
- Se consultó documentación/código oficial de OpenCode fijado a `v1.18.29`, la versión mínima declarada por el contrato. La versión instalada en la sesión del consumidor y su comportamiento efectivo siguen sin comprobarse.

## Decisiones

### Propuesta de contrato de autonomía

En el análisis inicial no se declaró adoptada una arquitectura nueva. Se recomendó lo siguiente; el apartado de refinamiento de #1820 registra después qué decisiones aprobó el mantenedor y qué alcance documental se marcó listo:

1. **Autorizar operaciones antes de admitir trabajo:** proyecto, entorno, release, toolchain, worktrees, salidas, red, operaciones Git/GitHub y agentes que puede usar la corrida. Un issue sin entradas necesarias no entra a un lote desatendido.
2. **Cero prompts y cero denegaciones de capacidades requeridas:** convertir `ask` en `deny` evita una pregunta pero no resuelve la pérdida operativa. Los recursos necesarios deben resolverse a `allow` en el permiso efectivo de cada participante.
3. **Cubrir la entrada:** elegir un agente orquestador publicado con permisos verificables, o instalar un perfil de proyecto expresamente aceptado que cubra la sesión primaria. No modificar silenciosamente la configuración global del usuario ni asumir que lanzar un slash command activa los permisos de Mefisto. Evaluar la elección respetando la composición de comandos y la profundidad de subagentes.
4. **Autoridad neutral y adaptación por runtime:** las capacidades operativas se expresan en el contrato publicado; los detalles OpenCode se generan. No editar `dist/` ni la release instalada a mano, y no importar el scope interno.
5. **Autonomía amplia de desarrollo dentro de un worker aislado:** OpenCode declara que su sistema de permisos no es un sandbox. Para admitir comandos de programación variados sin una lista interminable de prefijos, usar un contenedor/VM/worker dedicado con workspace/caches escribibles, release montada de solo lectura, credenciales acotadas y sin acceso arbitrario al host. La viabilidad de ese aislamiento con toolchains y multiplexores actuales requiere diseño/certificación propios; hoy no existe esa garantía en el harness.
6. **Separar privilegios de desarrollo, entrega y administración:** lectura de release y build/test nunca deberían preguntar. Bootstrap, secretos, mantenimiento de instalación y purga deben estar preautorizados con objetivos concretos o completarse antes; no heredan el permiso por ser parte de Mefisto. No convertir el requisito de autonomía en acceso irrestricto al home o a producción.
7. **No mutar la política durante una etapa:** ante una capacidad faltante, registrar error específico y evidencia; no reintentar a ciegas, saltarse una lectura obligatoria ni ampliar privilegios automáticamente. Los lotes no afectados pueden seguir según política explícita del orquestador.

Esta propuesta necesita documentar su relación con MEF-ADR-0049.5 (deny generado y `--auto`), MEF-ADR-0053.2/.5 (instalación y conservación de config/paridad), MEF-ADR-0050 (neutralidad), MEF-ADR-0019 (separación de lados), MEF-ADR-0025 (custodia) y MEF-ADR-0031 (evidencia). No autoriza LSP por herencia de `read`: MEF-ADR-0052 mantiene esa capacidad fuera de la adopción actual.

### Admisión de lote y evidencia de completitud

Propuesta de comprobaciones antes de crear el primer worktree:

- Identidad: repo, runtime/versión, agente iniciador, release realmente cargada, roots lógicas/físicas y perfil autorizado.
- Permisos efectivos fusionados: globales, proyecto, agente, sesión, configuración inline/gestionada y delegados; informar el origen de los conflictos sin volcar config ni secretos. No basta validar el JSON generado.
- Acceso al caso exacto de Grep de Control Asistencia, ADR y Skill de release, recurso NuGet requerido, temporal propio y salida truncada.
- Resolución de cada comando Bash generado, incluida asignación de entorno, comillas, espacios, tuberías, sustituciones y redirecciones, con semántica de la versión soportada.
- Toolchains y comandos de verificación disponibles; acceso remoto y credenciales vigentes comprobados mediante operaciones inocuas, no leyendo tokens.
- Delegación autorizada, profundidad suficiente y configuración transportada a tmux/Herdr/worktree y reanudaciones.
- Entradas, consentimiento operativo y derechos GitHub/CI necesarios presentes antes del lote; no prometer que permisos OpenCode corrigen una caducidad de autenticación o una política organizacional.

Evidencia durante y al terminar: correlación repo/lote/issue/stage/agente/sesión/release, eventos de permisos sanitizados (`ask`, `deny`, regla y recurso), resultado de verificaciones obligatorias y estado real de PR/CI. `denials: null` significa desconocido, no cero. Un mensaje final con exit 0 no demuestra que el agente leyó sus fuentes ni terminó la tarea.

Para certificación: suite determinista sin LLM en CI y smoke separado, controlado, de la release instalada con runtime real, sin aprobaciones persistidas. Mantener separada esa certificación de la decisión histórica de #1750/#1761 de no lanzar runtimes reales en sus tests unitarios. Repetir en entrada interactiva, task, headless, reanudación, macOS/Linux, XDG personalizado y worktree; añadir controles negativos de escritura de release y exposición de secretos. No se ejecutó esa certificación hoy.

### Desglose candidato, sin issues contenedores

En el análisis inicial no se crearon issues ni se marcaron como listos. Estos fueron los cortes candidatos, no un batch calculado ni estimaciones inferiores a 30 minutos ya validadas. La continuación autorizada por el usuario los concretó en el registro siguiente:

| Prioridad | Título candidato | Componente principal y resultado verificable |
|---|---|---|
| P0 | Cubrir la lectura de la release desde los comandos iniciadores OpenCode | Adaptador publicado/entrada; el Grep exacto de Control Asistencia funciona sin prompt en sesión nueva y no habilita escritura de instalación. |
| P0 | Alinear las invocaciones Bash generadas con los candidatos reales de OpenCode | Adaptador publicado; cubrir preámbulos, scripts, formas con entorno/comillas y comandos auxiliares usados. |
| P0 | Resolver las rutas externas necesarias desde el entorno efectivo | Contrato/proyección publicada; release y recursos declarados funcionan con XDG/config roots personalizados, sin abrir el home entero. |
| P0 | Unificar los temporales de decompilación del test-writer y reviewer | Doctrina publicada; dividir por agente si no cabe en un cambio pequeño; salidas leíbles dentro del estado de corrida. Retirar la instrucción de editar el cheatsheet de release en un corte propio si es necesario. |
| P0 | Registrar denegaciones OpenCode sin convertir desconocido en cero | Adaptador de eventos compartido; error de permiso observable y no confundido con éxito de completitud. Separar traducción del evento y consumo por pipeline si supera un componente. |
| P1 | Definir el contrato de autonomía desatendida del consumidor | ADR/contrato; decidir entrada, perfiles, aislamiento, custodia y frontera de consentimiento. |
| P1 | Verificar capacidades efectivas antes de admitir un lote | Preflight publicado; rechazar configuración inviable antes del primer issue con diagnóstico accionable. Conectar por pipeline en cortes pequeños. |
| P1 | Certificar entrada, delegación y etapas de una release instalada | Certificación; reproducir los recorridos, rutas y agentes pertinentes, sin confundir snapshots con ejecución real. |
| P1 | Separar los permisos de planificación interactiva y etapas headless | Contrato de agentes; delegación/Skills/fuentes y preguntas disponibles según rol, sin gates humanos dentro de etapas admitidas. |
| P2 | Incorporar autorizaciones previas a los comandos hoy interactivos | Un issue por comando o función: fix-review, scaffold, auth, mantenimiento y purga; preservar modo interactivo y objetivos explícitos. |
| P2 | Aislar el worker de programación y sus credenciales | Entorno de ejecución publicado; autonomía amplia verificable sin confiar en el matcher como barrera de seguridad. Requiere desglose propio. |

Reutilizar #1740 para la deriva de entorno tmux. #1750 y #1761 son antecedentes implementados con cobertura insuficiente para el objetivo completo; no se reabrieron ni cerraron nuevos issues. La prioridad anterior es operativa, no un orden de batch: cuando existan issues con dependencias declaradas, usar el script canónico de orden.

### Continuación autorizada: issues creados

Se crearon **15 issues en el repo activo: 5 listos y 10 borradores**. Se verificaron contra GitHub sus cuerpos, 4-6 CAs por issue, etiquetas, secciones y dependencias; no quedaron marcadores de redacción sin resolver. Todos tienen `tipo:tooling`, un solo estado y ningún label `dom:`. Los defectos identificados llevan `bug`; los que dependen de issues abiertos llevan `bloqueado`.

| Issue | Título | Estado |
|---|---|---|
| [#1813](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1813) | Permitir cut en la consulta NuGet de los agentes publicados OpenCode | Listo, independiente |
| [#1814](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1814) | Usar temporales del consumidor para decompilar paquetes en test-writer | Listo, independiente |
| [#1815](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1815) | Usar temporales del consumidor para decompilar paquetes en reviewer | Listo, independiente |
| [#1816](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1816) | Retirar del test-writer la escritura sobre el cheatsheet instalado | Listo, independiente |
| [#1817](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1817) | Registrar las denegaciones observables en los eventos del adaptador OpenCode | Borrador |
| [#1818](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1818) | Preservar el contador desconocido de denegaciones en los pipelines publicados | Listo, independiente |
| [#1819](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1819) | Alinear los permisos Bash publicados con los candidatos reales de OpenCode | Borrador |
| [#1820](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1820) | Definir el contrato de autonomía desatendida de Mefisto en consumidores | Borrador, entrega un ADR, no un epic |
| [#1821](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1821) | Incorporar autorizaciones previas a la ejecución desatendida de fix-review | Borrador, bloqueado por #1820 |
| [#1822](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1822) | Completar las capacidades de consulta de fuentes de los agentes publicados | Borrador, bloqueado por #1820 |
| [#1823](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1823) | Autorizar la lectura de release y la delegación desde los comandos iniciadores OpenCode | Borrador, bloqueado por #1820 |
| [#1824](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1824) | Aislar un worker de programación para ejecutar tooling del consumidor | Borrador, bloqueado por #1820 |
| [#1825](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1825) | Resolver las rutas externas necesarias desde el entorno efectivo de OpenCode | Borrador, bloqueado por #1820 |
| [#1826](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1826) | Verificar capacidades efectivas antes de admitir un lote del consumidor | Borrador, bloqueado por #1820/#1825 |
| [#1827](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1827) | Certificar la autonomía OpenCode y la no regresión de Claude en una release instalada | Borrador, bloqueado y `cierre:manual` |

Los cinco listos tienen revisión explícita de complejidad y Definition of Ready, estimaciones informales de 10-25 minutos y un componente principal con pruebas/salidas mecánicas. No se presentan como solución completa de la dark factory: son correcciones independientes que ya aportan valor.

#1823 conserva el Grep exacto de Control Asistencia como criterio y distingue causa estructural confirmada de atribución del incidente pendiente. #1827 exige evidencia de release instalada antes de cerrar, no solo un PR con un runbook; sus dependencias están en su sección canónica. #1740 permanece reutilizado, sin editar ni duplicar.

Al crear los issues, el próximo refinamiento recomendado era #1820 para decidir el mecanismo de autorización y límites; #1819 y #1817 podían investigarse sin esperar esa decisión. Después, #1823 concreta la entrada que hoy deja descubierto `/sequential`. La continuación de refinamiento de #1820 que aparece más abajo completa esa primera decisión. No se calculó ni lanzó un batch.

Ideas aún no convertidas en implementaciones listas: adopción de preautorizaciones en los demás comandos interactivos (scaffold, auth, onboarding, mantenimiento y purga), elección de worker/toolchain y alcance de certificación. #1821 es solo el primer corte de fix-review, no un contenedor de esos cambios.

### Revisión posterior: compatibilidad de las implementaciones Claude

El usuario preguntó si se había revisado que los cambios propuestos no afectaran las implementaciones que realiza Claude. La respuesta honesta fue **parcialmente**: la separación de lados y las regeneraciones de ambos adaptadores se contemplaron, pero no se había hecho una auditoría completa de no regresión ni ejecutado certificación real. Tener `--check` en un CA solo verifica sincronía del generado, no equivalencia funcional del pipeline.

Se contrastaron los 15 issues abiertos contra `e0343b31ef98`, el renderizador Claude, el traductor/runner Claude, los callers TDD/tooling y las suites relevantes. La distinción necesaria es **no regresión**, no **cero cambios en Claude**: los agentes y comandos de fuente neutral se proyectan a ambos runtimes y algunos cambios de doctrina son deliberadamente comunes.

| Grupo | Impacto Claude verificado en el diseño | Criterio reforzado |
|---|---|---|
| #1813 y #1819 | Mapping de permisos OpenCode separado; `shell` se traduce simplemente a `Bash` en Claude. `effective-contract.sh`, en cambio, es compartido. | Snapshots/herramientas/modelos/argv Claude sin cambio por la compensación OpenCode; si se toca el helper común, fixtures Claude de canonical/legacy/coexistencia/espacios. |
| #1814, #1815 y #1816 | Cambian cuerpos neutrales que Claude recibe: temporales y destino del aprendizaje. | Limitar el delta a esos cambios intencionales; preservar fases, gates, consulta de fuentes, modelo/tools/Skills y summaries. Fixtures con worktree/paths con espacios y doble de ilspycmd, sin incluir estado en commits. |
| #1817 y #1818 | El productor OpenCode es independiente, pero schema y lectores son comunes. Claude produce `denials` conocido o null según `permission_denials`. | Fixtures traducidos por Claude para array vacío/poblado/ausente; preservar retry único, hold/resume, recuperación y gates. No tratar null como aborto ni aplicar heurísticas de wire OpenCode a Claude. |
| #1820, #1821 y #1822 | Contrato, modo de comando y capacidades neutrales también gobiernan Claude. | Adopción explícita, modo interactivo previo preservado sin opt-in, herramientas/Skills/MCP y nombres Claude correctos, sin requisitos OpenCode. |
| #1823 | Agregar `agent` al comando neutral cambia Claude a delegación completa; no es un fix de OpenCode aislado. | Conservar la delegación puntual, retorno y continuación; probar `bitacora -> historiador -> verificación -> merge` y lanzamiento secuencial Claude. |
| #1824, #1825 y #1826 | Worker, resolución de recursos y admisión pueden alterar rutas de lanzamiento compartidas o imponer requisitos nuevos a Claude. | No cambiar su lanzamiento por defecto, exigir OpenCode ni mezclar roots/mirrors; probar consumidor solo Claude, fallback legacy y coexistencia dual. |
| #1827 | El borrador original solo exigía evidencia OpenCode. | Renombrado para incluir no regresión Claude; CA de control TDD equivalente con Claude hasta verificaciones/PR y coexistencia, sin extrapolar el resultado ni comparar rendimiento entre proveedores. |

Fuentes concretas de los riesgos: `src/published/scripts/lib/adapter-claude.sh:7,165,178-184,232-234` (capabilities, directivas y delegación); `src/runtime/lib/runtime-claude.sh:86-107` (argv/stdin/modelo/resume/system-file); `src/runtime/lib/runtime-claude.jq:271` (conteo o null); `scripts/tdd-pipeline.sh:805-817` y `scripts/tooling-pipeline.sh:553-574` (retry y continuidad). Las suites revisadas incluyen `test-adapter-claude.sh`, `test-tdd-agents.sh`, `test-bitacora-command.sh`, `test-fix-review-command.sh`, `test-generate-published-adapters.sh` y los tests de runner neutral TDD/tooling.

Se reforzaron los **15 cuerpos de issues** y se verificaron en GitHub: todos contienen un CA explícito relativo a Claude, todos conservan como máximo 6 CAs y siguen **5 listos/10 borradores**. No se promovió ningún borrador, no se cerró ni creó un issue adicional, y no se modificó código, permisos ni instalación. Los listos conservaron el alcance acotado con estimación ajustada a 15-25 minutos al reutilizar sus pruebas existentes.

**Límite de evidencia:** esta fue una revisión estática de propuestas y cobertura, no ejecución de tests ni de Claude/OpenCode reales. Las pruebas y el control de release deben ejecutarse sobre las implementaciones futuras; todavía no se puede afirmar «sin regresiones demostrado». El objetivo es que esa garantía quede como condición de aceptación explícita, no como supuesto del planner.

### Refinamiento de #1820: decisiones confirmadas y estado listo

El usuario pidió «Refina 1820». Tras revisar el issue, MEF-ADR-0049/0050/0053, el contrato consumidor y las restricciones de compatibilidad, respondió explícitamente:

| Decisión | Selección del mantenedor | Consecuencia |
|---|---|---|
| Entrada y activación | Perfil y entrada | Activación por proyecto, entrada controlada y permisos coherentes de agentes/etapas; no depender de seleccionar un agente a mano ni modificar permisos globales ajenos. |
| Alcance operativo | También administración acotada | El lote puede incluir bootstrap, auth, registro/cableado de secretos, mantenimiento y purgas previamente declarados por acción/entorno/recurso; no quedan excluidos por definición. |
| Aislamiento y transición | Local primero | Los fixes y la primera adopción local no esperan al worker aislado; el modo local declara que no es un sandbox. La plataforma de #1824 se decide en ese corte posterior. |

Se sustituyó el borrador abierto por un issue documental implementable: **#1820 quedó con `tipo:tooling` y `estado:listo`, sin dependencias bloqueantes y con 6 CAs**. Se reservó **MEF-ADR-0055**, libre en el árbol y sin otra reserva encontrada en issues/PRs, con destino exacto `docs/adr/mef-adr-0055-autonomia-desatendida-consumidores.md`.

El contrato que debe redactar su PR fija:

- Declaración neutral del perfil en el contrato canónico del consumidor y evidencia/estado bajo `.mefisto/pipeline/`; declaración versionada no equivale a consentimiento. La etapa no puede autorizarse editando el worktree ni usando su propia respuesta como aprobación.
- Administración acotada **sí** incluida, pero con acción, entorno, recursos, plan/revisión y límites aprobados antes de admisión. Una acción irreversible requiere autorización específica asociada al diagnóstico/plan o dry-run aplicable; producción no se autoriza implícitamente. No se ejecutó ninguna operación administrativa durante esta planeación.
- No repetir consentimiento por cada tool call/lote ni por cambiar una ruta de worktree/release dentro de las mismas capacidades. Cambiar acción, destino, alcance destructivo o límites sí exige nueva autorización previa. Los cambios técnicos invalidan evidencia para revalidar, no necesariamente el consentimiento.
- Ciclo explícito activar/autorizar -> resolver identidad/recursos -> comprobar -> admitir -> ejecutar/observar -> verificar. Conflictos o requisitos faltantes producen no-admisión/fallo concreto, no autoampliación, omisión de fuentes ni espera silenciosa.
- Transición local sin garantía de sandbox; worker aislado posterior, sin decidir ahora Docker/VM. No concede shell universal, sudo ni eliminación de controles del host.
- Claude conserva su flujo sin adopción del perfil, sin requerir OpenCode; las mejoras neutrales declaran deltas y exigen pruebas de ambos adaptadores. Certificación real en #1827, no en este PR documental.

El scope de implementación de #1820 es un ADR principal, dos referencias acotadas (MEF-ADR-0053 y `src/published/contract/README.md`), fragmentos `1820.added.md`/`1820.adr-index.md` y copias documentales generadas. No modifica código, permisos, schemas, agentes, comandos ni configuración efectiva. Estimación informal de 25 minutos con las decisiones ya fijadas; CAs verificables por contenido/diff y cinco escenarios de autorización/no-admisión/fallo/desconocido. El PR documental puede cerrar #1820, pero no certifica autonomía ni implementa los issues dependientes.

Se preservaron los bloqueos de #1821-#1826: la dependencia sigue abierta mientras no se entregue el ADR. No se promovieron automáticamente esos borradores. Próximo refinamiento: #1823, tomando las decisiones ya acordadas, sin repetir la elección de perfil/entrada. La tabla de creación y el conteo 5 listos/10 borradores anteriores describen sus momentos históricos; este refinamiento promovió únicamente #1820.

### Refinamiento de #1823: catálogo completo y cortes de implementación

El usuario pidió «refina 1823». Se verificó que #1820 seguía abierto/listo y que aún no existían ni MEF-ADR-0055 en main ni una implementación del perfil/consentimiento. El checkout había avanzado por trabajo ajeno a `fc79191ab4d7`; no se modificó ni revirtió ese trabajo.

Se ofreció un piloto de sequential/bitacora frente a catálogo completo dividido por componentes. El mantenedor eligió explícitamente **«Catálogo completo desde ahora»**. La entrega no puede darse por terminada cubriendo solo esos dos ejemplos; la cobertura se deriva del inventario de la release, 27 comandos hoy.

#### Evidencia de mecanismo OpenCode

- El SDK de plugins v1.18.29 expone `config` y `command.execute.before` (`packages/plugin/src/index.ts`). El hook `config` ya tiene precedente publicado en el plugin MCP de Mefisto y sus tests con dobles.
- `packages/opencode/src/session/prompt.ts:1356-1473` resuelve `cmd.agent`, modelo y `isSubtask` antes de llamar a `command.execute.before`. Por tanto, ese hook no sirve para seleccionar el agente: la selección se materializa en configuración y el hook previo solo revalida la admisión.
- Un agente primario con binding `subtask: false` no añade un Task envolvente. La delegación puntual de bitacora a historiador conserva el primer nivel y el retorno al comando; no hay que aumentar globalmente `subagent_depth`.
- Agregar el campo `agent` a los Markdown neutrales sigue descartado como compensación OpenCode: también cambia la delegación Claude. El binding será un asset exclusivo del adaptador OpenCode, sin nuevos modelos ni `default_agent` global.
- Esto es evidencia estática de código/documentación de la versión soportada, no un smoke ejecutado ni prueba de aislamiento del host. El hook previo tampoco es una barrera general contra interpolaciones de shell que el propio runtime procese antes.

#### Issues resultantes

| Issue | Entregable | Estado verificado |
|---|---|---|
| [#1834](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1834) — Definir y validar el contrato de perfil y consentimiento por proyecto | Contrato neutral y validador jq puro: declaración separada de consentimiento, digest/revisión/proyecto y estados `disabled`, `needs-approval`, `ready`, `conflict`. | Listo, bloqueado por #1820 |
| [#1835](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1835) — Activar y revocar el perfil autorizado de un consumidor | `autonomy-profile.sh`: preview/approve/revoke/inspect; aprobación explícita sobre digest, estado propio, lector sin escrituras ni autoaprobación. | Listo, bloqueado por #1834 |
| [#1836](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1836) — Resolver la proyección OpenCode de entrada para todo el catálogo publicado | Proyección por comando de capacidades, roots, delegaciones directas/transitivas, ownership y restricciones efectivas. Expone resolver y envelope para el binding. | Borrador, bloqueado por #1834/#1835/#1819/#1825 |
| [#1823](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1823) — Integrar la entrada OpenCode autorizada de todo el catálogo publicado | Plugin generado `mefisto-command-entry.js`: aplicar/revalidar la proyección ya resuelta, agentes técnicos `command-entry-<id>`, primarios y sin fijar modelo; no editar templates ni metadata neutral. | Listo, bloqueado por #1820/#1836 |

Los tres nuevos issues son entregables propios, no epics. #1823 se acotó a un componente principal —el binding generado— con seis CAs y estimación informal de 25 minutos **después** de sus dependencias. No debe simular el resolver, autoaprobar un perfil ni omitir un bloqueo porque #1836 siga en borrador. #1834/#1835 tienen seis CAs cada uno, interfaces/rutas especificadas y estimación informal de 25 minutos. #1836 conserva explícitos sus pendientes de matriz completa y algoritmo de ownership/precedencia; habrá que partirlo más si excede el tamaño del pipeline.

El guard de entrada usa únicamente la consulta del perfil; nunca approve/revoke. Un perfil inicialmente deshabilitado conserva el comportamiento previo. Revocación/cambio de un snapshot ya aplicado, conflicto, fallo del resolver o restricciones de sesión no consultables no permiten continuar con permisos viejos ni volver silenciosamente al agente anterior. No se cambia la doctrina ni se eliminan confirmaciones administrativas de los bodies desde este hook.

Se verificaron en GitHub los cuerpos, etiquetas, seis CAs, secciones canónicas y ausencia de marcadores sin resolver. Ninguno de estos issues está cerrado; conservar `bloqueado` donde corresponde. No se calculó ni lanzó un batch.

#### Evidencia adicional incorporada a #1819

La elección de catálogo completo descubrió que no basta resolver el preámbulo package-root:

- `eraser-diagram.md:38-57` exige ejecutar `curl` contra la API de Eraser, mientras el mapping publicado contiene `curl *: deny`. Requiere un corte acotado de wrapper/alternativa, no habilitar curl universal ni declarar el comando cubierto porque ya tenga agente.
- `seed-secret.md:114-116` usa `terraform -chdir=... fmt/init -backend=false/validate`, fuera de las reglas que comienzan directamente por el subcomando.
- `runtimes.md` usa `MEFISTO_LIFECYCLE_LAUNCHER` y el preámbulo lifecycle, distintos del resolver package-root que hoy prueba test-writer.

#1819 recibió estos casos y la exigencia de registrarlos/resolverlos o separarlos antes de afirmar cobertura completa; conserva `estado:borrador`. La certificación real sigue en #1827. La interacción del planner publicado fuera de un comando, las autorizaciones administrativas específicas y la admisión integral no se declaran resueltas por el nuevo binding.

Al terminar ese refinamiento, el siguiente recomendado era **#1836**, para cerrar la matriz y el algoritmo que #1823 consumirá, coordinando #1819 y #1825. Su continuación se registra abajo. El contrato/activación y el binding pueden desarrollarse solo respetando sus dependencias declaradas. Claude mantiene fuentes, runner, modelos, herramientas, Skills y delegación actuales; los nuevos artefactos de binding son exclusivos de OpenCode y requieren los controles de no regresión ya fijados.

### Refinamiento de #1836: matriz completa, política ordenada y ownership

El usuario pidió «refina 1836». Se revisó contra `70e71653c704`, con #1820 todavía abierto y las bibliotecas de perfil/entrada aún no implementadas. Se mantuvieron las decisiones de catálogo completo, perfil/entrada, administración acotada, local primero y no regresión Claude.

La revisión del código oficial OpenCode v1.18.29 permitió fijar, sin ejecutar el runtime:

- `Permission.evaluate` usa última coincidencia y `merge` concatena rulesets. No equivale a juntar todos los deny ni a reordenar objetos.
- `Wildcard.match` normaliza contrabarras y el sufijo ` *` admite argumentos opcionales: `git *` también casa con `git`. No se puede colapsar `**` indiscriminadamente alrededor de ese caso ni sustituir el matcher por el evaluador interno reducido.
- Config convierte tools legacy primero (write/edit/patch a edit) y después aplica permission explícito. El hook recibe la política ya normalizada: volver a fusionar tools puede alterar la intención.
- Los loaders de comandos y agentes usan `md.content.trim()`. Ownership debe comparar ese cuerpo efectivo, no el hash del Markdown con frontmatter; modelo/variant elegidos por el usuario no son un cambio de body.
- La consulta exitosa de una sesión sin reglas puede representarse como array vacío conocido; una consulta fallida/no realizada no es ese mismo caso. Se fijaron `configPolicyKnown`, `sessionPolicyKnown` y `sessionProjectMatches` en el contexto del resolver.

#### Cortes implementables

| Issue | Entregable | Estado verificado |
|---|---|---|
| [#1837](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1837) — Encapsular el renderizado de Eraser en un script publicado | Endpoint fijo, payload JSON en estado propio, credencial solo por canal interno del proceso, resultados/errores sanitizados; mismo flujo Claude. | Listo, sin dependencias |
| [#1838](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1838) — Componer y evaluar las políticas OpenCode de entrada sin ampliar permisos | Biblioteca pura del adaptador, orden/legacy/matcher/intersección, diagnóstico de composición no representable y reglas de sesión. | Listo, sin dependencias |
| [#1839](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1839) — Declarar la matriz de entrada y composición de los comandos publicados | Matriz neutral de 27 filas, capacidades directas y clausura de command-doc/task, hashes de templates/prompts y manifest generado. | Listo, bloqueado por #1820/#1837 |
| [#1836](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1836) — Resolver la proyección OpenCode de entrada para todo el catálogo publicado | Ensamblar perfil, matriz, recursos y política ya resueltos en el envelope versionado que consume #1823. | Listo, bloqueado por #1834/#1835/#1839/#1838/#1819/#1825 |

Los cuatro tienen seis CAs y un componente principal. #1836 ya no inventaría el catálogo ni escribiría un transporte HTTP y un motor de reglas en el mismo PR: su estimación de 25 minutos es para integrar entregables de dependencias cerradas. Los tres nuevos cortes también documentan interfaz, verificación determinista y compatibilidad Claude, sin afirmar pruebas ejecutadas.

#### Reglas que quedaron cerradas

- La clausura de **comandos compuestos** une sus capacidades; una llamada a **agente delegado** solo añade el destino task, no todas las capacidades del hijo al padre. Las menciones informativas a otros comandos no se tratan como ejecución.
- La matriz explicita edición de proyecto para los cuerpos que modifican código/HCL/config y edición de estado para el payload Eraser. Los coordinadores que solo lanzan pipelines no reciben task universal ni edición de proyecto por inercia.
- La composición no amplía la política propia con allows extranjeros ni ignora el deny ganador; config ask puede quedar cubierto por consentimiento previo dentro de lo autorizado. La sesión no se reescribe. Una intersección/representación no soportada se diagnostica antes, no se aproxima concediendo acceso. La biblioteca no parsea shell ni es un sandbox.
- `status: ready` se acotó a **proyección de entrada** (`admissionScope: entry`), no a consentimiento administrativo ni completitud. En fase config todos los bindings tienen `admitted: false` pero se instalan; en fase command solo la fila solicitada puede quedar admitida tras revalidación. Así una fila no aprobada no cae al agente anterior.
- Modelos/providers/transcripts y valores sensibles no viajan en el contexto del resolver. Se envían hashes, disponibilidad/modo de targets y reglas necesarias; los diagnósticos no vuelcan entradas crudas.
- El manifest se calcula con el renderer actual en memoria. La interfaz de assets no recibe el staging del generador; leer `dist/` persistido daría hashes obsoletos o fallaría en una generación limpia.

#1823 se sincronizó con el contrato preciso (observaciones conocidas, fase config/command, hashes y admisión solo de entrada), conservando estado listo/bloqueado. #1819 recibió referencias a #1837/#1838 y los casos pgrep de batch-stop y source/funciones/temporales de onboard; permanece borrador. No se habilitó curl genérico ni matar procesos por patrón.

La consulta agregada de verificación de GitHub agotó su timeout sin resultado; se reintentaron únicamente lecturas individuales, que confirmaron estados/etiquetas, seis CAs por issue y las 27 filas del catálogo. No se repitió ninguna creación de issue ni hubo duplicados por ese timeout.

No se implementó código, se modificaron permisos reales ni se ejecutaron runtimes/tests en esa continuación. Los siguientes refinamientos pendientes eran #1819 (candidatos Bash, sin duplicar el compositor) y #1825 (recursos efectivos); el primero se registra a continuación. #1826 conserva la admisión operativa integral y #1827 la certificación real.

### Refinamiento de #1819: invocaciones reales, no permisos para falsos candidatos

El usuario pidió «refina 1819». Se revisó el mapping, los dos preámbulos OpenCode, `effective-contract.sh`, el scanner heurístico actual y los callers operativos contra `70e71653c704`.

Se fijó la procedencia del parser: OpenCode **1.18.29** declara **tree-sitter-bash 0.25.0** y **web-tree-sitter 0.25.10** en su package.json. El código oficial de ShellTool recorre nodos `command`, usa el texto de su padre inmediato `redirected_statement` cuando corresponde y excluye CWD del permiso bash. La gramática oficial distingue `test_command`, `declaration_command`, `variable_assignment` y `command`.

**Corrección explícita de la hipótesis inicial:** la falta de reglas para `export MEFISTO_CONFIG_PATH`/`MEFISTO_INSTRUCTIONS_PATH` no demuestra una denegación. Export/local/declare y el nodo de bracket-test no son candidatos independientes; sus comandos descendientes sí pueden serlo. `test -f` es un command ordinario. Las funciones invocadas y commands dentro de su definición son otra cosa: no se deduce qué se autoriza ejecutando solo la rama feliz. Esta precisión evita ampliar permisos para satisfacer errores del simulador.

#### Cortes resultantes

| Issue | Entregable | Estado verificado |
|---|---|---|
| [#1840](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1840) — Normalizar la validación Terraform local al directorio del entorno | Nueve llamadas locales en seed-secret, infra-base-scaffolder y apim-gateway-scaffolder pasan a subshell con cwd de entorno, preservando argv, backend=false y comportamiento Claude. No toca los comandos de CI. | Listo, sin dependencias, 5 CAs |
| [#1841](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1841) — Centralizar la escritura de tenancy.strategy en un script publicado | Setter canónico compartido por onboard/install-apim, JSON configPath/strategy/changed, validación existente, escritura atómica y conservación de gates/callers Claude. | Listo, sin dependencias, 6 CAs |
| [#1819](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1819) — Alinear los permisos Bash publicados con los candidatos reales de OpenCode | Mapping/emisión y corpus trazable de familias de invocación, consumiendo el evaluador #1838 y las operaciones encapsuladas/canónicas. | Listo, bloqueado por #1838/#1837/#1840/#1841, 6 CAs |

El setter evita autorizar source genérico, funciones de un archivo externo o un `rm -f "$TMP"` cuyo destino no se conoce por su nombre de variable. Los callers mantienen las confirmaciones y condiciones existentes; install-apim rehidrata changed/configPath para su `TENANCY_TOKEN_FLIPPED`/`CONFIG` y git add condicional sin asumir estado shell persistente.

La normalización Terraform evita reglas con wildcard entre `-chdir` y el subcomando, que podrían confundir un argumento/ruta con la operación permitida. Se verificó que son exactamente nueve invocaciones locales en las tres ubicaciones. Es una transformación mecánica del mismo eje, no nueva infraestructura ni un cambio de HCL.

#1819 fija familias package-root, config/directivas, run (incluidas sustituciones/redirecciones), lifecycle, Terraform estático y consultas/control benigno. El preámbulo lifecycle se aplana solo en OpenCode para reutilizar if/asignaciones/OSTYPE, conservar su interfaz y repetirse por llamada. Las reglas de script se atan a referencias operativas reales, no a cualquier archivo empaquetado; aprobar el perfil no se convierte en una operación permitida a la etapa.

Los negativos incluyen shell/env/eval/source genéricos, curl directo, sudo/ssh/scp, plan/apply/destroy e init sin backend=false o con un segundo backend=true. Se acotan los init emitidos y no se normalizan candidatos quitando los fragmentos que causaban la denegación. `true`, el sleep acotado y las consultas pgrep reales se distinguen de comandos citados para el humano; no se autoriza matar procesos por patrón.

El corpus será de formas emitidas y caracterizadas, con snippets/rangos/candidatos y procedencia fijada. No se construye un parser shell universal ni se etiqueta una deducción de gramática como captura empírica. Cambios de forma exigen revisar la caracterización; la suite no descarga parsers, inicia un LLM ni usa el evaluador interno como autoridad. #1827 conserva la certificación contra runtime instalado.

Se verificaron cuerpos/estados/etiquetas de los tres issues y se sincronizó CA-5 de #1836 con las invocaciones normalizadas y el setter, para que no exija autorizar los antiguos -chdir por un glob amplio. No se ejecutaron Terraform, provisioning ni tests/runtimes reales; no se modificó código del harness ni permisos instalados.

Al terminar ese refinamiento, el siguiente era **#1825**, recursos externos efectivos; su continuación se registra abajo. #1840/#1841 pueden desarrollarse independientemente; el orden de un batch se obtiene con el mecanismo canónico, no se calculó aquí.

### Refinamiento de #1825: snapshot técnico, roots efectivas y alcance global de tool-output

El usuario pidió refinar #1825 y, antes de la continuación, eligió **«Toda la carpeta tool-output»**. Se incorporó literalmente ese alcance: lectura del directorio global completo, incluidos resultados de otras sesiones/proyectos del mismo usuario, después de advertir del posible contenido sensible. No significa escribir allí ni leer auth stores, logs, bases de sesiones o el resto del almacenamiento/configuración de OpenCode. No se volvió a imponer trazabilidad por sesión como requisito.

La revisión se mantuvo sobre `70e71653c704`, sin cambios de código ni de permisos instalados. Fuentes oficiales OpenCode fijadas a v1.18.29 y Microsoft Learn permitieron precisar:

- **Candidatos distintos:** Read y Edit/Write piden `path.relative(instance.worktree, filepath)`; external_directory pide directorio absoluto + `/*`. Una regla absoluta en read no demuestra el acceso esperado. Grep pide la expresión de búsqueda y comprueba external_directory aparte; no filtra el contenido mediante los denies de read.
- **Datos OpenCode distintos de Mefisto:** `Global.Path.data` parte de XDG también en macOS; sin override usa `.local/share/opencode`, no `Library/Application Support/mefisto`. Config y datos son roots distintas. `osHome` y el home usado por el matcher no se sustituyen entre sí, especialmente con el override de pruebas del runtime.
- **API sin campos inventados:** el SDK v1 Path consultado expone state/config/worktree/directory, no data/home. El contexto se captura explícitamente del proceso del plugin y las rutas siguen la semántica del runtime fijado, no una propiedad SDK inexistente.
- **Consulta no siempre pura:** `mefisto_state_path` crea directorios y projection-status adquiere lock/puede crear estado. El nuevo resolver no los usa como si fueran lectores sin efectos.
- **NuGet por dos evidencias:** locals descubre global-packages; assets v3 expone packageFolders del restore observado. La CLI por sí sola no demuestra RestorePackagesPath y un assets no demuestra frescura de un restore futuro. No evaluar proyectos/targets MSBuild ni volcar NuGet.Config para descubrir paths.
- **Permisos no corrigen callers:** reviewer/bug-investigator aún tienen paths NuGet fijos; test-writer usa otro parser de locals. Se separó su adaptación neutral y el delta Claude intencional.
- **Descubrir no retiene:** prune protege active/anterior/keep, sin referencias de uso de corridas. Ese lifecycle necesita su propio protocolo, no una afirmación de seguridad en el JSON de recursos.

#### Cortes resultantes y estados verificados en GitHub

| Issue | Entregable | Estado |
|---|---|---|
| [#1842](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1842) — Normalizar las rutas de recursos sin mutar el filesystem | Biblioteca neutral de raíz lógica/física, planned, relativos por segmentos y contención; sin mkdir. | Listo, sin dependencias; 5 CAs |
| [#1843](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1843) — Resolver las raíces efectivas del host y la release cargada de OpenCode | Biblioteca del borde para XDG/config/data/tool-output, manifiesto y metadata de proyección; no grants ni reparación. | Listo, bloqueado por #1842; 5 CAs |
| [#1844](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1844) — Descubrir las carpetas NuGet desde la CLI y los assets del worktree | Script neutral con procedencia, cobertura global-only/observed-assets y parser acotado; sin restore, clear o evaluación MSBuild. | Listo, bloqueado por #1842; 5 CAs |
| [#1845](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1845) — Usar las raíces NuGet efectivas en los agentes de inspección | Misma receta en test-writer/reviewer/bug-investigator, versiones/casing preservados y duplicados comparados con cmp -s. | Listo, bloqueado por #1844; 5 CAs homogéneos |
| [#1825](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1825) — Resolver el snapshot de recursos efectivos para la autonomía OpenCode | Ensamblador con inspect, identidad Git/worktree, scopes y bases de permisos, digest técnico y clausura autocontenida. | Listo, bloqueado por #1820/#1835/#1842/#1843/#1844; 6 CAs |
| [#1846](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1846) — Retener las releases OpenCode utilizadas por corridas activas | Protocolo de uso/retención coordinado con prune, sin borrar una release cargada. | Borrador, bloqueado por #1820; falta definir liveness/recuperación/callers |
| [#1847](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1847) — Aplicar el snapshot de recursos a delegados y etapas OpenCode | Extensión del binding publicado para roles, Task/headless/reanudación y pin por llamada. | Borrador, bloqueado por #1823/#1825/#1838/#1845/#1846/#1740; protocolo por cerrar |

#### Contrato y fronteras conservados

`resolve-opencode-resources.sh --project-root <approved-root> --worktree-root <execution-root>` recibe runtimeContext, ids cerrados de recursos requeridos y assets explícitos acotados. Devuelve `resolutionScope: resources`, estado, projectId/profileDigest, identidad de release, permissionBase, roots/relativos/aliases/exclusiones, metadata y resourcesDigest. La release es la del wrapper cargado; no un argumento elegido por el modelo ni el active recién consultado.

El common dir físico y la pertenencia del worktree se comprueban; el proyecto aprobado no se vuelve otro checkout editable por estar coordinando una etapa. Estado nuevo solo canónico, legacy de lectura, autorización y markers de control excluidos de escritura. NuGet se consulta cuando lo exige la matriz/rol; una fila documental no adquiere una dependencia accidental del SDK. Roots que el matcher no pueda representar literalmente fallan explícitamente, nunca se amplían a home. La resolución de symlinks es puntual, no una garantía contra TOCTOU o cualquier efecto shell.

El digest no incluye listado, contenido o mtime de tool-output ni el mero paso planned->existente sin deriva de root: crear una salida no debe invalidar el perfil. Sí incorpora identidad/bases/roots y metadata determinante. `ready` del resolver no equivale a permisos aplicados, assembly disponible, restore fresco, autorización administrativa ni certificación instalada.

Se sincronizaron #1836 y #1823 con runtimeContext/resourcesDigest y candidatos relativos/absolutos; #1839 con los ids de recursos y NuGet para fix-review; #1819 con la nueva invocación de #1845 y cmp -s; #1820 con el alcance expresamente elegido de tool-output; #1826/#1827 con los prerrequisitos de binding y retención. Los dos borradores no se declararon listos por tener cinco CAs: todavía requieren decisiones de protocolo y posible separación antes de estimar una implementación pequeña.

Se verificaron títulos, cuerpos, estados, labels, secciones y conteos de CAs en GitHub. No se cerraron issues, implementó código, aplicaron permisos o ejecutaron tests/runtimes/restore/podas. El checkout principal permaneció limpio en `main`/`70e71653c704`; todos los borradores locales están bajo `.mefisto/` ignorado. Se conserva la identidad de sesión y el PR documental #1808.

Próximo refinamiento recomendado: **#1846** (uso/retención), seguido del protocolo de **#1847**. #1842 ya es un entregable independiente implementable. No se calculó ni recomendó aquí un orden de batch manual.

## Descartado

- Parchar únicamente el permiso de `test-writer` o añadir una ruta más sin cubrir al agente iniciador.
- Recomendar «Always» como solución permanente: la documentación de OpenCode lo limita a la sesión.
- Presentar `--auto` como eliminación de todas las restricciones: los `deny` explícitos sobreviven.
- Proponer `external_directory: allow` sobre todo el sistema o quitar controles globales de la máquina para hacer funcionar un lector de release.
- Afirmar que `read: deny` protege secretos frente a toda forma de shell o búsqueda. Los permisos OpenCode son un control de UX, no aislamiento de seguridad.
- Copiar listas de permisos internos al consumidor o editar manualmente artefactos generados/releases.
- Confundir «no preguntar» con «no bloquear» o «exit 0» con «trabajo completo».
- Abrir issues cross-repo desde este planner, modificar el consumidor, cambiar autenticación o implementar código en esta sesión.

## Preguntas abiertas

- ¿Qué agente y versión de OpenCode ejecutaron el Grep reportado y qué regla produjo el prompt? Capturar evidencia sanitizada, no el contenido completo de configuración/auth stores.
- ¿Qué protocolo exacto de uso/liveness/recuperación adoptará #1846 para retener releases sin podar una corrida larga ni confiar en un PID reciclable?
- ¿Cómo transportará/revalidará #1847 el snapshot entre sesión padre, Task, headless y reanudación, antes del modelo y por llamada shell? La interfaz de recursos de #1825 ya quedó cerrada; aplicación y retención todavía no están implementadas ni refinadas a listo.
- ¿Qué plataforma y toolchains adoptará el worker aislado de #1824? Está diferido: **local primero** quedó decidido y su plataforma no bloquea #1820 ni los fixes actuales.
- ¿Qué formato y validadores materializarán las autorizaciones administrativas por acción/entorno/recurso en cada comando? Su inclusión en los lotes está aprobada en #1820; los scopes concretos y el consentimiento se resuelven por consumidor antes de ejecutar, no se otorgan durante esta planeación.
- ¿Qué versión(es) de OpenCode se certifican y cómo se invalida la certificación cuando cambia el runtime, la release, el perfil o el entorno?

## Referencias

Issues creados: #1813, #1814, #1815, #1816, #1817, #1818, #1819, #1820, #1821, #1822, #1823, #1824, #1825, #1826 y #1827; posteriormente #1834-#1836 al desglosar la entrada, #1837-#1839 al cerrar la proyección, #1840/#1841 al normalizar las operaciones Bash y #1842-#1847 al refinar recursos. Los primeros 15 se reforzaron con criterios de no regresión Claude. Se promovieron #1820, #1823, #1836, #1819 y #1825 a `estado:listo`, conservando los bloqueos donde corresponden. #1842-#1845 nacieron listos; #1846/#1847 siguen borradores. Se sincronizaron los consumidores de las interfaces y la certificación sin dar por implementados los contratos. Issues ajenos a este desglose refinados/cerrados por esta sesión: ninguno.

Antecedentes del repo activo:

- [#1761: permitir lectura de release/config de agentes](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1761).
- [#1750: permitir preámbulo de release](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1750).
- [#1740: aislar entorno tmux](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1740).

Fuentes primarias de Mefisto: las rutas y líneas citadas arriba corresponden a `b1983395acf4`; fuentes canónicas de permisos y generación: `src/published/contract/opencode-permissions.json`, `src/published/contract/README.md`, `src/published/scripts/adapters/adapter-opencode.sh`; ejecución/telemetría: `src/runtime/lib/runtime-opencode.{sh,jq}` y `scripts/_pipeline-common.sh`. ADRs: MEF-ADR-0019, 0022, 0025, 0031, 0049, 0050, 0052 y 0053.

Fuentes oficiales OpenCode consultadas vía GitHub, fijadas a `v1.18.29`:

- [Permisos: actions, last match, external_directory, auto y agentes](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/web/src/content/docs/permissions.mdx).
- [Comandos: herencia del agente actual, agent y subtask](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/web/src/content/docs/commands.mdx).
- [Configuración: fusión, precedencia, overrides y profundidad de delegación](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/web/src/content/docs/config.mdx).
- [Grep y doble comprobación](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/opencode/src/tool/grep.ts) y [external-directory](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/opencode/src/tool/external-directory.ts).
- [Parser/candidatos shell](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/opencode/src/tool/shell.ts) y [clave de permiso bash](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/opencode/src/tool/shell/id.ts).
- [Task](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/opencode/src/tool/task.ts) y [restricciones heredadas por sesiones hijas](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/opencode/src/agent/subagent-permissions.ts).
- [Construcción de permisos de agentes y excepciones tool-output](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/opencode/src/agent/agent.ts) y [directorio de truncación](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/opencode/src/tool/truncation-dir.ts).
- [Modelo de seguridad: OpenCode no es un sandbox](https://github.com/anomalyco/opencode/blob/v1.18.29/SECURITY.md).
- [Read](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/opencode/src/tool/read.ts), [Edit](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/opencode/src/tool/edit.ts) y [Write](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/opencode/src/tool/write.ts): candidatos relativos al worktree del runtime.
- [Global.Path](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/core/src/global.ts), [PluginInput/hooks](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/plugin/src/index.ts) y [SDK v1 Path](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/sdk/js/src/gen/types.gen.ts): procedencia y límites del contexto de rutas.
- Microsoft Learn: [global packages y overrides](https://learn.microsoft.com/nuget/consume-packages/managing-the-global-packages-and-cache-folders), [dotnet nuget locals](https://learn.microsoft.com/dotnet/core/tools/dotnet-nuget-locals) y [restore/assets](https://learn.microsoft.com/nuget/consume-packages/package-restore). [NuGet.Client LockFileFormat](https://github.com/NuGet/NuGet.Client/blob/dev/src/NuGet.Core/NuGet.ProjectModel/LockFile/LockFileFormat.cs): packageFolders; las pruebas previstas fijan fixtures v3, no descargan esa rama.
