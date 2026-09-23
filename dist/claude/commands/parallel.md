---
description: "Lanza pipelines en paralelo para multiples issues, cada uno en su propio pane o tab."
argument-hint: "<issue1> <issue2> ... [--pipeline tdd|tooling]"
model: "haiku"
---
<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/parallel.md. No editar a mano. -->
```bash
mefisto_claude_root=''
mefisto_claude_canonical_contaminated=0
mefisto_claude_root_from_candidate() {
    local root
    case "$mefisto_claude_candidate" in /*) ;; *) return 1 ;; esac
    root="$(cd "$mefisto_claude_candidate" 2>/dev/null && pwd -P)" || return 1
    jq -e '
      .name == "mefisto" and
      (.version | type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$"))
    ' "$root/.claude-plugin/plugin.json" >/dev/null 2>&1 || return 1
    jq -e --arg version "$(jq -er '.version | strings' "$root/.claude-plugin/plugin.json" 2>/dev/null)" '
      (keys | sort) == ["commit", "runtime", "schemaVersion", "version"] and
      .schemaVersion == 1 and .runtime == "claude" and .version == $version and
      (.commit | type == "string" and test("^[0-9a-f]{40}$"))
    ' "$root/mefisto-manifest.json" >/dev/null 2>&1 || return 1
    printf '%s\n' "$root"
}
mefisto_claude_is_opencode_root() {
    local root
    case "$mefisto_claude_candidate" in /*) ;; *) return 1 ;; esac
    root="$(cd "$mefisto_claude_candidate" 2>/dev/null && pwd -P)" || return 1
    jq -e '
      (keys | sort) == ["commit", "minimumRuntimeVersion", "runtime", "schemaVersion", "version"] and
      .schemaVersion == 1 and .runtime == "opencode" and
      (.version | type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$")) and
      (.commit | type == "string" and test("^[0-9a-f]{40}$")) and
      (.minimumRuntimeVersion | type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))
    ' "$root/mefisto-manifest.json" >/dev/null 2>&1
}
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    mefisto_claude_candidate="$CLAUDE_PLUGIN_ROOT"
    mefisto_claude_root="$(mefisto_claude_root_from_candidate)" || {
        printf '%s\n' 'ERROR Claude: la raiz indicada por CLAUDE_PLUGIN_ROOT es invalida; reabra o reinstale el plugin.' >&2; exit 1;
    }
else
    mefisto_claude_cursor="$PWD"
    while :; do
        if [ -f "$mefisto_claude_cursor/.mefisto/pipeline/.plugin-root" ]; then
            mefisto_claude_candidate="$(< "$mefisto_claude_cursor/.mefisto/pipeline/.plugin-root")"
            if mefisto_claude_root="$(mefisto_claude_root_from_candidate)"; then break; fi
            if mefisto_claude_is_opencode_root; then
                mefisto_claude_canonical_contaminated=1
                break
            else
                printf '%s\n' 'ERROR Claude: metadata del marker canonico invalida; reabra o reinstale el plugin.' >&2; exit 1
            fi
        fi
        if [ "$mefisto_claude_cursor" = / ]; then break; fi
        mefisto_claude_cursor="$(cd "$mefisto_claude_cursor/.." && pwd -P)"
    done
    if [ -z "$mefisto_claude_root" ]; then
        mefisto_claude_cursor="$PWD"
        while :; do
            if [ -f "$mefisto_claude_cursor/.claude/pipeline/.plugin-root" ]; then
                mefisto_claude_candidate="$(< "$mefisto_claude_cursor/.claude/pipeline/.plugin-root")"
                if mefisto_claude_root="$(mefisto_claude_root_from_candidate)"; then break; fi
                if mefisto_claude_is_opencode_root; then
                    printf '%s\n' 'ERROR Claude: el marker Claude identifica una distribucion de otro runtime; reabra Claude o reinstale el plugin.' >&2; exit 1
                fi
                printf '%s\n' 'ERROR Claude: metadata del marker Claude invalida; reabra o reinstale el plugin.' >&2; exit 1
            fi
            if [ "$mefisto_claude_cursor" = / ]; then break; fi
            mefisto_claude_cursor="$(cd "$mefisto_claude_cursor/.." && pwd -P)"
        done
    fi
fi
if [ -z "$mefisto_claude_root" ]; then
    if [ "$mefisto_claude_canonical_contaminated" -eq 1 ]; then
        printf '%s\n' 'ERROR Claude: el marker canonico identifica una distribucion OpenCode y no existe un mirror Claude valido; reabra Claude o reinstale el plugin.' >&2
    else
        printf '%s\n' 'ERROR Claude: no se encontro una raiz Claude valida; reabra o reinstale el plugin.' >&2
    fi
    exit 1
fi
MEFISTO_PACKAGE_ROOT="$mefisto_claude_root"
export MEFISTO_PACKAGE_ROOT
```

