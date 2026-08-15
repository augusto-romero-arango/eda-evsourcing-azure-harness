---
name: comment-cleanup
description: Mecanica de limpieza de comentarios de codigo en archivos .cs -- clasificar cada comentario, aplicar el umbral doble Context Delta/Decision Delta (MEF-ADR-0044), intentar codificar la informacion en el codigo, comprimir los sobrevivientes y releer el archivo. Usar cuando se revise o refactorice un archivo .cs sobre-comentado: narracion que repite el codigo, provenance (`// HU-XX`, citas de issue/PR/HU), citas de ADR sueltas sin restriccion activa, o comentarios que duplican lo que un nombre, un tipo o un test ya dicen.
---

# Limpieza de comentarios de codigo

Mecanica operativa de MEF-ADR-0044 (doctrina de comentarios minimos): ese ADR fija **cuando**
un comentario merece existir; este Skill fija **como** podar los que no. Lo usa el `reviewer`
(fase refactor del pipeline TDD, MEF-ADR-0044 seccion 6) sobre archivos `.cs` que el propio PR
del issue ya interviene -- nunca sobre un archivo externo al diff. Tambien se dispara en
cualquier sesion interactiva sobre un archivo `.cs` que el usuario senale como sobre-comentado,
sin pasar por el pipeline (MEF-ADR-0033).

**Este Skill no ensena a escribir comentarios nuevos** -- esa doctrina compacta vive en el body
de cada agente escritor (`test-writer`, `implementer`, `smoke-test-writer`). Aqui solo la
mecanica de limpieza sobre comentarios ya existentes.

**Alcance**: `.cs` (produccion, tests, smoke tests) unicamente -- MEF-ADR-0044 seccion 5 fija
que HCL, JSON/YAML de workflows y Markdown/bash del propio plugin quedan fuera de este modo de
limpieza (HCL en particular es hogar canonico de documentacion de MEF-ADR-0027/MEF-ADR-0032; no
se poda).

## 1. Clasificar cada comentario candidato

Antes de tocar nada, recorre el archivo y clasifica cada comentario existente en una de estas
categorias. La etiqueta es solo el punto de partida -- el umbral del paso 2 decide, no la
categoria por si sola:

| Categoria | Descripcion | Suele... |
|---|---|---|
| Narracion del codigo | Repite en prosa lo que la linea o el bloque siguiente ya dice | podarse |
| Rationale obvio | Explica una decision ya evidente por el nombre o la estructura | podarse |
| Heading estructural | Divide el archivo en secciones sin aportar informacion nueva | podarse |
| Provenance | Cita la HU/issue/PR/tarea que origino el codigo (`// HU-XX` incluido) | podarse |
| Doc redundante de API | Explica sintaxis del lenguaje o un metodo bien documentado de una libreria de terceros | podarse |
| Restriccion no obvia | Documenta un invariante o una restriccion que condiciona una edicion futura | conservarse |
| Workaround externo | Documenta un rodeo forzado por un bug o limite de una libreria/API externa | conservarse |

Ver **[ejemplos.md](ejemplos.md)** para un antes/despues de cada categoria.

## 2. Aplicar el umbral doble (MEF-ADR-0044 seccion 2)

Para cada comentario clasificado, evalua las dos condiciones -- **ambas** son necesarias:

- **Context Delta**: ¿la informacion no es inferible del codigo mismo (nombres, tipos,
  estructura, tests, semantica convencional del lenguaje o la libreria)?
- **Decision Delta**: ¿perder esa informacion podria hacer que una edicion futura sea
  plausible pero incorrecta?

**Test operativo**: *"si este comentario desapareciera, ¿un agente competente podria hacer un
cambio plausible pero incorrecto?"*. Si la respuesta es no, el comentario no pasa el umbral --
se poda, sin importar que tan bien escrito este.

Un comentario con Context Delta sin Decision Delta (trivia interesante que no cambia ninguna
decision futura) no pasa. Uno con Decision Delta sin Context Delta (la informacion ya es
evidente por el nombre o la estructura) tampoco.

## 3. Intentar codificar la informacion en el codigo antes de conservar el comentario

