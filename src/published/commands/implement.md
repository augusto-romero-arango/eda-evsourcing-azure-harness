---
{
  "kind": "command",
  "id": "implement",
  "description": "Lanza el pipeline TDD del consumidor para un issue de GitHub dentro de una sesion tmux.",
  "profile": "fast",
  "arguments": "<issue> [--models 'agente=modelo[,agente=modelo...]'] [--variant <label>]"
}
---

{{mefisto:assert-consumer-repo}}

Lanza el pipeline TDD para un issue de GitHub dentro de una sesion tmux. Comunicate en **espanol**.

**Alcance**: este comando solo lanza trabajo TDD del proyecto consumidor. No cambia el plugin Mefisto. Si la causa pertenece a Mefisto, crea o enruta un draft en su repositorio y detiene esta ejecucion.

## Entrada

El numero de issue y los flags estan en: $ARGUMENTS

Si `$ARGUMENTS` esta vacio, no contiene un token compuesto solo por digitos, incluye un flag sin valor o presenta argumentos mal formados, muestra el motivo y responde con este uso accionable: `Uso: /mefisto:implement <numero-de-issue> [--models 'agente=modelo[,agente=modelo...]'] [--variant <label>]`.

Extrae `ISSUE_NUM` como el primer token numerico de `$ARGUMENTS`. Reenvia `$ARGUMENTS` intacto al wrapper: el parser definitivo y la validacion de formato pertenecen al wrapper y al pipeline, sin mantener una segunda gramatica shell aqui.

`--models` acepta un mapa opaco para los stages TDD; no alteres sus valores ni publiques aliases de proveedor. Un stage omitido conserva su default.

`--variant <label>` recibe un slug de minusculas, digitos y guiones (`[a-z0-9-]`, maximo 40 caracteres). Conserva el aislamiento mediante el sufijo `-<label>` en worktree, rama, logs y pane o sesion. Una variante no hace push, no abre PR ni muta el issue (comentarios, labels o transiciones); deja la rama local para compararla. No intentes validar otra vez estas gramaticas: reenvia ambos flags intactos.

## Proceso

### 1. Validar el issue y su tipo

Consulta el issue con `gh issue view ISSUE_NUM --json number,title,state,labels,body`. Muestra titulo, estado y labels. Si no es consultable, no existe o esta cerrado (`CLOSED`), informa el motivo y detente.

Exige exactamente un tipo TDD: `tipo:feature`, `tipo:refactor` o `tipo:projection`. Si hay `tipo:tooling`, informa que debe lanzarse con {{mefisto:command tooling}} y detente. Si falta un tipo TDD, hay mas de uno, o hay un tipo no compatible, muestra los labels detectados y detente.

### 2. Validar Definition of Ready

Lee la seccion `Validacion en \`/implement\`` de `{{mefisto:package-root}}/docs/adr/mef-adr-0011-definition-of-ready.md`. Aplica todos los criterios vigentes que enumera esa seccion usando los labels y body ya consultados; no memorices una cantidad fija ni dupliques su doctrina aqui. Acumula todos los fallos antes de reportarlos.

Si uno o mas criterios fallan, muestra la lista completa de lo que falta, sugiere `planner refinar` para completarlos y detente. Si todos pasan, continua.

### 3. Verificar label bloqueado

Si lleva el label `bloqueado`, lee solo la seccion `## Dependencias` del body, hasta el siguiente encabezado de nivel dos, y considera exclusivamente las lineas canonicas `Depende de #N` o `Bloqueado por #N` (tambien si llevan marcador de lista). Ignora cualquier otro `#N`.

Para cada numero, intenta primero `gh pr view` y, si no corresponde a un PR, `gh issue view`, consultando titulo y estado. Si no hay una dependencia canonica consultable, o una dependencia `OPEN` o no consultable, conserva el label, muestra el bloqueo visible y detente; nunca supongas que un fallo significa cierre.

Solo cuando todas las dependencias canonicas declaradas cerraron (`CLOSED`) o se integraron (`MERGED`), retira el label `bloqueado` y continua. Con `--variant`, nunca mutas labels: informa que el label permanece y continua solo si todas las dependencias cerraron.

### 4. Detectar dominio(s) y necesidad de scaffold

Obtiene todos los labels `dom:*` del issue. Para cada dominio, obtiene `namespacePrefix` desde `{{mefisto:config-path}}` y lo convierte a PascalCase para comprobar `src/<namespacePrefix>.{Dominio}/`.

La necesidad de scaffold se deriva solo del alcance declarado: lee la seccion cuyo encabezado empieza con `## Impacto`, hasta el siguiente encabezado de nivel dos. Si esa seccion no existe o no menciona `src/<namespacePrefix>.{Dominio}/`, no preguntes por ese dominio. Si la menciona y el directorio no existe, es candidato a scaffold.

Si no hay candidatos, continua al lanzamiento sin scaffold. Para cada candidato, muestra exactamente las tres opciones: (1) scaffoldear el dominio antes de lanzar el pipeline, (2) continuar sin scaffold y (3) abortar. La opcion 3 detiene la ejecucion. La opcion 2 no agrega scaffold.

Si mas de un dominio recibe opcion 1, no lances el pipeline: informa que solo se admite un scaffold por invocacion, pide scaffoldear los adicionales por separado y volver a ejecutar el comando. Nunca autorices mas de un scaffold por invocacion.

### 5. Lanzar

Muestra la informacion validada del issue. Sin scaffold confirmado ejecuta exactamente:

```bash
{{mefisto:run tmux-pipeline.sh $ARGUMENTS}}
```

Con un unico scaffold confirmado, ejecuta la forma equivalente agregando el dominio kebab-case confirmado:

```bash
{{mefisto:run tmux-pipeline.sh $ARGUMENTS --scaffold-domain <dominio-kebab-confirmado>}}
```

En ambas rutas reenvia los argumentos intactos y deja al wrapper la validacion definitiva. Dentro de Herdr, informa que el pipeline queda corriendo en un pane de este workspace con el visor en vivo. Fuera de Herdr, informa que fue lanzado en una sesion tmux; el wrapper informa la sesion o pane creado.

## Reglas

- **No esperes a que termine.** Devuelve el control inmediatamente.
- **No implementes nada tu mismo.** Solo valida y lanza el wrapper.
- **Nunca crees un dominio sin confirmacion explicita.** El scaffold implica infraestructura del consumidor.
- Si tmux no esta instalado fuera de Herdr, el wrapper muestra el error.