Antes de continuar, aborta si existe `src/internal/scripts/generate-internal-adapters.sh`: ese directorio es el repositorio de Mefisto, no un consumidor.

Lanza pipelines en paralelo para multiples issues. Dentro de Herdr cada issue corre en su propio pane apilado en el workspace actual; fuera de Herdr, en una sesion tmux con un tab por issue. Los PRs se crean pero NO se mergean automaticamente. Comunicate en **espanol**.

**Grupos homogeneos**: todos los issues del grupo deben pertenecer al repo activo. El script subyacente (`parallel-pipeline.sh`) consulta cada issue con `gh issue view N` sin `-R`, asi que issues de otros repos se descartan automaticamente como UNKNOWN. No uses flags `-R` con este comando.

## Entrada

Los numeros de issues estan en: $ARGUMENTS

Si `$ARGUMENTS` esta vacio, responde: `Uso: /mefisto:parallel <issue1> <issue2> <issue3> ... [--pipeline tdd|tooling]`

## Proceso

### 1. Validar los issues

Para cada numero en los argumentos (excluyendo flags como `--pipeline`):

```bash
gh issue view <num> --json number,title,state,labels -q '"#\(.number): \(.title) [\(.state)] [\(.labels | map(.name) | join(", "))]"'
```

Si algun issue no existe o esta cerrado, informalo y excluyelo de la lista. Si no queda ningun issue valido, detente.

### 2. Mostrar resumen y lanzar

Muestra la lista de issues que se procesaran:

```
Paralelo — 3 issues (cada uno en su propio pane/tab):
  #42: Implementar calculo de horas extras nocturnas
  #43: Agregar validacion de jornada maxima
  #44: Calcular recargos dominicales
```

Si el grupo trae mas de un issue `tipo:projection`, avisa desde este resumen que /mefisto:sequential es el camino natural para un lote de puras proyecciones.

Luego lanza, pasando `--pipeline` si el usuario lo proporciono:

```bash
MEFISTO_RUNTIME=claude "${MEFISTO_PACKAGE_ROOT}/scripts/tmux-pipeline.sh" --parallel $ARGUMENTS
```

### 3. Instrucciones de conexion

Dentro de Herdr (`HERDR_ENV=1` en el entorno), el wrapper delega en la interfaz Herdr y no hay nada que adjuntar: cada issue queda corriendo en su propio pane apilado de este workspace, con el visor en vivo de su agente y arranques escalonados de 30s. En ese caso responde con:

```
Pipeline paralelo corriendo: un pane apilado por issue en este workspace.
Los PRs NO se mergean automaticamente.
Usa /mefisto:work-status para ver el progreso sin salir de aqui.
```

Fuera de Herdr responde con:

```
Pipeline paralelo lanzado en tmux. Para monitorear:
  tmux -CC attach -t parallel-<timestamp>

Cada issue tiene su propio tab. Los PRs NO se mergean automaticamente.
Usa /mefisto:work-status para ver el progreso sin salir de aqui.
```

## Reglas

- **No esperes a que termine.** Devuelve el control inmediatamente.
- **No implementes nada tu mismo.** Solo lanza el wrapper.
- Los PRs creados no se mergean. Recuerdale al usuario que puede usar /mefisto:merge despues.
- Si el usuario pasa `--pipeline tdd|tooling`, pasalo tal cual al wrapper.
- **Issues `tipo:projection`: nunca deben correr dos a la vez.** Todas las proyecciones del BC comparten los archivos del worker de proyecciones (MEF-ADR-0034). En cualquiera de los dos modos pane (Herdr y tmux) un lote con dos o mas aborta con mensaje, antes de crear panes: el camino es /mefisto:sequential, o `${MEFISTO_PACKAGE_ROOT}/scripts/parallel-pipeline.sh` directo (su scheduler si los serializa dentro del lote sin frenar al resto).
- Para limitar la concurrencia con `--max-parallel`, lanza `${MEFISTO_PACKAGE_ROOT}/scripts/parallel-pipeline.sh` directo. Para detener esa corrida con cola usa /mefisto:batch-stop; el modo pane de este comando lanza todos los issues de entrada y no tiene cola que retener.