Antes de decidir que un comentario sobrevive, evalua si la jerarquia de MEF-ADR-0044 seccion 1
resuelve la necesidad sin el: un nombre mas claro, un tipo mas expresivo, una extraccion de
metodo, o una assertion/guard clause que haga el invariante verificable en vez de solo narrado.
Si la refactorizacion es segura (behavior-preserving) y elimina la necesidad de explicar algo,
prefierela sobre conservar el comentario. Solo cuando el codigo no puede expresar la restriccion
por si mismo el comentario que paso el umbral del paso 2 se conserva tal cual.

## 4. Comprimir los sobrevivientes

Un comentario que pasa el umbral no se copia intacto si es verboso: se reduce a la restriccion
misma, sin la narracion, el razonamiento deliberativo o el contexto historico que lo rodea. El
objetivo es la restriccion en la menor cantidad de palabras que la transmitan sin ambiguedad --
no una prosa completa que documente ademas por que se llego a ella.

## 5. Releer el archivo completo y validar behavior-preserving

Despues de aplicar todas las podas y compresiones, relee el archivo **completo** (no solo el
diff de tus propios cambios) para confirmar:

- Ningun cambio altero el comportamiento del codigo -- podar comentarios es una operacion
  puramente textual (MEF-ADR-0044 seccion 6).
- Ningun comentario podado dejaba huerfana una referencia (p. ej. un comentario que explicaba
  un nombre generico que ahora, sin el, resulta ambiguo -- senal de que faltaba la refactorizacion
  del paso 3, no solo la poda).
- Si el archivo tiene tests, siguen en verde tras la limpieza.

## 6. Regla de seguridad: nunca podar mecanicamente

- No elimines comentarios por coincidencia de patron (`// HU-`, `// TODO`, etc.) sin leer cada
  uno: la mecanica es clasificar y evaluar el umbral, no un `grep -v` ciego.
- Si un comentario verboso mezcla narracion con una restriccion valiosa, **conserva la
  restriccion y poda solo la narracion** -- no es todo-o-nada por comentario.
- **Comentario que contradice la implementacion**: si un comentario describe algo que el codigo
  ya no hace, no lo resuelvas por tu cuenta. Reportalo sin tocarlo -- la discrepancia puede
  senalar un bug real, y decidir cual de los dos esta mal es criterio humano (MEF-ADR-0044
  seccion 6).

## 7. Regla de precedencia para citas a ADR (MEF-ADR-0044 seccion 4)

- Una cita `MEF-ADR-XXXX` (o a un ADR del consumidor) **junto a una restriccion local activa**
  se conserva -- la cita es el puntero resoluble, la restriccion es lo que realmente pasa el
  umbral.
- Una cita **sola**, sin la restriccion que la acompana, es provenance disfrazada: se poda igual
  que cualquier otra cita de origen.
- **Excepcion -- nunca podar estos, pasan el umbral por construccion**:
  - El comentario junto al test de composicion del contenedor DI que documenta los limites de
    `ValidateOnBuild` (MEF-ADR-0029).
  - El "comentario gemelo" de `AddSource`/`ActivitySource` que `domain-scaffolder` y
    `projections-scaffolder` dejan junto a la fuente de OpenTelemetry que registran
    (MEF-ADR-0034 seccion 10).
  - Guardrails deliberados emitidos por plantillas de scaffolders, como el de `using
    OpenTelemetry;` en `agents/projections-scaffolder.md` (ver [ejemplos.md](ejemplos.md)).

## 8. Frontera de limpieza

- **Solo archivos que el PR del issue ya interviene** -- nunca abras ni edites un archivo
  externo al diff propio para podar comentarios.
- **Behavior-preserving estricto** -- ninguna poda cambia comportamiento.
- Ver paso 6 para el manejo de comentarios contradictorios.

## Que NO fija este Skill

- La doctrina de umbral de escritura (que comentario merece escribirse la primera vez): vive en
  MEF-ADR-0044 y en los bodies compactos de los agentes escritores.
- Limpieza de HCL, JSON/YAML de workflows o Markdown/bash del propio plugin: fuera de alcance
  (MEF-ADR-0044 seccion 5).
- Cuando el pipeline dispara esta limpieza: lo fija `agents/reviewer.md` (seccion 6b, el paso de
  su fase de refactor que precarga este Skill via frontmatter `skills:`).

## Recursos

- **[ejemplos.md](ejemplos.md)** -- antes/despues en C# del marco para cada categoria del paso 1,
  incluyendo los tres comentarios mandatados que la regla de precedencia blinda.
