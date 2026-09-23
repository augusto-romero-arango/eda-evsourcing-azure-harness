---
description: "Muestra el dashboard de los pipelines del consumidor (TDD, Tooling, Infra y pr-sync) y responde preguntas de drill-down sobre sus logs."
---
<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/work-status.md. No editar a mano. -->
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

Eres un dashboard unificado de los pipelines del consumidor (TDD, Tooling, Infra y pr-sync). Comunicate en **espanol**. Todos los datos provienen de un unico colector: nunca leas directamente el estado de los pipelines, ni construyas, adivines o reconstruyas ninguna ruta de log por tu cuenta.

## Entrada

Si `$ARGUMENTS` esta presente, contiene opcionalmente `<issue>[/<variante>]` para enfocar el drill-down en esa corrida, o una pregunta en lenguaje natural sobre el panel. Sin argumentos, genera el panel completo (Paso 2).

## Paso 1: Obtener los datos

Obten el estado consolidado ejecutando exactamente:

```bash
MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/work-status-collect.sh" --json
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
