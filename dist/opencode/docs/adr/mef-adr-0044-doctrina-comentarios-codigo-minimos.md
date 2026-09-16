# MEF-ADR-0044: Doctrina de comentarios de codigo minimos

- **Fecha**: 2026-08-15
- **Estado**: aceptado
- **Aplica a**: doctrina del marco que fija cuando un comentario de codigo merece existir y quien limpia el exceso. Alcance pleno (umbral de escritura + modo limpieza) sobre `.cs` (produccion, tests, smoke tests); alcance parcial (solo umbral de escritura, sin modo limpieza) sobre HCL; fuera de alcance JSON/YAML de workflows y Markdown/bash del propio plugin. Este ADR funda la doctrina; no la propaga a los agentes escritores (`test-writer`, `implementer`, `smoke-test-writer`) ni crea el Agent Skill de limpieza `comment-cleanup` (MEF-ADR-0033) -- ambos quedan para issues dependientes que este ADR bloquea.

## Contexto

Los agentes escritores del harness generan comentarios en exceso sobre el codigo del consumidor. El patron se repite en tres formas:

- **Narracion del codigo**: un comentario que repite en prosa lo que la linea siguiente ya dice (`// Incrementa el contador` sobre `contador++`).
- **Provenance**: la convencion `// HU-XX` que `test-writer` antepone a sus tests, y citas sueltas a un issue, PR o tarea que origino el codigo -- informacion que pertenece al commit/PR, no al archivo.
- **Resumen de implementacion**: un bloque que describe que hizo el cambio o narra su historia temporal ("ahora usamos X en vez de Y"), en vez de documentar el estado presente del codigo.

Ningun ADR del marco fijaba, antes de este, un criterio decidible para cuando un comentario merece existir ni quien es responsable de podar el exceso una vez escrito. La convencion `// HU-XX` en particular no tiene **ningun consumidor mecanico** hoy -- ningun script, gate ni agente la lee para correlacionar un test con su historia de usuario -- por lo que su unico efecto es ruido de provenance que un agente futuro debe ignorar para entender el codigo.

Este ADR funda la doctrina de comentarios minimos: la jerarquia entre codigo/comentario/documentacion externa, el umbral que decide si un comentario especifico merece escribirse o sobrevivir, la lista de patrones proscritos, la regla de precedencia para citas a ADR, el alcance por lenguaje, y la frontera de responsabilidad de limpieza. Dos issues dependientes (bloqueados por este) hacen operable la doctrina: uno propaga el umbral a los agentes escritores y retira `// HU-XX` de `test-writer`; el otro crea el Agent Skill `comment-cleanup` con la mecanica de limpieza (clasificar/comprimir/releer) que este ADR deliberadamente no incluye -- conforme a MEF-ADR-0033, doctrina pesada y operativa vive en un Skill de progressive disclosure, no en el cuerpo de un ADR.

### Terminologia propia, no de los repos citados

