---
description: "Lanza el pipeline de tooling del consumidor para un issue de GitHub dentro de una sesion tmux."
---
<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/tooling.md. No editar a mano. -->
```bash
mefisto_opencode_data_root() {
    if [ -n "${XDG_DATA_HOME:-}" ]; then printf '%s/mefisto\n' "$XDG_DATA_HOME"
    elif [ "$(uname -s)" = Darwin ]; then printf '%s/Library/Application Support/mefisto\n' "$HOME"
    else printf '%s/.local/share/mefisto\n' "$HOME"; fi
}
mefisto_opencode_launcher="$(mefisto_opencode_data_root)/active/bin/mefisto-opencode"
if [ ! -f "$mefisto_opencode_launcher" ] || [ -L "$mefisto_opencode_launcher" ] || [ ! -x "$mefisto_opencode_launcher" ]; then
    printf '%s\n' 'ERROR OpenCode: no hay una release activa valida; instale o active la release OpenCode.' >&2; exit 1
fi
MEFISTO_PACKAGE_ROOT="$("$mefisto_opencode_launcher" package-root)" || {
    printf '%s\n' 'ERROR OpenCode: no se pudo resolver la release activa; instale o active la release OpenCode.' >&2; exit 1;
}
case "$MEFISTO_PACKAGE_ROOT" in
    /*) ;;
    *) printf '%s\n' 'ERROR OpenCode: la release activa no devolvio una raiz absoluta; reinstale o active la release OpenCode.' >&2; exit 1 ;;
esac
MEFISTO_PACKAGE_ROOT="$(cd "$MEFISTO_PACKAGE_ROOT" 2>/dev/null && pwd -P)" || {
    printf '%s\n' 'ERROR OpenCode: la release activa no existe; reinstale o active la release OpenCode.' >&2; exit 1;
}
export MEFISTO_PACKAGE_ROOT
```

Antes de continuar, aborta si existe `src/internal/scripts/generate-internal-adapters.sh`: ese directorio es el repositorio de Mefisto, no un consumidor.

Lanza el pipeline de tooling para un issue de GitHub dentro de una sesion tmux. Comunicate en **espanol**.

**Alcance**: este comando solo lanza tareas de tooling del proyecto consumidor. No implementa logica de dominio ni cambia el plugin Mefisto. Si la causa pertenece a Mefisto, crea o enruta un draft en su repositorio y detiene esta ejecucion.

## Entrada

El numero de issue y los flags estan en: $ARGUMENTS

Si `$ARGUMENTS` esta vacio, no contiene un token compuesto solo por digitos, incluye un flag sin valor o presenta argumentos mal formados, muestra el motivo y responde con este uso accionable: `Uso: /mefisto:tooling <numero-de-issue> [--models 'agente=modelo[,agente=modelo...]'] [--variant <label>]`.

Extrae `ISSUE_NUM` como el primer token numerico de `$ARGUMENTS`. Reenvia `$ARGUMENTS` intacto al wrapper: el parser definitivo y la validacion de formato pertenecen al wrapper y al pipeline, sin mantener una segunda gramatica shell aqui.

`--models` acepta un mapa opaco para las claves de stage `writer` y `reviewer`; no alteres sus valores ni publiques aliases de proveedor. Un stage omitido conserva su default y `writer` cubre tanto escritura como merge porque ambos stages usan esa clave.

`--variant <label>` recibe un slug de minusculas, digitos y guiones (`[a-z0-9-]`, maximo 40 caracteres). Conserva el aislamiento mediante el sufijo `-<label>` en worktree, rama, logs y pane o sesion. Una variante no hace push, no abre PR ni muta el issue (comentarios, labels o transiciones); deja la rama local para compararla. No intentes validar otra vez estas gramaticas: reenvia ambos flags intactos.

## Proceso

### 1. Validar el issue

Consulta el issue con `gh issue view ISSUE_NUM --json number,title,state,labels,body`. Muestra titulo, estado y labels. Si no es consultable, no existe o esta cerrado (`CLOSED`), informa el motivo y detente.

### 2. Validar el tipo y los bloqueos

Verifica el label `tipo:tooling`. Si falta, explica que la logica de dominio se lanza con el comando de implementacion y pide confirmacion explicita antes de continuar. Si no se confirma, detente.

Si lleva el label `bloqueado`, lee solo la seccion `## Dependencias` del body, hasta el siguiente encabezado de nivel dos, y considera exclusivamente las lineas canonicas `Depende de #N` o `Bloqueado por #N` (tambien si llevan marcador de lista). Ignora cualquier otro `#N`. Si no hay una dependencia canonica consultable, conserva el label, muestra el bloqueo y detente.

Para cada numero, intenta primero `gh pr view` y, si no corresponde a un PR, `gh issue view`, consultando titulo y estado. Una dependencia `OPEN` o no consultable es un bloqueo visible: muestra su numero, titulo si pudo consultarse y estado o error de consulta, y detente; nunca supongas que un fallo significa cierre.

Solo cuando todas las dependencias canonicas declaradas cerraron (`CLOSED`) o se integraron (`MERGED`), retira el label `bloqueado` y continua. Con `--variant`, nunca mutas labels: informa que el label permanece y continua solo si todas las dependencias cerraron.

### 3. Lanzar

Muestra la informacion validada del issue y ejecuta exactamente:

```bash
"${MEFISTO_PACKAGE_ROOT}/scripts/tmux-pipeline.sh" --tooling $ARGUMENTS
```

Dentro de Herdr, informa que el pipeline queda corriendo en un pane de este workspace con el visor en vivo. Fuera de Herdr, informa que fue lanzado en una sesion tmux y que el nombre usa `tooling-ISSUE_NUM`, con el sufijo de variante cuando aplique.

## Reglas

- **No esperes a que termine.** Devuelve el control inmediatamente.
- **No implementes nada tu mismo.** Solo valida y lanza el wrapper.
- Si tmux no esta instalado fuera de Herdr, el wrapper muestra el error.
