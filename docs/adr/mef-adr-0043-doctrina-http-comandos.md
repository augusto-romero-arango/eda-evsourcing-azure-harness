# MEF-ADR-0043: Doctrina HTTP de comandos (verbo y forma de ruta)

- **Fecha**: 2026-08-14
- **Estado**: aceptado
- **Aplica a**: doctrina del marco que fija, para toda Function HTTP de **comando** (nunca de query -- MEF-ADR-0042 ya cubre GET/QUERY), el metodo HTTP y la forma de la ruta REST: un test de precedencia decidible (POST a la coleccion / PUT / DELETE / `POST {recurso}:{verbo}`), la precondicion de ids URL-safe, el casing kebab-case minusculo y la simetria CQRS entre la API (imperativo) y el event store (pasado). Enmienda MEF-ADR-0006 (casing de rutas, ejemplo canonico, referencia cruzada) y MEF-ADR-0011 (contrato HTTP como campo del Definition of Ready). Frontera con MEF-ADR-0042 (queries, sin cambio). Compatible con MEF-ADR-0004 (declinar con resultado -- el 409 de PUT es un caso mas de esa doctrina) y con MEF-ADR-0037 (identidad de stream en la ruta -- este ADR solo agrega la precondicion URL-safe -- charset RFC 3986, criterio rechazar-vs-normalizar por propiedad del dato --, no reabre el parseo). Anota una consecuencia a verificar en el borde APIM (MEF-ADR-0032), sin enmendarlo.

## Contexto

MEF-ADR-0006 norma el **nombre** de las Functions de comando (verbo infinitivo + sustantivo) y, desde su enmienda del issue #363, tambien el naming y la ruta de las Functions de **query**. MEF-ADR-0042 cierra la frontera GET/QUERY para queries. Pero ningun ADR del marco fija **que metodo HTTP usa un comando ni la forma de su ruta** -- el marco daba por sentado `POST` para todo comando, sin declarar el criterio, y sin doctrina sobre el casing de los segmentos.