Los terminos **Context Delta** y **Decision Delta** (seccion 2) son sintesis propia de este ADR a partir de una guia de doctrina de documentacion minima de codigo (input de la sesion de planeacion del issue #632, sintetizada con asistencia de un modelo GPT). Ninguno de los cuatro `AGENTS.md` citados en "Referencias" usa esta terminologia exacta; se citan porque su doctrina de comentarios converge independientemente hacia el mismo principio de fondo (comentar el "por que", no el "que"; default a ningun comentario), no porque acunen estos dos nombres.

## Decision

### 1. Jerarquia: codigo autodocumentado > comentario > documentacion externa

Ante la necesidad de transmitir informacion sobre el codigo, el marco fija un orden de preferencia estricto:

1. **Codigo autodocumentado** (nombres claros, tipos expresivos, estructura que refleja la intencion) es siempre la primera opcion. Si un nombre mejor o una extraccion de metodo eliminan la necesidad de explicar algo, esa refactorizacion se prefiere sobre escribir un comentario.
2. **Comentario** es la segunda opcion, reservada para informacion que el codigo no puede expresar por si mismo (seccion 2).
3. **Documentacion externa** (ADRs del marco o del consumidor, `docs/`) es el ultimo recurso para doctrina que trasciende un archivo o un modulo puntual -- nunca un sustituto de un comentario que documenta una restriccion local activa (seccion 4).

**Default: sin comentario.** Un archivo nuevo no necesita comentarios para ser correcto; la ausencia de comentarios no es una deficiencia a corregir, es el estado esperado salvo que el umbral de la seccion 2 diga lo contrario.

### 2. Umbral doble para escribir o conservar un comentario

Un comentario merece existir (al escribirse, o al sobrevivir una limpieza) solo si cumple **ambas** condiciones a la vez:

- **Context Delta**: el comentario porta informacion importante que no es inferible del codigo mismo -- ni de sus nombres, ni de sus tipos, ni de su estructura, ni de sus tests, ni de la semantica convencional del lenguaje o la libreria en uso.
- **Decision Delta**: esa informacion, de perderse, puede cambiar materialmente una modificacion futura del codigo -- no es trivia, es una restriccion o un invariante que condiciona como se edita ese codigo despues.

**Test operativo**: *"si este comentario desapareciera, ¿un agente competente podria hacer un cambio plausible pero incorrecto?"*. Si la respuesta es no -- el codigo, sus nombres y su estructura ya bastan para que cualquier agente o desarrollador acierte -- el comentario no pasa el umbral, se escriba o se encuentre al revisar.

Las dos condiciones son necesarias, ninguna es suficiente por si sola: informacion no inferible del codigo pero irrelevante para futuras modificaciones (Context Delta sin Decision Delta) no pasa el umbral -- es trivia interesante, no una restriccion que documentar. Informacion que si cambiaria una decision futura pero que ya es evidente por el nombre o la estructura (Decision Delta sin Context Delta) tampoco lo pasa -- el codigo ya la comunica, un comentario solo la duplicaria.

### 3. Proscritos

Los siguientes patrones nunca pasan el umbral de la seccion 2 -- ninguno aporta Context Delta que el codigo, los nombres, los tipos o los tests no aporten ya:

- **Narracion del codigo**: un comentario que repite en prosa lo que la linea o el bloque siguiente ya dicen.
- **Explicacion de sintaxis o de librerias estandar**: documentar que hace un `foreach`, un `using`, o un metodo publico bien documentado de una libreria de terceros -- esa informacion vive en la documentacion oficial de la libreria o del lenguaje, no en el codigo del consumidor.
- **Resumen de la implementacion o del cambio**: un bloque que describe que hizo un PR, un commit o una sesion de trabajo. Esa informacion pertenece al mensaje de commit y a la descripcion del PR (`git blame`/`git log` son la fuente autoritativa), nunca al archivo.
- **Razonamiento del agente**: rastros de "pense en X pero elegi Y" que documentan el proceso deliberativo de quien escribio el codigo, no una restriccion vigente sobre el codigo mismo.
- **Provenance**: referencia a la HU, issue, PR o tarea que origino el codigo -- incluida la convencion `// HU-XX` que `test-writer` antepone hoy a sus tests, que este ADR proscribe explicitamente por carecer de todo consumidor mecanico (ningun script, gate ni agente la lee). Su retiro efectivo de `test-writer` ocurre en el issue dependiente que propaga esta doctrina a los agentes escritores, no en este ADR.
- **Narracion temporal**: comentarios que documentan la historia del codigo en vez de su estado presente ("ahora usamos X en vez de Y", "antes esto se hacia de otra forma"). Esa historia vive en `git log`/`git blame`, que son la fuente autoritativa de que cambio y cuando -- un comentario que la duplica en el archivo se desactualiza en la primera edicion futura que no la actualice.

### 4. Regla de precedencia: una cita a ADR se conserva solo junto a una restriccion local activa

Una cita a `MEF-ADR-XXXX` (o a un ADR del proyecto consumidor) dentro de un comentario de codigo se conserva **unicamente cuando acompana una restriccion local activa**: el comentario documenta la restriccion en si (que no se puede inferir del codigo, y que condiciona una edicion futura -- pasa el umbral doble de la seccion 2), y la cita es un puntero resoluble que le da a un agente futuro donde profundizar si la restriccion no le basta.

La cita **sola**, sin la restriccion que la acompana, es provenance disfrazada de documentacion -- indica de donde vino la decision, no que decision rige el codigo presente -- y se poda igual que cualquier otro provenance de la seccion 3.

**Excepcion: comentarios mandatados por ADRs del marco y guardrails deliberados de scaffolders.** Dos categorias de comentarios -- tres casos concretos hoy -- existen precisamente porque un ADR o una plantilla los exige, y este ADR los blinda explicitamente de cualquier limpieza:

- El comentario junto al test de composicion del contenedor DI que documenta los limites de `ValidateOnBuild` (MEF-ADR-0029, seccion 3: *"El codigo generado documenta este limite con un comentario junto a la clase de test... para que no se lea como garantia total"*).
- El "comentario gemelo" de `AddSource`/`ActivitySource` que `domain-scaffolder` y `projections-scaffolder` dejan junto a la fuente de OpenTelemetry que registran (MEF-ADR-0034, seccion 10, sobre las fuentes de traza del worker de proyecciones).
- Guardrails deliberados emitidos por plantillas de scaffolders, como el "No 'limpies' `using OpenTelemetry;` por parecer redundante" de `agents/projections-scaffolder.md` (documenta que sin ese `using`, `ConfigureResource`/`WithTracing` fallan con `CS1061` -- una restriccion local activa que el propio codigo no hace evidente sin decompilar el SDK).

Estos tres casos pasan el umbral doble por construccion (documentan una restriccion no inferible que condiciona una edicion futura) y un `comment-cleanup` que los borrara estaria destruyendo doctrina mandatada, no ruido.

### 5. Alcance por lenguaje

- **`.cs` (produccion, tests, smoke tests)**: alcance pleno. El umbral doble (seccion 2) rige tanto la escritura de comentarios nuevos como la limpieza de comentarios existentes (seccion 6).
- **HCL (Terraform)**: el umbral aplica **solo como criterio de escritura de codigo nuevo** -- un comentario HCL nuevo debe pasar el mismo umbral doble que uno en `.cs`. **Sin modo limpieza**: ningun agente ni Skill de este marco poda comentarios HCL existentes. Los comentarios de Terraform son el **hogar canonico de documentacion** de varias piezas de doctrina del marco -- la topologia de enrutamiento que MEF-ADR-0027 documenta *"en los comentarios de Terraform de la subscription"* (seccion sobre documentacion en claro) y las notas de la politica APIM que MEF-ADR-0032 (trampa B6) fija explicitamente que *"cualquier nota va en comentarios HCL (`#`), nunca dentro del `xml_content`"*. Podar ese comentario destruiria la unica copia de esa doctrina.
- **JSON/YAML de workflows**: fuera de alcance. JSON no admite comentarios -- MEF-ADR-0038 (seccion 7) ya documenta el efecto concreto de esa limitacion (*"JSON no admite comentarios que digan 'este bloque no hace nada'"*, sobre el bloque inerte de `samplingSettings` en `host.json`) -- y YAML de workflows de GitHub Actions no es un artefacto que este ADR gobierne.
- **Markdown/bash del propio plugin**: fuera de alcance de este ADR. La prosa de un `.md` o los comentarios de un script bash del harness no son "codigo del consumidor" en el sentido que motiva este ADR -- son doctrina o tooling del propio marco, gobernados por las convenciones de documentacion del propio repo (`CLAUDE.md` del harness, README de cada carpeta), no por este ADR.

### 6. Responsabilidad y frontera de limpieza

La limpieza de comentarios que no pasan el umbral es responsabilidad del **reviewer** (fase refactor del pipeline TDD, `agents/reviewer.md`), sujeta a tres restricciones:

- **Exclusivamente sobre archivos que el PR del issue ya interviene**: el reviewer nunca abre ni edita un archivo externo al diff del propio PR para podar comentarios -- limpiar un archivo no tocado por el issue es un cambio fuera de alcance del propio PR, con su propio costo de revision y riesgo de regresion no relacionado.
- **Behavior-preserving estricto**: podar un comentario nunca cambia el comportamiento del codigo. Es una operacion puramente textual.
- **Comentario que contradice la implementacion**: si un comentario existente describe algo que el codigo ya no hace (quedo desactualizado por una edicion posterior), el reviewer **no lo resuelve por su cuenta** -- lo reporta sin tocar, porque la discrepancia puede senalar un bug real en vez de solo un comentario obsoleto, y decidir cual de los dos esta mal (el comentario o el codigo) es criterio humano.

La mecanica operativa detallada de la limpieza -- como el reviewer clasifica, comprime y relee cada comentario candidato -- **no vive en este ADR**. Vive en el Agent Skill `comment-cleanup` (MEF-ADR-0033, progressive disclosure), creado por un issue dependiente que este ADR bloquea: doctrina de umbral y alcance es liviana y estable (cabe en un ADR), mecanica operativa de limpieza es pesada y solo se paga cuando el reviewer efectivamente la ejecuta.

## Alternativas consideradas

### Alt 1: prohibir todo comentario, sin excepciones

Fijar una regla mas simple: ningun comentario nuevo, punto -- sin umbral que evaluar caso por caso.

**Descartada**: el marco ya tiene comentarios **mandatados** por otros ADRs (MEF-ADR-0029, MEF-ADR-0034) y guardrails deliberados de scaffolders que documentan restricciones reales no inferibles del codigo (seccion 4). Una prohibicion absoluta entraria en conflicto directo con doctrina ya aceptada, o forzaria a esos ADRs a mover su contenido a documentacion externa -- peor ergonomia para un agente que edita el archivo directamente y nunca abre el ADR citado.

### Alt 2: conservar toda cita a ADR en un comentario, sin exigir una restriccion local que la acompane

Tratar cualquier cita `MEF-ADR-XXXX` como valiosa por si misma -- un puntero a mas contexto nunca esta de mas.

**Descartada**: es exactamente el patron de provenance que origina este ADR. Una cita sin la restriccion que documenta se vuelve indistinguible de "este codigo nacio a partir de esa decision", informacion historica sin Decision Delta -- no dice que hacer distinto en una edicion futura, solo de donde vino. Peor aun, una cita bare envejece mal: si el ADR se enmienda o se retira, el comentario queda apuntando a una version de la doctrina que ya no rige, sin que nada en el archivo lo advierta.

### Alt 3: aplicar el mismo modo de limpieza (no solo el umbral de escritura) a HCL

Extender el modo limpieza de `.cs` a Terraform, dado que ambos son codigo y ambos pueden acumular comentarios narrativos.

**Descartada** (seccion 5): a diferencia de `.cs`, HCL es el hogar canonico de piezas de doctrina completa del marco -- MEF-ADR-0027 (topologia de enrutamiento) y MEF-ADR-0032 B6 (notas de la politica APIM) documentan explicitamente que esa informacion vive en comentarios HCL porque no tiene otro lugar donde vivir (el `xml_content` de una politica APIM no admite XML comments intercalados sin romper el orden de sus elementos, MEF-ADR-0032 B6). Un modo de limpieza que trate esos comentarios igual que narracion en `.cs` los borraria sin sustituto.

### Alt 4: incluir la mecanica operativa de limpieza (clasificar/comprimir/releer) en este mismo ADR

Escribir el algoritmo completo que el reviewer sigue para clasificar cada comentario candidato, en vez de diferirlo a un Skill separado.

**Descartada**: MEF-ADR-0033 ya fijo que la doctrina pesada y operativa -- que se paga en tokens solo cuando la tarea concreta la dispara -- vive en un Agent Skill de progressive disclosure, no en el cuerpo de un agente ni de un ADR que se relee en cada consulta de doctrina de comentarios. Meter la mecanica aqui infla este ADR con contenido que la mayoria de las lecturas (¿este comentario pasa el umbral?) no necesita.

## Consecuencias

### Positivas

- **Criterio decidible en vez de gusto individual**: el umbral doble (Context Delta + Decision Delta) mas su test operativo le dan a cualquier agente o desarrollador una pregunta concreta que responder, en vez de dejar la decision al estilo de quien escribe el codigo.
- **La convencion `// HU-XX` deja de generar ruido sin proposito**: se proscribe explicitamente por no tener consumidor mecanico; su retiro efectivo (issue dependiente) elimina un patron que hoy se copia por inercia en cada test nuevo.
- **Las citas a ADR dejan de envejecer mal**: al exigir que acompanen una restriccion local activa, un comentario que cita doctrina sigue siendo utilizable aunque el lector nunca abra el ADR citado -- la restriccion misma ya esta en el archivo.
- **HCL conserva su rol de hogar canonico de documentacion**: el alcance por lenguaje protege explicitamente la doctrina que MEF-ADR-0027/MEF-ADR-0032 ya depositaron en comentarios Terraform, evitando que un futuro `comment-cleanup` mal generalizado la destruya.
- **Progressive disclosure real**: la mecanica de limpieza queda deferida a un Skill (MEF-ADR-0033), asi que consultar esta doctrina (¿debo escribir este comentario?) no exige cargar tambien el algoritmo completo de limpieza que solo el reviewer necesita.

### Negativas

- **Doctrina sin propagacion inmediata**: este ADR no cambia el comportamiento de ningun agente escritor por si solo -- `test-writer` sigue emitiendo `// HU-XX` y los demas agentes siguen sin el umbral hasta que el issue dependiente de propagacion cierre. Existe una ventana en la que el ADR esta aceptado pero no aplicado.
- **Ningun mecanismo de limpieza ejecutable todavia**: hasta que el Agent Skill `comment-cleanup` exista, la unica forma de aplicar la seccion 6 es revision manual -- este ADR fija la responsabilidad y la frontera, no la herramienta.
- **Ambiguedad residual en el umbral**: "Context Delta" y "Decision Delta" son un criterio de dos preguntas, no una regla mecanica -- dos agentes distintos pueden discrepar sobre si un comentario puntual pasa el umbral. El test operativo (seccion 2) acota la discrepancia pero no la elimina.
- **Excepcion de precedencia exige memoria de los tres casos mandatados**: quien aplique la seccion 6 debe reconocer los comentarios blindados por MEF-ADR-0029/MEF-ADR-0034 y los guardrails de scaffolders para no podarlos por error; la lista no es autocontenida en el codigo mismo, depende de conocer esos ADRs.

## Referencias

- **[1]** Apache Airflow, `AGENTS.md`, seccion de estandares de codigo: *"Comment sparingly — code says _what_, comments say _why_. Add a comment only when the reasoning is non-obvious and cannot be carried by a clear name or the code itself."* Advierte ademas contra comentarios que narran la linea siguiente, contra prosa multi-linea innecesaria y contra repetir el mismo razonamiento en varios sitios. https://github.com/apache/airflow/blob/main/AGENTS.md
- **[2]** OpenHands `software-agent-sdk`, `AGENTS.md`, seccion "Comments policy": *"Do NOT add comments that restate what the code already says, summarize the surrounding diff/PR, or narrate the change history ('previously we did X, now we do Y')."* Y en sentido positivo: *"DO add a comment when the code expresses something genuinely unintuitive: a non-obvious invariant, a workaround for an external bug, a subtle ordering/locking requirement, or a deliberate trade-off the reader cannot infer from the code itself."* Fuente directa de la proscripcion de narracion temporal y de resumen de diff/PR (seccion 3), y del principio "restructurar/renombrar es preferible a comentar" que subyace a la jerarquia de la seccion 1. https://github.com/OpenHands/software-agent-sdk/blob/main/AGENTS.md
- **[3]** Vercel `eve`, `AGENTS.md`, principio de codificacion #10: *"Comment why, not what. Default to no comment; well-named code is the documentation. Comment only what the code cannot say itself — a non-obvious why, an invariant, a surprising edge case."* Fuente directa del default "sin comentario" (seccion 1) y de la formulacion "por que, no que" que subyace al umbral doble. https://github.com/vercel/eve/blob/main/AGENTS.md
- **[4]** OpenAI `apps-sdk-ui`, `AGENTS.md`, seccion "Contributing": *"Do not add comments for obvious behaviors, and do not change build settings."* Fuente de la proscripcion de explicar sintaxis o comportamiento evidente (seccion 3). https://github.com/openai/apps-sdk-ui/blob/main/AGENTS.md
- **Verificacion de [1]-[4]**: las cuatro URLs se consultaron el 2026-08-15 (fecha de este ADR) contra el `AGENTS.md` publicado en la rama `main` de cada repositorio; las cuatro resolvieron y las citas de arriba son textuales de esa lectura. Ninguna quedo sin verificar (principio de verificacion de fuentes, `CLAUDE.md`). Al ser archivos de rama viva, su contenido puede cambiar despues de esta fecha.
- MEF-ADR-0027 (enrutamiento multidestinatario por correlation filter): fija que la topologia de Service Bus se documenta *"en los comentarios de Terraform de la subscription"* -- fundamenta que HCL es hogar canonico de documentacion (seccion 5). No se enmienda.
- MEF-ADR-0029 (test de composicion del contenedor DI): mandata el comentario junto a la clase de test que documenta los limites de `ValidateOnBuild` -- uno de los comentarios blindados por la regla de precedencia (seccion 4). No se enmienda.
- MEF-ADR-0030 (esquema de identificacion de ADRs): fija el numero `MEF-ADR-0044` para este documento.
- MEF-ADR-0032 (identidad y autenticacion en el borde, WorkOS + APIM): trampa B6 fija que toda nota sobre la politica `validate-jwt` *"va en comentarios HCL (`#`), nunca dentro del `xml_content`"* -- segunda fuente de HCL como hogar canonico de documentacion (seccion 5). No se enmienda.
- MEF-ADR-0033 (adopcion de Agent Skills): la mecanica operativa de limpieza (clasificar/comprimir/releer) vive en el Agent Skill `comment-cleanup`, no en este ADR -- aplicacion directa de su modelo de progressive disclosure (seccion 6, Alt 4).
- MEF-ADR-0034 (worker de proyecciones y read models, seccion 10): mandata el "comentario gemelo" junto a la fuente de OpenTelemetry (`AddSource`) que `domain-scaffolder`/`projections-scaffolder` registran -- segundo comentario blindado por la regla de precedencia (seccion 4). No se enmienda.
- MEF-ADR-0038 (control de volumen de telemetria, seccion 7): documenta que *"JSON no admite comentarios que digan 'este bloque no hace nada'"* sobre el bloque inerte de `samplingSettings` de `host.json` -- fundamenta la exclusion de JSON del alcance de este ADR (seccion 5). No se enmienda.
- MEF-ADR-0040 (fuentes de conocimiento del dominio sin capa EDA): antecedente del principio "el codigo por rol es fuente de verdad, la documentacion externa no debe divergir de si misma" que informa la jerarquia de la seccion 1.
- `agents/projections-scaffolder.md` (linea ~573): guardrail deliberado *"No 'limpies' `using OpenTelemetry;` por parecer redundante con los dos hijos: sin el, `ConfigureResource` y `WithTracing` fallan con CS1061 y el seam no compila"* -- tercer caso concreto blindado por la regla de precedencia (seccion 4).
- Issue #632: origen de este ADR y de las seis decisiones de su sesion de planeacion (2026-08-14).

## Control de cambios

- 2026-08-15: creacion como `aceptado` (issue #632). Fija la jerarquia codigo-autodocumentado > comentario > documentacion externa con default "sin comentario"; el umbral doble Context Delta + Decision Delta con su test operativo; la lista de patrones proscritos (narracion del codigo, explicacion de sintaxis/librerias estandar, resumen de implementacion/cambio, razonamiento del agente, provenance incluyendo la proscripcion explicita de `// HU-XX`, narracion temporal); la regla de precedencia para citas a ADR (se conservan solo junto a una restriccion local activa, con excepcion explicita para los comentarios mandatados por MEF-ADR-0029/MEF-ADR-0034 y guardrails deliberados de scaffolders); el alcance por lenguaje (`.cs` pleno, HCL solo escritura sin modo limpieza, JSON/YAML de workflows y Markdown/bash del propio plugin fuera de alcance); y la responsabilidad de limpieza del reviewer acotada al diff del propio PR, behavior-preserving, con comentarios contradictorios reportados sin resolver. Declara "Context Delta"/"Decision Delta" como sintesis propia, no terminologia de los `AGENTS.md` citados. No propaga la doctrina a los agentes escritores ni crea el Agent Skill `comment-cleanup` -- ambos quedan para issues dependientes que este ADR bloquea.
