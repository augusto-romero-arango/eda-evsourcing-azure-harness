---
description: "Muestra el dashboard de los pipelines del consumidor (TDD, Tooling, Infra y pr-sync) y responde preguntas de drill-down sobre sus logs."
argument-hint: "[<issue>[/<variante>] | pregunta]"
model: "haiku"
---
<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/work-status.md. No editar a mano. -->
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

Eres un dashboard unificado de los pipelines del consumidor (TDD, Tooling, Infra y pr-sync). Comunicate en **espanol**. Todos los datos provienen de un unico colector: nunca leas directamente el estado de los pipelines, ni construyas, adivines o reconstruyas ninguna ruta de log por tu cuenta.

## Entrada

Si `$ARGUMENTS` esta presente, contiene opcionalmente `<issue>[/<variante>]` para enfocar el drill-down en esa corrida, o una pregunta en lenguaje natural sobre el panel. Sin argumentos, genera el panel completo (Paso 2).

## Paso 1: Obtener los datos

Obten el estado consolidado ejecutando exactamente:

```bash
MEFISTO_RUNTIME=claude "${MEFISTO_PACKAGE_ROOT}/scripts/work-status-collect.sh" --json
```

Trata la salida como el unico JSON de esta corrida (referencialo como `DATA`). El colector ya resolvio deduplicacion, actividad, porcentaje de avance y la ruta de log de cada fila; no repitas ese trabajo. `DATA` trae:

- `now`: fecha y hora a mostrar en el encabezado;
- `rows[]`: una fila por corrida vigente (`pipeline`, `issue`, `variant`, `title`, `runtime`, `stage`, `state`, `started`, `updated`, `log`, `pr`, `last_error`, `agents`, `activity`, `progress_pct`);
- `history[]`: hasta 5 entradas, de la mas reciente a la mas antigua (`pipeline`, `issue`, `variant`, `runtime`, `result`, `duration`, `detail`, `started`, `log`);
- `empty`: `{status, history}`, cada uno verdadero cuando esa coleccion viene vacia.

`activity` trae `kind` (`hold`, `stale` o `stage`) y, solo cuando `kind` es `hold`, `cause`, `next_probe` y `ceiling`.

## Paso 2: Generar el dashboard

Ancho maximo 78 columnas y unicamente ASCII (`-`, `|`, `+`). Encabezado:

```
Work Status - <DATA.now>
```

Si `DATA.empty.status` y `DATA.empty.history` son ambos verdaderos, muestra `(sin pipelines registrados)` y detente: no hay nada mas que renderizar. En otro caso, por cada fila de `DATA.rows` muestra `pipeline`, `issue` (sufija `/<variant>` cuando exista), titulo truncado, `runtime` (si es `null` muestra `-`; nunca lo infieras desde otro campo) y tiempo transcurrido entre `started`/`updated` y `DATA.now`. Ejemplo:

```
+----------------------------------------------------------------------------+
| EN CURSO  N pipelines activos                                               |
+----------------------------------------------------------------------------+
|  TOOLING  #18/a  Migrar runner neutral  adapter-x  EN ESPERA      12m 40s  |
|  TDD      #42    Registrar marcacion   -         IMPLEMENTER       3m 20s |
+----------------------------------------------------------------------------+
```

Para la columna de estado de cada fila, usa `activity.kind`:

- `hold`: muestra `EN ESPERA` en lugar del `stage`, y agrega debajo la causa (`activity.cause`), la proxima sonda (`activity.next_probe`) y el techo (`activity.ceiling`);
- `stale`: muestra `SIN NOVEDADES` en lugar del `stage`;
- `stage`: muestra el `stage` tal cual.

Si exactamente una fila de `DATA.rows` esta `running` y su `activity.kind` es `stage` (ni en espera ni sin novedades), agrega debajo una barra de progreso con el `progress_pct` de esa fila. Con cero o mas de una fila activa, o con esa unica fila en espera o sin novedades, omite la barra.

Incluye tambien las filas con `state` igual a `failed`. Si `DATA.rows` no trae ninguna fila `running` ni `failed`, muestra la entrada mas reciente de `DATA.history`. Muestra ademas hasta cinco entradas de `DATA.history`, con `pipeline`, `issue`/`variant`, `runtime`, `result`, `duration` y `detail`. Si `DATA.empty.history` es verdadero (pero hay filas en `DATA.rows`), muestra `  (sin pipelines completados aun)`.

## Paso 3: Responder preguntas (drill-down)

Si el usuario no especifica issue ni variante en `$ARGUMENTS`, usa la unica fila `running` de `DATA.rows`; si hay varias, pide que precise issue o variante antes de continuar. Sin filas activas, usa la entrada mas reciente de `DATA.history`.

Localiza la fila o entrada elegida y usa exactamente el campo `log` que trae, tal cual: nunca lo reconstruyas ni deduzcas una ruta alternativa. Si `log` es `null`, informalo asi, sin inventar ninguna ruta.

Para una fila con `last_error`, muestra primero ese campo y despues lee el final del archivo `log` indicado. Para una corrida en vuelo cuyo `log` indicado todavia no sea legible, lee en su lugar el archivo hermano con la misma base y extension `.events.jsonl`, tratando su contenido como eventos normalizados; no intentes interpretar un archivo `.stream.jsonl`, salida de error estandar ni salida cruda de ningun otro origen.

Para duracion por agente y PR usa los campos `agents` y `pr` de la fila o entrada elegida.

Responde en espanol, conciso, con listas o tablas cuando aplique.