El consumidor Bitakora.ControlAsistencia evidencio drift real al auditar sus 11 comandos existentes con el experto de dominio (tabla completa en el issue #621, seccion "Evidencia"):

- **Casing mixto entre dominios**: unos comandos usaban `Route = "Colaboradores/Etiquetas"` (PascalCase), otros `control-horas/marcaciones` (kebab-case) -- sin criterio escrito que dijera cual era el correcto.
- **Dos estilos de comando conviviendo sin criterio**: unos comandos modelaban la intencion del usuario como un sub-recurso nuevo bajo POST (`Colaboradores/Terminaciones`, `Colaboradores/Terminaciones/Anulaciones`) -- un "buzon de hechos" donde cada intencion crea una fila nueva --, otros modelaban el mismo tipo de intencion como reemplazo de un recurso existente. La intencion real del comando (¿crea algo nuevo? ¿reemplaza un valor? ¿ejecuta una accion de negocio sobre algo que ya existe?) quedaba invisible en la URL, y la eleccion de estilo se justificaba por precedente interno ("asi lo hicimos en el ultimo dominio"), nunca por una regla escrita.
- **Un create disfrazado**: `ReingresarColaborador` (`POST Colaboradores/Reingresos`) emitia el **mismo evento** que el registro inicial (`VinculacionIniciada`) -- el nombre del comando y su ruta sugerian una operacion distinta de "crear", pero la historia del stream (los eventos que en realidad emite) decia que era exactamente el mismo create, ejecutado una segunda vez sobre el mismo colaborador.

**Colision doctrinal vigente con MEF-ADR-0006**: el ejemplo canonico que ese ADR usa para toda su seccion "Ruta HTTP" es `Route = "Programacion/Turnos"` -- PascalCase --, incompatible con el kebab-case minusculo que exige la doctrina destilada en este ADR. Cualquier consumidor que copie ese ejemplo hereda el casing equivocado.

Este ADR es el **techo doctrinal** de un paquete de cuatro issues: escribe la doctrina nueva y enmienda los dos ADRs afectados por la colision y por el nuevo campo del DoR. La propagacion a los agentes que generan codigo o issues va en issues aparte, que este ADR bloquea: #622 (`agents/implementer.md` + `skills/projections/naming.md`), #623 (`agents/planner.md`), #624 (`agents/reviewer.md`).

### Que queda fuera de este ADR

- **Queries (GET/QUERY)**: sin cambio. MEF-ADR-0042 ya fija su frontera de metodo, paginacion y filtros; este ADR cubre exclusivamente comandos.
- **Migracion de endpoints ya desplegados**: ver seccion "Aplicabilidad" abajo.
- **Enmienda formal a MEF-ADR-0032 o al `apim-gateway-scaffolder`**: este ADR anota la consecuencia en el borde APIM (seccion "Consecuencias"), pero la enmienda concreta -- si al escribirla se revela trabajo real -- se hace en un issue propio.

## Decision

### 1. Precondicion global: ids URL-safe, `:` reservado para acciones (CA-1)

Todo id que viaje como segmento de ruta debe ser **URL-safe**. En particular, el caracter `:` queda **reservado** para designar una accion de negocio (seccion 2, paso 4) y nunca debe aparecer como parte de un id. Verificado contra las Microsoft Azure REST API Guidelines: *"DO restrict the characters in service-defined path segments to `0-9 A-Z a-z - . _ ~`, with `:` allowed only to designate an action operation"*, y explicitamente *"Avoid the use of the `:` character within resource ids"* [1].

#### 1.1 Charset canonico: el conjunto *unreserved* de RFC 3986

El conjunto de caracteres permitido en un id de ruta es el *unreserved* que fija la fuente primaria de la cita anterior, RFC 3986 §2.3: *"Characters that are allowed in a URI but do not have a reserved purpose are called unreserved... These include uppercase and lowercase letters, decimal digits, hyphen, period, underscore, and tilde"*, con la gramatica `unreserved = ALPHA / DIGIT / "-" / "." / "_" / "~"` [7] -- exactamente el mismo conjunto `0-9 A-Z a-z - . _ ~` que citan las Azure REST API Guidelines [1], ahora con su fuente de sintaxis URI declarada de forma explicita en vez de solo heredada por cita de proveedor.

`:` queda fuera del charset por partida doble: no pertenece al conjunto *unreserved* (RFC 3986 lo clasifica como *reserved*, categoria *gen-delims* -- seccion 2.2 [7]) y, aunque perteneciera, el marco ya lo reserva en exclusiva como separador de accion (seccion 2, paso 4). Dos razones independientes que apuntan a la misma proscripcion: una de sintaxis URI, otra de convencion propia del marco.

La relacion de este charset con la identidad de stream que norma MEF-ADR-0037 es por alcances, no uniforme entre sus formas: (a) el Guid canonico "D" en minusculas (MEF-ADR-0037 seccion 1) cumple este charset **por construccion** -- el formato fijo de `Guid.ToString()` nunca produce `:` ni ningun caracter fuera del conjunto *unreserved*; (b) la forma string de una identidad de **un** componente tipado no-Guid (un VO unico -- MEF-ADR-0037 seccion 2, enmendada) **si viaja** como segmento de ruta, y su URL-safety **no es automatica**: la fija el `ToString()` propio de ese tipo, sujeta al criterio rechazar-vs-normalizar de 1.2 y al momento de la invariante de 1.3; (c) la clave natural **compuesta** que reconstruye `ComputarStreamId` (MEF-ADR-0037 seccion 1) queda **fuera del sujeto de este charset**: nunca viaja entera en un segmento de ruta -- cada componente tipado viaja en su propio segmento y el servidor reconstruye la clave, como fija MEF-ADR-0037 seccion 2 enmendada --, asi que su separador (`:` en el ejemplo canonico `$"{empleadoId}:{fecha:yyyy-MM-dd}"` de la seccion 1 de ese ADR) es interno a ese punto unico de conversion y jamas se encuentra con una URL.

#### 1.2 Criterio rechazar-vs-normalizar segun quien es dueno del dato

La precondicion de 1.1 cubre el caso feliz: el dato de negocio que se promueve a segmento de ruta ya nace URL-safe. Cuando no nace URL-safe, el marco fija el criterio que decide entre normalizar y rechazar -- y la decision depende de **quien es dueno de la forma canonica del dato**, nunca de la comodidad del endpoint que lo recibe:

- **Identidad que el dominio normaliza para unificar**: el dato es una identidad de negocio sobre la que el propio dominio ya define una forma canonica -- unificar variantes superficiales es precisamente lo que le da sentido a esa identidad (dos formas distintas deben resolver al mismo stream). Ejemplo: un numero de identificacion donde `" ab-12.3 "` y `"AB123"` deben producir el mismo stream. El dominio es dueno de esa forma canonica -- se **normaliza sin rechazo**, en el punto unico de conversion que ya fija MEF-ADR-0037 seccion 1. Es exactamente el caso al que apunta la regla unica de MEF-ADR-0037 seccion 2 (*"normalizar, no rechazar"*): una variante de formato que el parseo tipado admite nunca se responde con `400`.
- **Identificador asignado por un tercero**: el dato lo asigna una parte externa al dominio (p. ej. un codigo de colaborador que asigna la empresa cliente que lo emplea) -- el dominio no tiene autoridad para redefinir su forma. Alterarlo en silencio (recortar espacios, cambiar mayusculas, sustituir caracteres) cambiaria un dato ajeno sin que ese tercero lo sepa ni lo consienta. Se **rechaza con `400`** cuando trae caracteres fuera del charset de 1.1 -- lo unico que el marco exige es que el dato quepa en una URL, nunca que el dominio le imponga una forma que no le pertenece. Ese `400` no es una excepcion a la regla unica de MEF-ADR-0037 seccion 2 sino su aplicacion directa: la URL-safety es invariante del tipo que representa ese codigo (1.3), asi que un valor fuera del charset **no parsea** como el tipo declarado -- y para texto que no parsea, el `400` es lo que ese ADR ya fija.

La pregunta decidible para elegir entre los dos casos es "¿quien define la forma canonica de este dato -- el dominio, o un tercero externo?", nunca "¿cual de los dos es mas facil de implementar en este endpoint?".

#### 1.3 Momento de la invariante: issue previo dedicado

La URL-safety de un dato de negocio se gana como invariante del dominio **en un issue previo dedicado**, nunca dentro del mismo issue/PR que promueve ese dato a segmento de ruta de un comando. Esto es doctrina de **planeacion**: es el planner quien aplica esta secuencia al desglosar el trabajo -- fijar la invariante URL-safe (normalizacion o validacion, segun 1.2) antes de aceptar un issue que expone el dato en una ruta, nunca como hallazgo bloqueante descubierto a mitad del mismo PR que ya la esta usando como segmento. La operacionalizacion concreta en el checklist del planner es alcance de un issue dependiente de este ADR, no de este ADR.

#### 1.4 Mecanismo: sin cambios sobre MEF-ADR-0037

Esta seccion fija **que** charset aplica (1.1), **cuando** un dato exige normalizacion o rechazo (1.2) y **en que momento del ciclo de un issue** se gana esa invariante (1.3) -- nunca **como** se ejecuta la normalizacion o el rechazo en tiempo de ejecucion. Ese mecanismo sigue viviendo integramente en MEF-ADR-0037: el borde HTTP hace un unico parseo tipado del segmento de ruta con `400` explicito si no parsea (seccion 2 de ese ADR), y la unica salida a string es la del punto unico de conversion (seccion 1). La normalizacion de 1.2 (caso "identidad que el dominio unifica") *es* esa pareja parseo tipado + punto unico de conversion, no un paso adicional; el rechazo de 1.2 (caso "identificador de tercero") *es* el mismo `400` que MEF-ADR-0037 ya fija para texto que no parsea como el tipo declarado, sin excepcion nueva.

En particular, la **regla unica** de MEF-ADR-0037 seccion 2 -- *"normalizar, no rechazar"*, que proscribe el `400` para una variante de formato que si parsea -- **queda intacta**: 1.3 exige que la URL-safety ya sea invariante del tipo antes de que el dato viaje en un segmento de ruta, asi que un valor fuera del charset de 1.1 no llega a ser "una variante de formato que parsea" -- simplemente no parsea. Este ADR **no reabre** el parseo tipado ni el punto unico de conversion de MEF-ADR-0037 -- solo agrega la precondicion URL-safe y el criterio de cuando normalizar vs. rechazar.

### 2. Test de precedencia por comando (CA-1)

Todo comando nuevo evalua las siguientes preguntas **en orden**; la primera que responde afirmativamente fija el metodo y la forma de la ruta. El test es secuencial y excluyente: un comando que responde "si" a la pregunta 2 nunca llega a evaluar la 3.

#### Paso 1: ¿El comando crea algo que el dominio modela como entidad, aunque el nombre lo disimule?

**-> `POST` a la coleccion** (create canonico): `POST {coleccion}`. RFC 9110 §9.3.3 fija a POST como el metodo para *"request that the target resource process the representation enclosed in the request"*, con la creacion de un recurso subordinado a la coleccion como uno de sus usos comunes [2] -- el caso canonico de este paso.

El criterio decidible no es el nombre del comando ni la intencion superficial del usuario -- es **que eventos emite realmente**, verificado contra la historia del stream. Caso probado: `ReingresarColaborador` sugiere una operacion distinta de "crear", pero emite el mismo evento que `RegistrarColaborador` (`VinculacionIniciada`) -- es un create disfrazado. La ruta correcta no reifica el nombre del comando como si fuera un sub-recurso propio (`POST Colaboradores/Reingresos`); reifica la entidad que el evento realmente instancia: `POST colaboradores/{id}/vinculaciones`.

**Principio**: el cliente HTTP no declara lo que el servidor deriva de la historia del stream. Si dos comandos distintos emiten el mismo evento sobre el mismo tipo de entidad, son el mismo create visto desde dos intenciones de negocio -- y comparten la misma ruta POST.

#### Paso 2: ¿El comando reemplaza completo un value object atomico direccionable?

**-> `PUT {recurso}/{sub-recurso}`**.

La granularidad de los recursos REST la dictan los **value objects del dominio**, nunca la imaginacion de quien diseña la API. Si el dominio modela `NombreColaborador` como VO atomico, el comando que lo reemplaza completo es `PUT colaboradores/{id}/nombres`. Si modela `Etiqueta` como VO direccionable por categoria, el comando que la reemplaza es `PUT colaboradores/{id}/etiquetas/{categoria}`.

RFC 9110 §9.3.4 sanciona expresamente el rechazo cuando el recurso tiene restricciones que el reemplazo propuesto viola: un PUT puede responder `409 Conflict` sin que eso sea una desviacion del metodo [3] -- compatible con "declinar con resultado" (MEF-ADR-0004): el aggregate sigue emitiendo su evento de fallo, y el endpoint traduce ese fallo a `409` igual que ya traduce el fallo de "crear sobre un stream que ya existe".

**Verificacion de decidibilidad**: la pregunta es "¿existe en el dominio un VO cuyo reemplazo completo es exactamente lo que este comando hace?" -- si el dominio no modela ese VO como unidad atomica direccionable, el comando no califica para PUT y sigue al paso 3.

#### Paso 3: ¿El comando remueve verazmente un sub-recurso direccionable, sin payload?

**-> `DELETE {recurso}/{sub-recurso}`**.

Dos condiciones, ambas necesarias:

- **Veraz**: el sub-recurso deja de existir en el estado vigente tras el comando. `RetirarEtiqueta` califica -- la etiqueta deja de ser legible en el estado vigente del colaborador. `TerminarVinculacion` **no** califica aunque el nombre sugiera un "remove": la vinculacion sigue siendo legible (hay reingreso posible, la terminacion es un hecho mas en la historia, no una desaparicion).
- **Sin payload**: RFC 9110 §9.3.5 fija que una request DELETE no debe llevar body con semantica -- *"a client SHOULD NOT generate content in a DELETE request"* [4]. Si el comando necesita datos ademas del id de ruta (una fecha del hecho, por el principio bitemporal que ya rige el marco), DELETE queda descartado aunque la operacion sea semanticamente un remove.

Si cualquiera de las dos condiciones falla, el comando sigue al paso 4.

#### Paso 4: todo lo demas -- accion con verbo propio del negocio

**-> `POST {recurso}:{verbo}`**.

Este es el caso general, no la excepcion: la mayoria de los comandos de un dominio rico son acciones de negocio que ni crean una entidad nueva, ni reemplazan un VO completo, ni remueven veraz y sin payload un sub-recurso. Ejemplos del catalogo evaluado: `TerminarVinculacion` -> `POST colaboradores/{id}/vinculaciones/{codigo}:terminar`; `AnularTerminacion` -> `POST .../vinculaciones/{codigo}:anular-terminacion`; `CorregirFechaInicioVinculacion` -> `POST .../vinculaciones/{codigo}:corregir-fecha-inicio`.

El patron `{recurso}:{verbo}` viene de la escuela de "custom methods" documentada por dos guias independientes que llegan a la misma forma:

- **Google AIP-136**: *"If a resource-oriented design (standard methods) does not fit your use case, you can also use custom methods... a custom method... uses a colon to distinguish the custom method from a call for a standard method"* -- ejemplo canonico `POST /publishers/{publisher}/books/{book}:archive` [5].
- **Microsoft Azure REST API Guidelines**: acciones se exponen con `POST` sobre `{recurso}:{accion}` -- el mismo separador `:` que la seccion 1 ya reserva para este uso exclusivo [1].

**Derivacion mecanica del nombre**: el verbo de la ruta es el verbo infinitivo del nombre del comando, en kebab-case (seccion 3) -- `TerminarVinculacion` -> `:terminar`, `AnularTerminacion` -> `:anular-terminacion`. No hay creatividad por issue: el nombre del comando ya fija el verbo, la conversion es mecanica.

**Simetria CQRS deliberada** (seccion 4): la API habla en imperativo (`:terminar`, un comando es una intencion que todavia puede fallar) mientras el event store habla en pasado (`VinculacionTerminada`, un evento es un hecho consumado). El marco **desobedece a sabiendas** la guia de Zalando *"MUST keep URLs verb-free"* [6] -- ver "Alternativas consideradas" para el razonamiento completo de por que esta desviacion es deliberada, no un descuido.

#### Paso 5 (proscripcion transversal): PATCH queda descartado

**PATCH no es una quinta rama del test -- es una proscripcion que corre en paralelo a los pasos 1-4.** Ningun comando del marco se expone como PATCH mientras los comandos operen sobre VOs atomicos (la unidad de reemplazo que ya fija el paso 2). Razones:

- RFC 5789 declara PATCH *"neither safe nor idempotent"* por diseño -- el marco ya exige que sus recursos tengan una semantica de metodo clara, y PATCH la vuelve dependiente del contenido del body, no del metodo en si.
- **JSON Merge Patch (RFC 7386)** tiene una trampa estructural con valores nulos: *"If the provided merge patch contains members that do not appear within the target, those members are added... any member in the target that has a corresponding member with a null value in the provided patch is deleted"* -- un cliente que quiere "no tocar este campo" y uno que quiere "borrar este campo" no se pueden distinguir sin una convencion adicional fuera del estandar.
- **Embudo de intenciones**: un unico `PATCH {recurso}` que acepte cualquier subconjunto de campos colapsa comandos de negocio distintos (cada uno una intencion propia, cada uno con sus propias reglas de validacion) en una sola Function distinguible solo por el body -- rompe el invariante "una Function por comando" que MEF-ADR-0006 ya fija para toda operacion de escritura del marco.

### 3. Casing: kebab-case minusculo en todos los segmentos (CA-1)

Todo segmento de una ruta HTTP de comando -- coleccion, sub-recurso, y el verbo de un `{recurso}:{verbo}` -- se escribe en **kebab-case minusculo**: `colaboradores`, `vinculaciones`, `etiquetas/{categoria}`, `:corregir-fecha-inicio`. Nunca PascalCase (`Colaboradores/Etiquetas`), nunca camelCase, nunca mezclado entre segmentos del mismo path.

Esta regla de casing rige por igual **comandos y queries**, y hasta ahora ningun ADR la habia declarado -- de ahi el drift. Al escribirse este ADR, el ejemplo canonico del marco estaba en PascalCase en cuatro sitios: MEF-ADR-0006 (que **este ADR enmienda**, seccion 5 abajo, eliminando la colision doctrinal directa) y tres artefactos que lo replican y que **este ADR no toca** -- `agents/implementer.md` (`Route = "Programacion/Turnos"` del endpoint de comando), `skills/projections/naming.md` y `skills/projections/read-apis.md` (sus ejemplos de query). Alinearlos al casing que fija esta seccion es alcance del issue #622, no de este ADR: hasta que ese issue cierre, quien copie un ejemplo de esos tres archivos hereda el casing viejo y debe corregirlo contra esta seccion.

### 4. Simetria CQRS: API en imperativo, event store en pasado (CA-1)

El marco fija, como principio explicito y no solo como consecuencia incidental de nombrar comandos con verbo infinitivo: **la superficie HTTP habla en imperativo** (un comando es una intencion, todavia sujeta a las reglas de negocio del aggregate -- puede declinarse, MEF-ADR-0004) **mientras el event store habla en pasado** (un evento es un hecho ya consumado, irreversible). `POST .../vinculaciones/{codigo}:terminar` (imperativo, puede responder `409` o un evento de fallo) produce `VinculacionTerminada` (pasado, hecho consumado) cuando el aggregate acepta la intencion.

Esta simetria es la razon de fondo por la que este ADR se aparta de Zalando en el paso 4: fuentes de doctrina de comandos coinciden en que la superficie de comandos existe precisamente para expresar intenciones con verbo propio del negocio, distintas de los hechos que produce:

- Greg Young (CQRS Documents / Task-Based UI): al forzar toda escritura a un CRUD generico *"the intent of the user was lost... the domain was unable to have any verbs in it"* -- la perdida de verbo de negocio en la superficie de escritura es exactamente el sintoma que este ADR evita en el paso 4.
- Oskar Dudycz (event-driven.io): *"the command represents the intention"*, y los clientes *"typically send commands via REST API, events via queues"* -- los eventos nunca se postean por un cliente HTTP; incluso la API de append de streams de una base de datos de event sourcing (ej. KurrentDB, `POST /streams/{stream}`) es infraestructura de la base de datos, no una API de negocio del dominio.
- Roy Fielding ("It is okay to use POST", 2009): *"We don't need to use PUT for every state change... POST serves the general purpose of 'this action isn't worth standardizing'"* -- respalda que forzar PUT/DELETE sobre acciones que no son reemplazo/remocion real (los pasos 2-3) seria peor que declarar honestamente un `POST {recurso}:{verbo}` (paso 4).

### 5. Enmienda a MEF-ADR-0006: casing y referencia cruzada

MEF-ADR-0006 se enmienda (control de cambios de ese ADR) en dos puntos: (a) su ejemplo canonico de `Route` pasa de PascalCase (`Programacion/Turnos`) a kebab-case minusculo (`programacion/turnos`), eliminando la colision doctrinal que motivo este ADR; (b) su seccion "Ruta HTTP" remite a este ADR para el verbo HTTP y la forma de ruta de un comando -- MEF-ADR-0006 sigue fijando el **nombre** de la Function (verbo infinitivo + sustantivo) y la organizacion vertical de directorios, pero deja de ser la fuente de la forma de ruta de un comando: esa doctrina vive aqui.

### 6. Enmienda a MEF-ADR-0011: contrato HTTP en el Definition of Ready

MEF-ADR-0011 se enmienda (control de cambios de ese ADR) para exigir, en todo issue que introduzca o modifique un endpoint HTTP de comando, el **contrato HTTP** de ese comando -- verbo, ruta y el paso del test de precedencia (seccion 2 de este ADR) que se aplico -- como campo **Critico** para llegar a `estado:listo`. La seccion "Validacion en `/implement`" de ese ADR incorpora el criterio programatico correspondiente.

Esa validacion vive dentro del propio MEF-ADR-0011 y `commands/implement.md` la delega leyendo el ADR en runtime, asi que la enmienda **se autopropaga al gate sin duplicar la doctrina en el skill** (mismo mecanismo que ya usan las enmiendas de `tipo:projection`). La autopropagacion no era gratis, sin embargo: el skill enumeraba "los 5 criterios del MEF-ADR-0011" -- una cantidad fija memorizada fuera del ADR, que habria dejado el criterio 6 fuera del gate en silencio. El issue #621 corrigio ese conteo a "todos los criterios que enumere esa seccion", que es lo que hace real el mecanismo de delegacion para esta enmienda y para cualquier futura.

### 7. Aplicabilidad: solo endpoints nuevos (CA-2)

Esta doctrina rige **todo endpoint de comando que nazca a partir de este ADR**. Los endpoints preexistentes no conformes -- casing PascalCase, comandos POST que en realidad reemplazan o remueven, acciones de negocio expuestas sin el separador `:` -- **no generan hallazgo bloqueante ni migracion forzada**: pueden tener consumidores externos ya integrados contra la URL vieja, y un rename de endpoint HTTP es un breaking change para quien sea que lo consuma.

Sugerir el rename de un endpoint viejo hacia la forma conforme es **legitimo**, pero:

- Siempre **precavido**: nunca se aplica de forma automatica ni se trata como un hallazgo de reviewer que bloquee un PR no relacionado.
- Siempre **discutido con el humano**: la migracion de un endpoint en produccion es decision y calendario del equipo que opera el consumidor, no del agente que detecta la no conformidad.

### 8. NO VERIFICADO: `:` pegado a un parametro de ruta en Azure Functions worker aislado

El literal `:` de un comando de accion (`{codigo}:terminar`) forma, junto con el parametro que lo precede, un **complex segment** de ASP.NET Core -- un segmento de ruta con mas de un valor literal/parametro combinados (`{codigo}:terminar` es, para el enrutador, un solo segmento que combina el parametro `{codigo}` con el literal `:terminar`). Que Azure Functions (worker aislado, `HttpTriggerAttribute.Route`) soporte esta forma de complex segment sin configuracion adicional **no esta verificado** contra la documentacion oficial ni contra un POC propio del marco -- a diferencia de MEF-ADR-0042 (que si corrio POCs propios para el verbo QUERY antes de aceptar la doctrina), este ADR no corrio un POC equivalente para el complex segment `:verbo`.

**Regla operativa**: mismo patron que MEF-ADR-0042 seccion 6 y `skills/projections/naming.md` ya aplican para sus propios puntos no verificados -- este punto se trata como **gate empirico obligatorio** en el primer endpoint real que use la forma `{parametro}:verbo`. El agente o desarrollador que lo implemente debe correr el endpoint contra el host local de Azure Functions (Core Tools) y confirmar que el enrutamiento distingue correctamente `{codigo}:terminar` de `{codigo}:anular-terminacion` sobre el mismo segmento base, antes de asumir que arranca en un entorno real. Si el host no soporta la forma sin configuracion adicional, la alternativa sin gate es mover el verbo a un segmento propio (`{recurso}/{codigo}/terminar`, sin `:`) -- Microsoft Azure REST API Guidelines no exige el separador `:`, solo lo permite [1]; Google AIP-136 si lo fija como parte de su convencion [5], pero el marco no adopta AIP-136 al pie de la letra, solo su principio de custom methods.

## Alternativas consideradas

### Alt 1: POST para todo comando, sin distinguir PUT/DELETE/accion

Seguir la practica implicita previa del marco: todo comando es `POST`, sin test de precedencia.

**Descartada**: es la practica que produjo el drift documentado en "Contexto" -- sin un criterio decidible, cada dominio (y cada desarrollador dentro del mismo dominio) resuelve el estilo por precedente interno, nunca por regla escrita. Roy Fielding respalda que POST es aceptable para "esto no vale la pena estandarizar" [ver seccion 4], pero eso no es excusa para renunciar a PUT/DELETE en los casos donde si hay una operacion estandarizable (reemplazo completo de un VO, remocion veraz sin payload) -- ahi la semantica de metodo estandar (idempotencia de PUT, "sin contenido" de DELETE) es informacion util para cualquier cliente HTTP generico, que un POST uniforme esconde.

### Alt 2: PATCH para actualizaciones parciales de un VO

Adoptar PATCH (JSON Patch o JSON Merge Patch) para los casos donde solo cambia un subconjunto de campos de un recurso, en vez de forzar PUT con el VO completo.

**Descartada** (paso 5 de la seccion 2): mientras los comandos del marco operen sobre VOs atomicos (la granularidad que el paso 2 ya fija), PATCH no tiene nada que ofrecer que PUT no cubra ya -- el VO completo es la unidad de reemplazo, no hay "campos sueltos" del VO que editar independientemente sin romper su propia invariante de value object. Ademas la trampa de RFC 7386 (null borra el campo) y el embudo de intenciones (un solo endpoint colapsando varios comandos de negocio distintos) son riesgos reales que el marco no necesita asumir cuando el paso 4 (`POST {recurso}:{verbo}`) ya cubre cualquier accion que no sea reemplazo completo.

### Alt 3: seguir la guia de Zalando al pie de la letra -- URLs sin verbos, todo recurso

Zalando: *"MUST avoid actions -- think about resources"* [6], preferir siempre remodelar una accion como recurso (su ejemplo es transformar un "cancel" en una entidad `cancellation` creada por POST -- el patron "letter box").

**Descartada a sabiendas**: el patron "letter box" (reificar cada accion como una entidad de buzon, `POST Colaboradores/Terminaciones`) es exactamente el "buzon de hechos" que el issue #621 identifico como uno de los dos estilos en competencia sin criterio en el consumidor, y es indistinguible en la URL de un create genuino -- el mismo problema del paso 1 (¿esto es un create o no?), pero ahora aplicado a *toda* accion de negocio, no solo a las que de verdad crean algo. El marco prefiere declarar honestamente que la accion es una accion (paso 4, `:verbo`) en vez de disfrazarla de recurso creado -- alineado con Google AIP-136 y Microsoft Azure REST API Guidelines, que abordan el mismo problema con la misma solucion (custom methods vs. letter box) de forma independiente entre si.

### Alt 4: introducir un "estilo canonico" propio del marco, distinto de `:verbo`, para las acciones de negocio

Inventar una convencion propia -- por ejemplo, un sub-recurso `/acciones/{nombreAccion}` en vez del separador `:`.

**Descartada**: duplicaria una convencion que dos guias de proveedores mayores (Google, Microsoft) ya resuelven de forma consistente entre si, sin ninguna ventaja concreta para el marco. Adoptar `:verbo` da interoperabilidad con herramientas y expectativas que ya reconocen ese patron (documentacion OpenAPI, clientes que siguen las mismas guias), en vez de un formato de solo este marco que cualquier consumidor tendria que aprender desde cero.

## Consecuencias

### Positivas

- **Criterio decidible, no precedente**: dos desarrolladores distintos, dado el mismo comando nuevo, llegan al mismo metodo y a la misma forma de ruta -- elimina la fuente del drift documentado en "Contexto".
- **La URL deja de mentir sobre la intencion del comando**: un create disfrazado (`ReingresarColaborador`) se expone con la ruta que refleja lo que el stream realmente hace (paso 1), no el nombre superficial del comando.
- **Simetria CQRS explicita**: la API en imperativo y el event store en pasado dejan de ser una convencion tacita -- quedan citadas con las mismas fuentes de doctrina de comandos que el marco ya sigue implicitamente (Greg Young, Oskar Dudycz).
- **PUT/DELETE dejan de ser un caso especial no documentado**: el marco ya tenia `POST 202 Accepted` como respuesta estandar de comando (MEF-ADR-0004); esta doctrina no lo cambia, solo agrega el `409` de PUT como una instancia mas de "declinar con resultado", sin necesitar una excepcion nueva.
- **Migracion nunca forzada**: la regla de aplicabilidad (seccion 7) protege a los endpoints preexistentes de un rename automatico que romperia consumidores integrados.

### Negativas

- **Costo de aprendizaje del test de precedencia**: a diferencia de "todo es POST", el paso 1-5 exige que quien escribe el issue (planner) o el codigo (implementer) evalue explicitamente que eventos emite el comando antes de fijar la ruta -- mas trabajo de analisis por comando que la practica previa.
- **`{parametro}:verbo` no esta verificado en el host real** (seccion 8): el primer dominio que use esta forma paga el costo de un gate empirico que las formas mas simples (POST a coleccion, PUT, DELETE sin complex segment) no necesitan.
- **Divergencia visible entre endpoints viejos y nuevos**: mientras un consumidor no decida migrar sus endpoints preexistentes, convive PascalCase (legado) con kebab-case (nuevo) en el mismo Function App -- costo aceptado explicitamente por la regla de aplicabilidad de la seccion 7.
- **Consecuencia pendiente en el borde APIM**: ver nota abajo.

### Consecuencia a verificar en el borde APIM (MEF-ADR-0032)

MEF-ADR-0032 fija que `<allowed-methods>` se enumera explicitamente (nunca `*`, trampa B3) y que APIM no expone ninguna operacion sin declararla -- de ahi las operaciones wildcard por verbo del modulo `apim-function-api` (trampa B11). Ambas superficies hoy solo cubren `GET`/`POST`/`QUERY`. Un Bounded Context que adopte `PUT`/`DELETE` para sus comandos (pasos 2-3 de este ADR), o que exponga rutas `{recurso}:{verbo}`, necesita que el gateway los cubra: `PUT`/`DELETE` sumados a `<allowed-methods>` (B3) y a la lista de operaciones wildcard (B11) -- el `:verbo` en si no es un metodo HTTP nuevo (sigue siendo `POST`), asi que no exige un verbo wildcard adicional, solo pasa por la misma operacion `POST /*` ya existente. **Esta consecuencia queda anotada, no resuelta**: una enmienda formal a MEF-ADR-0032 o al `apim-gateway-scaffolder` para sumar `PUT`/`DELETE` a ambas listas se difiere a un issue propio, a abrir cuando un Bounded Context real adopte alguno de los dos metodos (mismo criterio de Rule of Three que ya aplica MEF-ADR-0018 -- no se sobre-generaliza sin evidencia de necesidad real).

## Referencias

- **[1]** Microsoft Azure REST API Guidelines -- seccion de convenciones de resource ID: *"DO restrict the characters in service-defined path segments to `0-9 A-Z a-z - . _ ~`, with `:` allowed only to designate an action operation"*; *"Avoid the use of the `:` character within resource ids"*. Custom actions expuestas como `POST` sobre `{recurso}:{accion}`. https://github.com/microsoft/api-guidelines/blob/vNext/azure/Guidelines.md
- **[2]** RFC 9110, "HTTP Semantics" -- IETF, §9.3.3 (POST): *"The POST method requests that the target resource process the representation enclosed in the request according to the resource's own specific semantics"*, con la creacion de un recurso subordinado a la coleccion como uno de sus usos comunes documentados. https://www.rfc-editor.org/rfc/rfc9110.html#section-9.3.3
- **[3]** RFC 9110, "HTTP Semantics" -- IETF, §9.3.4 (PUT): el metodo puede rechazar la request con un codigo de error apropiado (incluyendo `409 Conflict`) cuando el recurso destino tiene restricciones que el reemplazo propuesto no puede satisfacer. https://www.rfc-editor.org/rfc/rfc9110.html#section-9.3.4
- **[4]** RFC 9110, "HTTP Semantics" -- IETF, §9.3.5 (DELETE): *"A client SHOULD NOT generate content in a DELETE request unless the content is a representation of the target resource intended to trigger something beyond deletion"* -- fundamento de por que un remove con payload (dato adicional, p. ej. una fecha del hecho) no califica para DELETE en el paso 3 del test de precedencia. https://www.rfc-editor.org/rfc/rfc9110.html#section-9.3.5
- **[5]** Google AIP-136, "Custom methods": *"If a resource-oriented design (standard methods) does not fit your use case, you can also use custom methods... a custom method uses a colon to distinguish the custom method from a call for a standard method"*; recomienda `POST` para custom methods con side effects y advierte *"prefer standard methods if possible, and only introduce additional custom methods if they can't be avoided"*. https://google.aip.dev/136
- **[6]** Zalando RESTful API and Event Guidelines: *"MUST avoid actions -- think about resources"* (patron "letter box" para acciones como `cancellation`), *"MUST use HTTP methods correctly"*, y su guia de PATCH (JSON Merge Patch/JSON Patch) -- fuente de la Alt 3 (descartada a sabiendas) y de referencia para la proscripcion de PATCH (paso 5). https://opensource.zalando.com/restful-api-guidelines/
- RFC 5789, "PATCH Method for HTTP" -- IETF: *"PATCH is neither safe nor idempotent"* -- fundamento del paso 5. https://www.rfc-editor.org/rfc/rfc5789.html
- RFC 7386, "JSON Merge Patch" -- IETF: semantica de fusion donde un valor `null` en el patch borra el miembro correspondiente del target -- fuente de la "trampa del null" que cita el paso 5. https://www.rfc-editor.org/rfc/rfc7386.html
- **[7]** RFC 3986, "Uniform Resource Identifier (URI): Generic Syntax" -- IETF, §2.3 (Unreserved Characters): *"Characters that are allowed in a URI but do not have a reserved purpose are called unreserved... These include uppercase and lowercase letters, decimal digits, hyphen, period, underscore, and tilde"*, con la gramatica `unreserved = ALPHA / DIGIT / "-" / "." / "_" / "~"` -- fuente primaria del charset canonico que fija la seccion 1.1 de este ADR, coherente con las Azure REST API Guidelines ya citadas en [1]. La misma seccion 2.2 (Reserved Characters) clasifica `:` como *gen-delims* -- fuera del conjunto *unreserved* por definicion propia del RFC, razon independiente de la reserva del marco para separador de accion (seccion 2, paso 4); el caracter sigue siendo legal dentro de la gramatica general de un segmento de path/query, asi que la proscripcion de `:` en ids no es una restriccion de sintaxis URI sino una convencion adicional (guias de proveedor Microsoft/Google + reserva propia del marco). https://www.rfc-editor.org/rfc/rfc3986.html#section-2.3
- Roy Fielding, "It is okay to use POST" (roy.gbiv.com/untangled, diciembre 2009): *"We don't need to use PUT for every state change... POST serves the general purpose of 'this action isn't worth standardizing'"*. https://roy.gbiv.com/untangled/2009/it-is-okay-to-use-post
- Greg Young, "CQRS Documents" / charlas sobre Task-Based UI: *"the intent of the user was lost... the domain was unable to have any verbs in it"* cuando toda escritura se fuerza a un CRUD generico -- fundamento de la simetria CQRS (seccion 4).
- Oskar Dudycz (event-driven.io): *"the command represents the intention... we typically send commands via REST API, events via queues"* -- los clientes HTTP publican comandos, nunca eventos; la API de append de streams de una base de datos de event sourcing es infraestructura, no una API de negocio del dominio.
- ThoughtWorks Technology Radar, tecnica "REST without PUT" (noviembre 2015): referenciada como antecedente de la industria que cuestiona el uso obligatorio de PUT/DELETE para toda mutacion; texto completo no extraible sin JavaScript al momento de esta investigacion (2026-08-12/13), citada por titulo y fecha, no verificada palabra por palabra.
- MEF-ADR-0004 (manejo de errores en event sourcing): el `409` de PUT (seccion 2, paso 2) es una instancia mas de "declinar con resultado" -- el aggregate emite su evento de fallo, el endpoint lo traduce al codigo HTTP correspondiente, sin excepcion nueva a esa doctrina.
- MEF-ADR-0006 (convenciones de nombramiento de Functions Azure): **enmendado por este ADR** -- casing kebab-case del ejemplo canonico de `Route` y referencia cruzada de la seccion "Ruta HTTP" a este ADR para el verbo/forma de ruta de comandos (seccion 5).
- MEF-ADR-0011 (Definition of Ready): **enmendado por este ADR** -- el contrato HTTP (verbo + ruta + precedencia aplicada) entra como campo Critico para issues con comando de trigger HTTP (seccion 6).
- MEF-ADR-0018 (heuristicas de evolucion y reuso, Rule of Three): fundamenta que la enmienda a MEF-ADR-0032 se defiere a un issue propio en vez de anticiparse sin un caso real de PUT/DELETE.
- MEF-ADR-0030 (esquema de identificacion de ADRs): fija el numero `MEF-ADR-0043`.
- MEF-ADR-0032 (identidad y autenticacion en el borde, WorkOS + APIM): destinatario de la consecuencia anotada (no resuelta) sobre `<allowed-methods>` (B3) y operaciones wildcard (B11) cuando un BC adopte PUT/DELETE.
- MEF-ADR-0037 (identidad del stream y su representacion string canonica): el id de ruta de un comando sigue el mismo parseo tipado que ya fija ese ADR; este ADR solo agrega la precondicion URL-safe -- charset RFC 3986 §2.3 y el criterio rechazar-vs-normalizar por propiedad del dato (seccion 1) --, sin reabrir el parseo tipado del borde HTTP (seccion 2 de ese ADR, cuya regla unica *"normalizar, no rechazar"* queda intacta) ni el punto unico de conversion (seccion 1 de ese ADR). La seccion 1.4 de este ADR nombra donde se ejecutan ambos, sin duplicar su mecanica.
- MEF-ADR-0042 (doctrina GET/QUERY, paginacion y filtros): frontera explicita -- ese ADR cubre queries, este ADR cubre comandos; ninguno reabre al otro. Fuente del patron "catalogo NO VERIFICADO + gate empirico obligatorio" que la seccion 8 de este ADR replica.
- Issue #621 (este ADR, cabeza del paquete); issue #622 (propagacion a `agents/implementer.md` + `skills/projections/naming.md`); issue #623 (propagacion a `agents/planner.md`); issue #624 (propagacion a `agents/reviewer.md`); issue #631 (enmienda de la seccion 1 con la politica de aceptacion de ids/codigos de negocio destinados a segmentos de URI -- charset RFC 3986, criterio rechazar-vs-normalizar, momento de la invariante -- descubierta por Bitakora.ControlAsistencia en sus issues #381 y #387).

## Control de cambios

- 2026-08-14: creacion como `aceptado` (issue #621). Fija la precondicion de ids URL-safe con `:` reservado a acciones, el test de precedencia de cinco pasos para comandos (create disfrazado -> POST coleccion; reemplazo completo de VO -> PUT; remocion veraz sin payload -> DELETE; todo lo demas -> `POST {recurso}:{verbo}`; PATCH proscrito de forma transversal), el casing kebab-case minusculo en todos los segmentos, la simetria CQRS (API en imperativo, event store en pasado) con sus fuentes de doctrina de comandos, la regla de aplicabilidad solo a endpoints nuevos (con precaucion explicita sobre renombrar endpoints viejos), el punto NO VERIFICADO del complex segment `{parametro}:verbo` en Azure Functions worker aislado con su gate empirico, y la enmienda a MEF-ADR-0006 (casing del ejemplo canonico, referencia cruzada) y a MEF-ADR-0011 (contrato HTTP como campo Critico del DoR, con su criterio programatico en el gate de `/implement`). El unico archivo no-ADR que toca el issue es `commands/implement.md`, y solo para destrabar esa autopropagacion: enumeraba una cantidad fija de criterios del DoR ("los 5 criterios"), que habria dejado el criterio 6 fuera del gate en silencio. Anota, sin resolver, la consecuencia pendiente en el borde APIM (MEF-ADR-0032) cuando un BC adopte PUT/DELETE.
- 2026-08-15: enmendada la seccion 1 (issue #631), que solo cubria el caso feliz (el Guid canonico y la clave compuesta de MEF-ADR-0037 ya son URL-safe) sin decir que hacer cuando el dato de negocio que se promueve a segmento de ruta no nace URL-safe -- vacio que dos issues independientes del consumidor Bitakora.ControlAsistencia (#381 y #387) descubrieron por su cuenta durante refinamiento. La seccion se reorganiza en cuatro subsecciones: 1.1 fija el charset canonico como el conjunto *unreserved* de RFC 3986 §2.3 (`A-Z a-z 0-9 - . _ ~`), con `:` excluido por partida doble (no es *unreserved* -- RFC 3986 §2.2 lo clasifica *gen-delims* -- y el marco ya lo reserva como separador de accion); 1.2 fija el criterio rechazar-vs-normalizar segun quien es dueno de la forma canonica del dato -- identidad que el dominio normaliza para unificar (ej. numero de identificacion, se normaliza sin rechazo en el punto unico de conversion de MEF-ADR-0037) vs. identificador asignado por un tercero (ej. codigo de colaborador, se rechaza con `400` si cae fuera del charset, nunca se altera en silencio); 1.3 fija el momento de la invariante como doctrina de planeacion -- se gana en un issue previo dedicado, nunca en el mismo PR que promueve el campo a segmento de ruta; 1.4 conserva y extiende el deslinde con MEF-ADR-0037: nombra donde se ejecutan normalizacion y rechazo (parseo tipado del borde HTTP en la seccion 2 de ese ADR, punto unico de conversion en su seccion 1), sin duplicar su mecanica ni reabrirla -- en particular deja constancia de que su regla unica *"normalizar, no rechazar"* **queda intacta**: el `400` del caso "identificador de tercero" es el de texto que no parsea como el tipo declarado, precisamente porque 1.3 exige que la URL-safety ya sea invariante de ese tipo. Numera como [7] y amplia la referencia bibliografica de RFC 3986, ya presente sin numero (ahora con §2.2/§2.3 citadas y URL verificada), y extiende las cross-referencias a MEF-ADR-0037 en el frontmatter y en "Referencias". Las cuatro subsecciones no llevan marcador `(CA-N)`: en este repo esos marcadores mapean a los criterios del issue que **creo** el ADR (#621), y reusarlos para los de un issue de enmienda haria ambiguo, por ejemplo, el `(CA-2)` de la seccion 7. No toca `agents/planner.md` ni `agents/reviewer.md` -- su actualizacion (replica de la precondicion, checklist del punto 3) es alcance del issue dependiente que este issue habilita.
- 2026-08-21: corregida la frase final de la seccion 1.1 (issue #681). La redaccion anterior afirmaba textualmente que "ninguno de los dos formatos usa `:`" para el identificador de stream de MEF-ADR-0037, en contradiccion directa con la seccion 1 de ese ADR, que fija como canonico `$"{empleadoId}:{fecha:yyyy-MM-dd}"` -- **con** `:` -- para la clave compuesta; la contradiccion, reportada desde el consumidor Bitakora.ControlAsistencia, alimento alli una lectura equivocada que costo un programa de renotacion innecesario. La nueva redaccion distingue por alcances: el Guid canonico "D" cumple el charset por construccion; la forma string de una identidad de un componente tipado no-Guid (MEF-ADR-0037 seccion 2 enmendada) si viaja como segmento y su URL-safety no es automatica (remite a 1.2 y 1.3); la clave compuesta via `ComputarStreamId` queda fuera del sujeto del charset porque nunca viaja entera en un segmento (misma seccion 2 enmendada) -- su separador es interno al punto unico de conversion. Las subsecciones 1.2, 1.3 y 1.4, el frontmatter "Aplica a" y la entrada de MEF-ADR-0037 en "Referencias" no se modifican: ya eran compatibles con la lectura por alcances.
