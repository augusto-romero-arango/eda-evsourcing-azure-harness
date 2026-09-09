---
description: "Lanza el pipeline de tooling del consumidor para un issue de GitHub dentro de una sesion tmux."
argument-hint: "<issue> [--models 'agente=modelo[,agente=modelo...]'] [--variant <label>]"
model: "haiku"
---
<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/tooling.md. No editar a mano. -->
```bash
mefisto_claude_root=''
mefisto_claude_candidate="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$mefisto_claude_candidate" ]; then
    mefisto_claude_cursor="$PWD"
    while :; do
        if [ -f "$mefisto_claude_cursor/.mefisto/pipeline/.plugin-root" ]; then
            mefisto_claude_candidate="$(< "$mefisto_claude_cursor/.mefisto/pipeline/.plugin-root")"
            break
        fi
        if [ "$mefisto_claude_cursor" = / ]; then break; fi
        mefisto_claude_cursor="$(cd "$mefisto_claude_cursor/.." && pwd -P)"
    done
fi
if [ -z "$mefisto_claude_candidate" ]; then
    mefisto_claude_cursor="$PWD"
    while :; do
        if [ -f "$mefisto_claude_cursor/.claude/pipeline/.plugin-root" ]; then
            mefisto_claude_candidate="$(< "$mefisto_claude_cursor/.claude/pipeline/.plugin-root")"
            break
        fi
        if [ "$mefisto_claude_cursor" = / ]; then break; fi
        mefisto_claude_cursor="$(cd "$mefisto_claude_cursor/.." && pwd -P)"
    done
fi
case "$mefisto_claude_candidate" in
    /*) ;;
    *) printf '%s\n' 'ERROR Claude: no se encontro una raiz absoluta valida; reabra o reinstale el plugin.' >&2; exit 1 ;;
esac
mefisto_claude_root="$(cd "$mefisto_claude_candidate" 2>/dev/null && pwd -P)" || {
    printf '%s\n' 'ERROR Claude: la raiz del plugin no existe; reabra o reinstale el plugin.' >&2; exit 1;
}
if ! jq -e '
  .name == "mefisto" and
  (.version | type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$"))
' "$mefisto_claude_root/.claude-plugin/plugin.json" >/dev/null 2>&1; then
    printf '%s\n' 'ERROR Claude: metadata del plugin invalida; reabra o reinstale el plugin.' >&2; exit 1
fi
MEFISTO_PACKAGE_ROOT="$mefisto_claude_root"
export MEFISTO_PACKAGE_ROOT
```

Antes de continuar, aborta si existe `src/internal/scripts/generate-internal-adapters.sh`: ese directorio es el repositorio de Mefisto, no un consumidor.

Lanza el pipeline de tooling para un issue de GitHub dentro de una sesion tmux. Comunicate en **espanol**.

**Alcance**: este comando solo lanza tareas de tooling del proyecto consumidor. No implementa logica de dominio ni cambia el plugin Mefisto. Si la causa pertenece a Mefisto, crea o enruta un draft en su repositorio y detiene esta ejecucion.

## Entrada

El numero de issue y los flags estan en: $ARGUMENTS

Si `$ARGUMENTS` esta vacio o los flags no tienen valor, responde: `Uso: /mefisto:tooling <numero-de-issue> [--models 'agente=modelo[,agente=modelo...]'] [--variant <label>]`.

Extrae `ISSUE_NUM` como el primer token numerico de `$ARGUMENTS`. Reenvia `$ARGUMENTS` intacto al wrapper: el parser definitivo y la validacion de formato pertenecen al wrapper y al pipeline, sin mantener una segunda gramatica shell aqui.

`--models` acepta un mapa opaco para las claves de stage `writer` y `reviewer`; no alteres sus valores ni publiques aliases de proveedor. `--variant <label>` conserva el slug, aislamiento y semantica sin mutaciones del issue.

## Proceso

### 1. Validar el issue

Consulta el issue con `gh issue view ISSUE_NUM --json number,title,state,labels,body`. Muestra titulo, estado y labels. Si no es consultable, no existe o esta cerrado (`CLOSED`), informa el motivo y detente.

### 2. Validar el tipo y los bloqueos

Verifica el label `tipo:tooling`. Si falta, explica que la logica de dominio se lanza con el comando de implementacion y pide confirmacion explicita antes de continuar. Si no se confirma, detente.

Si lleva el label `bloqueado`, lee solo `## Dependencias` del body y considera exclusivamente las lineas `Depende de #N` o `Bloqueado por #N`. Consulta cada dependencia como issue o PR. Una dependencia abierta o no consultable es un bloqueo visible: muestra su numero, titulo si pudo consultarse y estado, y detente.

Cuando todas las dependencias declaradas cerraron (`CLOSED`) o se integraron (`MERGED`), retira el label `bloqueado` y continua. Con `--variant`, nunca mutas labels: informa que el label permanece y continua solo si todas las dependencias cerraron.

### 3. Lanzar

Muestra la informacion validada del issue y ejecuta exactamente:

```bash
${MEFISTO_PACKAGE_ROOT}/scripts/tmux-pipeline.sh --tooling $ARGUMENTS
```

Dentro de Herdr, informa que el pipeline queda corriendo en un pane de este workspace con el visor en vivo. Fuera de Herdr, informa que fue lanzado en una sesion tmux y que el nombre usa `tooling-ISSUE_NUM`, con el sufijo de variante cuando aplique.

## Reglas

- **No esperes a que termine.** Devuelve el control inmediatamente.
- **No implementes nada tu mismo.** Solo valida y lanza el wrapper.
- Si tmux no esta instalado fuera de Herdr, el wrapper muestra el error.
