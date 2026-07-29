#!/usr/bin/env bash
# mefisto-stream-watch.sh -- Visor en vivo del flujo de acciones del agente
# sobre la traza stream-json cruda de un stage (issue #434)
#
# Uso:
#   .claude/scripts/mefisto-stream-watch.sh
#       Descubre por si solo el *.stream.jsonl mas reciente en
#       .claude/pipeline/logs/ y lo sigue en vivo. Cuando aparece un stream
#       mas nuevo (stage 2, o el siguiente issue de un batch/secuencial)
#       cambia a el solo.
#
#   .claude/scripts/mefisto-stream-watch.sh <ruta-al-stream>
#       Sigue/inspecciona un stream concreto (p. ej. para revisar una corrida
#       pasada) en vez de descubrir el mas reciente.
#
# Contexto: durante una corrida de /mefisto-tooling el pane de tmux que hace
# `tail -f` de events.log solo ve DOS lineas por corrida completa ("STAGE 1:
# writer" / "STAGE 2: reviewer") -- 20+ minutos de silencio en el medio, sin
# forma de notar que el agente esta dando vueltas ni de aprender mirando. La
# traza cruda `<log_base>.stream.jsonl` (una linea JSON por evento del CLI,
# `--output-format stream-json --verbose`, ver run_agent en
# mefisto-tooling-pipeline.sh) ya crece en vivo desde #431; este script la sigue
# incrementalmente y renderiza una linea legible por accion: hora, delta
# desde la accion anterior (el reloj es lo que revela los round-trips de
# ~20s), herramienta y objetivo. Los turnos SIN tool call tambien se señalan
# (texto y bloques de thinking): son los que no mueven ningun archivo y donde
# se va el tiempo de razonamiento.
#
# Solo lectura y autonomo (CA-6): no modifica ningun pipeline ni archivo
# existente, no escribe en .claude/pipeline/ (solo en un directorio temporal
# propio via mktemp) y se puede invocar a mano en cualquier terminal contra
# una corrida en marcha o pasada.
#
# Lectura incremental sin `tail -f` (notas tecnicas del issue): se lleva un
# contador de lineas ya consumidas y se emiten las nuevas con
# `sed -n "$((last+1)),\$p"` cada ~1s -- mas simple y portable que anidar
# `tail -f` y matarlo al cambiar de stream (tail -F de BSD no acepta --pid),
# y resuelve el cambio de stream con solo comparar la ruta descubierta.
#
# Entorno: macOS con bash 3.2.57 en PATH -- nada de `declare -A` (bash 3.2 no
# la tiene); el contador de repeticion de CA-4 usa un archivo temporal en vez
# de un array asociativo.
#
# A proposito NO se reutiliza ni modifica derive_stage_log_from_stream de
# _mefisto-common.sh (deriva el log COMPLETO post-mortem, no un render
# incremental) -- evita colisionar con el trabajo de #427 sobre el mismo
# archivo.
#
# Testeable sin invocar el CLI ni depender de una corrida real (CA-7): cada
# pieza de logica vive en su propia funcion pura (o casi pura, con estado en
# variables globales explicitas) para que
# .claude/scripts/tests/test-stream-watch.sh pueda extraerlas con el mismo
# patron de test-abort-log-tail.sh (awk sobre "funcname() {" .. "}") y
# evaluarlas sueltas, sin sourcing el archivo completo (evita disparar
# assert_in_mefisto/el chequeo de jq/el bucle principal).

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_mefisto-common.sh"
assert_in_mefisto || exit 1

# --- Colores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

LOG_DIR="$MEFISTO_REPO_ROOT/.claude/pipeline/logs"
POLL_INTERVAL=1

# Estado runtime (mutado por process_new_lines/render_row a lo largo del
# bucle principal). Sin `declare -A` disponible en bash 3.2, la repeticion de
# CA-4 se lleva en un archivo temporal (TOUCHED_FILE, una linea por toque).
TMP_STATE=""
TOUCHED_FILE=""
JQ_FILTER_PATH=""
LAST_LINE=0
PREV_EMS=""
CURRENT_STREAM=""

# write_jq_filter <dest_file>
#
# Escribe en <dest_file> el programa jq que traduce una linea cruda del
# stream (un evento `assistant`/`result`, ya parseado por linea en
# process_new_lines) a una fila TSV lista para render_row: "tool" (nombre +
# objetivo aplanado a una sola linea via `flatten`, CA-3), "text" (turno sin
# tool call -- texto o bloque de thinking, CA-2) o "result" (cierre de stage,
# CA-5). El guard `if (type != "object") then empty` tolera una linea que SI
# es JSON valido pero no es un objeto (select(type=="object") en
# derive_stage_log_from_stream cubre el mismo caso) sin que jq aborte con un
# error de indexado duro.
#
# `cell` sustituye por "-" todo campo nulo o vacio, y NO es cosmetico: la
# fila se lee en el shell con `IFS=$'\t' read`, y el tab es un caracter de
# espacio en blanco para IFS -- bash colapsa dos tabs seguidos en un solo
# separador, asi que un campo vacio en el medio DESPLAZARIA todos los que
# siguen. Con placeholder no hay campo vacio y la posicion se conserva; el
# shell lo traduce de vuelta con is_missing. El caso real que lo exige: el
# evento `result` del CLI NO trae `.timestamp` (verificado contra las trazas
# de .claude/pipeline/logs/), asi que su segundo campo siempre estaria vacio
# y el cierre de stage reportaria duration_ms como turnos y is_error como
# costo.
#
# El objetivo por herramienta sigue el vocabulario de CA-2: ruta para
# Read/Edit/Write/NotebookEdit, comando para Bash, patron (+ruta si la trae)
# para Grep/Glob; el resto cae a un fallback generico (primer valor string
# del input, o "(sin detalle)").
write_jq_filter() {
    local dest="$1"
    cat > "$dest" <<'MEFISTO_STREAM_WATCH_JQ'
def epoch_ms:
  if . == null then null
  else
    (capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.(?<frac>[0-9]+))?Z$")) as $c
    | if $c == null then null
      else
        (($c.base + "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $sec
        | $sec*1000 + (if $c.frac then (($c.frac + "000") | .[0:3] | tonumber) else 0 end)
      end
  end;

# Aplana a una sola linea (CA-3): los comandos Bash traen newlines embebidos,
# y volcarlos crudos parte un comando en varias lineas del pane. Se barren
# primero los caracteres de control ([[:cntrl:]] cubre newline/tab/CR y
# tambien el ESC de una secuencia ANSI, que garabatearia el pane) y luego se
# colapsa la corrida de espacios resultante.
def flatten: tostring | gsub("[[:cntrl:]]"; " ") | gsub("\\s+"; " ") | gsub("^ +| +$"; "");

# Campo vacio o nulo -> "-", para que la fila TSV nunca colapse en el
# `IFS=$'\t' read` del shell (ver el comentario de write_jq_filter).
def cell: if (. == null or . == "") then "-" else tostring end;
def row: map(cell) | @tsv;

def is_file_tool($name):
  ($name == "Read" or $name == "Edit" or $name == "Write"
    or $name == "NotebookEdit" or $name == "MultiEdit");

def target_for($name; $in):
  if is_file_tool($name) then
    ($in.file_path // $in.notebook_path // "?")
  elif $name == "Bash" then
    ($in.command // "?")
  elif ($name == "Grep" or $name == "Glob") then
    (($in.pattern // $in.glob // "?") as $p
      | ($in.path // null) as $pa
      | if $pa then ($p + " @ " + $pa) else $p end)
  elif $name == "WebFetch" then
    ($in.url // "?")
  elif $name == "WebSearch" then
    ($in.query // "?")
  elif ($name == "Task" or $name == "Agent") then
    ($in.description // $in.prompt // "?")
  else
    ((try [$in | to_entries[] | select(.value | type == "string") | .value] catch []) | first // "(sin detalle)")
  end;

if (type != "object") then empty else
  . as $e
  | ($e.timestamp | epoch_ms) as $ems
  | if $e.type == "assistant" then
      ($e.message.content // []) as $content
      | ($content | map(select(.type == "tool_use"))) as $tools
      | if ($tools | length) > 0 then
          $tools[] as $t
          | ($t.input // {}) as $in
          | [ "tool", $ems, $t.name, (target_for($t.name; $in) | flatten),
              (if is_file_tool($t.name) then (($in.file_path // $in.notebook_path // "") | flatten) else "" end) ]
          | row
        else
          # Turno sin tool call: ahi se va el tiempo de razonamiento (CA-2). Se
          # distinguen los dos sabores que produce el CLI, porque ambos son
          # frecuentes en una traza real: bloques `text` (el agente escribe al
          # humano) y bloques `thinking` (razonamiento; su texto viaja vacio y
          # solo queda la firma, asi que se señala el turno, no su contenido).
          if ($content | map(select(.type == "text" and ((.text // "") | length > 0))) | length) > 0 then
            [ "text", $ems, "texto" ] | row
          elif ($content | map(select(.type == "thinking")) | length) > 0 then
            [ "text", $ems, "pensamiento" ] | row
          else empty end
        end
    elif $e.type == "result" then
      [ "result", $ems, $e.num_turns, $e.duration_ms, $e.duration_api_ms,
        $e.total_cost_usd, $e.is_error ]
      | row
    else empty end
end
MEFISTO_STREAM_WATCH_JQ
}

# discover_stream <log_dir>
#
# Imprime por stdout la ruta absoluta del *.stream.jsonl mas reciente (por
# mtime) de <log_dir>, o nada si el directorio no existe o esta vacio (CA-1).
# El mtime es el criterio correcto para detectar el cambio de stage/issue: en
# cualquier momento solo un agente esta corriendo, asi que su stream es el
# unico que sigue recibiendo escrituras -- el de un stage ya terminado deja
# de actualizar su mtime en el instante en que el nuevo empieza a escribir.
discover_stream() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    ls -t "$dir"/*.stream.jsonl 2>/dev/null | head -1
}

# parse_stream_header <stream_path>
#
# Imprime el encabezado de CA-1: el nombre del stream ya codifica issue,
# stage y agente (`mefisto-tooling-stage-<N>-<agente>-<TS>-issue-<N>.stream.jsonl`,
# ver run_agent en mefisto-tooling-pipeline.sh) -- de ahi sale el encabezado
# sin leer el contenido del archivo. Si la ruta no matchea ese patron (una
# ruta manual con otro nombre, o una convencion futura), degrada a mostrar
# el nombre tal cual en vez de fallar.
parse_stream_header() {
    local path="$1"
    local base
    base=$(basename "$path")

    if [[ "$base" =~ ^mefisto-tooling-stage-([^-]+)-([^-]+)-([0-9]{8}-[0-9]{6})-issue-([0-9]+)\.stream\.jsonl$ ]]; then
        local stage="${BASH_REMATCH[1]}"
        local agent="${BASH_REMATCH[2]}"
        local ts="${BASH_REMATCH[3]}"
        local issue="${BASH_REMATCH[4]}"
        printf '%b\n' "${CYAN}${BOLD}=== issue #${issue} -- stage ${stage} (${agent}) -- ${ts} ===${NC}"
    else
        printf '%b\n' "${CYAN}${BOLD}=== ${base} ===${NC}"
    fi
    printf '%b\n' "${CYAN}${path}${NC}"
}

# pane_width
#
# Ancho de columnas de la terminal actual (`tput cols`), o 80 si no se puede
# determinar (headless, sin tty). Usado por render_row para truncar targets
# largos al ancho real del pane (CA-3). Un COLUMNS explicito en el entorno
# gana: permite fijar el ancho a mano (`COLUMNS=60 mefisto-stream-watch.sh`)
# y deja el truncado verificable en el test sin depender del tty que corra.
pane_width() {
    local w="${COLUMNS:-}"
    if [ -z "$w" ]; then
        w=$(tput cols 2>/dev/null)
    fi
    if [ -n "$w" ] && [ "$w" -gt 0 ] 2>/dev/null; then
        echo "$w"
    else
        echo 80
    fi
}

# is_missing <valor>
#
# 0 si <valor> representa "campo ausente" en una fila del filtro jq: vacio,
# el placeholder "-" que emite `cell` (ver write_jq_filter) o el literal
# "null". Centraliza el contrato de la fila para que los formateadores no
# repitan el triple guard.
is_missing() {
    case "$1" in
        ""|"-"|"null") return 0 ;;
        *) return 1 ;;
    esac
}

# truncate_target <texto> <maxlen>
#
# Trunca <texto> a <maxlen> caracteres con sufijo "..." si excede; lo
# devuelve tal cual si ya entra. <maxlen> se sanea a un minimo de 4 (el
# sufijo por si solo ya ocupa 3). Corta por el final: es lo correcto para un
# comando Bash, donde lo que identifica la accion esta al principio
# (`dotnet test ...`).
truncate_target() {
    local s="$1" maxlen="$2"
    [ "$maxlen" -lt 4 ] 2>/dev/null && maxlen=4
    local len=${#s}
    if [ "$len" -le "$maxlen" ]; then
        printf '%s' "$s"
    else
        printf '%s...' "${s:0:$((maxlen - 3))}"
    fi
}

# truncate_path <ruta> <maxlen>
#
# Como truncate_target pero conservando la COLA, con el prefijo "..." al
# principio. El agente reporta rutas absolutas, y en este repo el prefijo
# comun se come el ancho entero de un pane estrecho: truncar por el final
# deja `/Users/augusto-romero-arango/Codigo/Sincosof...` en toda linea de
# Read/Edit/Write -- sin el nombre del archivo, que es justo la unica parte
# informativa y la que sostiene la señal de repeticion de CA-4.
truncate_path() {
    local s="$1" maxlen="$2"
    [ "$maxlen" -lt 4 ] 2>/dev/null && maxlen=4
    local len=${#s}
    if [ "$len" -le "$maxlen" ]; then
        printf '%s' "$s"
    else
        printf '...%s' "${s:$((len - maxlen + 3))}"
    fi
}

# fmt_time_hhmmss <epoch_ms>
#
# Formatea un timestamp epoch-en-milisegundos (el que produce epoch_ms del
# filtro jq) como hora local HH:MM:SS. "--:--:--" si <epoch_ms> falta
# (is_missing: evento sin `.timestamp` parseable). `date -r` es la forma BSD
# (macOS, el entorno del harness); el segundo intento cubre el `date` de GNU
# por si el visor se corre en Linux.
fmt_time_hhmmss() {
    local ems="$1"
    if is_missing "$ems"; then
        echo "--:--:--"
        return 0
    fi
    local secs=$((ems / 1000))
    date -r "$secs" +%H:%M:%S 2>/dev/null \
        || date -d "@$secs" +%H:%M:%S 2>/dev/null \
        || echo "--:--:--"
}

# fmt_delta_s <prev_epoch_ms> <epoch_ms>
#
# Formatea el delta "+N.Ns" desde la accion anterior -- el reloj que revela
# los round-trips de ~20s (CA-2). "-" si no hay accion anterior en el stage
# actual (primer render tras un cambio de stream) o si falta algun operando.
fmt_delta_s() {
    local prev="$1" ems="$2"
    if is_missing "$prev" || is_missing "$ems"; then
        printf '%7s' "-"
        return 0
    fi
    awk -v a="$prev" -v b="$ems" 'BEGIN{d=(b-a)/1000; printf "+%5.1fs", d}'
}

# ms_to_s <milisegundos>
#
# Milisegundos a segundos con un decimal ("?" si el campo viene ausente).
ms_to_s() {
    local ms="$1"
    if is_missing "$ms"; then
        echo "?"
        return 0
    fi
    awk -v v="$ms" 'BEGIN{printf "%.1f", v/1000}'
}

# touch_count <touched_file> <target>
#
# Marca un toque sobre <target> en <touched_file> (una linea por toque,
# CA-4) y devuelve por stdout cuantas veces (incluido este) se toco ese
# mismo objetivo dentro del stage actual. <touched_file> se trunca a vacio
# cada vez que el bucle principal cambia de stream (nueva corrida = nuevo
# stage = contador en cero). Solo se llama para herramientas con un archivo
# como objetivo (Read/Edit/Write/NotebookEdit) -- CA-4 senala explicitamente
# que la repeticion de un mismo comando Bash NO se detecta (es rarisima
# medida contra 108 writers; la señal barata esta en el patron sobre el
# mismo archivo).
touch_count() {
    local touched_file="$1" target="$2"
    local count
    count=$(grep -c -F -x -- "$target" "$touched_file" 2>/dev/null)
    count=$((count + 1))
    printf '%s\n' "$target" >> "$touched_file"
    echo "$count"
}

# render_result_summary <hora> <turnos> <duration_ms> <duration_api_ms> <cost_usd> <is_error>
#
# Imprime el cierre de stage de CA-5: turnos, costo y duracion total
# desglosada en API vs no-API. No termina el proceso -- el bucle principal
# sigue esperando el siguiente stream.
render_result_summary() {
    local now_str="$1" turns="$2" duration_ms="$3" duration_api_ms="$4" cost_usd="$5" is_error="$6"

    local dur_s dur_api_s dur_nonapi_s
    dur_s=$(ms_to_s "$duration_ms")
    dur_api_s=$(ms_to_s "$duration_api_ms")
    if ! is_missing "$duration_ms" && ! is_missing "$duration_api_ms"; then
        dur_nonapi_s=$(awk -v a="$duration_ms" -v b="$duration_api_ms" 'BEGIN{printf "%.1f", (a-b)/1000}')
    else
        dur_nonapi_s="?"
    fi

    local estado="${GREEN}OK${NC}"
    [ "$is_error" = "true" ] && estado="${RED}ERROR${NC}"

    local turns_disp="$turns"
    is_missing "$turns_disp" && turns_disp="?"
    local cost_disp="$cost_usd"
    is_missing "$cost_disp" && cost_disp="?"

    echo ""
    printf '%b\n' "${GREEN}${BOLD}--- cierre de stage [${now_str}] (${estado}${GREEN}${BOLD}) ---${NC}"
    printf 'turnos=%s  costo_usd=%s  duracion=%ss (api=%ss, no-api=%ss)\n' \
        "$turns_disp" "$cost_disp" "$dur_s" "$dur_api_s" "$dur_nonapi_s"
    printf '%b\n' "${GREEN}${BOLD}Esperando el siguiente stream...${NC}"
    echo ""
}

# render_row <kind> <epoch_ms> <a> <b> <c> <d> <e>
#
# Renderiza una fila TSV ya producida por el filtro jq (write_jq_filter):
#   kind=tool   -> a=nombre, b=objetivo aplanado, c=ruta (si es tool de archivo, "-" si no)
#   kind=text   -> a=sabor del turno sin tool call ("texto" o "pensamiento")
#   kind=result -> a=turnos, b=duration_ms, c=duration_api_ms, d=cost_usd, e=is_error
#
# Todo campo ausente llega como el placeholder "-" del filtro (is_missing).
#
# Actualiza PREV_EMS (delta de la proxima accion) y, para tools de archivo,
# marca la repeticion via touch_count sobre TOUCHED_FILE (CA-4).
render_row() {
    local kind="$1" ems="$2" a="$3" b="$4" c="$5" d="$6" e="$7"

    if [ "$kind" = "result" ]; then
        # El evento `result` del CLI no trae `.timestamp` (verificado contra
        # las trazas reales), asi que el reloj del cierre es el de la ultima
        # accion vista. Es la hora honesta en los dos modos de uso: en vivo
        # coincide con "ahora", y sobre un stream pasado no inventa el
        # momento en que se corrio el visor.
        local close_ems="$ems"
        is_missing "$close_ems" && close_ems="$PREV_EMS"
        render_result_summary "$(fmt_time_hhmmss "$close_ems")" "$a" "$b" "$c" "$d" "$e"
        PREV_EMS=""
        return 0
    fi

    local now_str delta_str
    now_str=$(fmt_time_hhmmss "$ems")
    delta_str=$(fmt_delta_s "$PREV_EMS" "$ems")

    case "$kind" in
        text)
            local etiqueta="(razonamiento, sin tool call)"
            [ "$a" = "texto" ] && etiqueta="(mensaje de texto, sin tool call)"
            printf '%b\n' "${BLUE}[${now_str}]${NC} ${delta_str}  ${YELLOW}${etiqueta}${NC}"
            ;;
        tool)
            local name="$a" target="$b" file_target="$c"
            local suffix=""
            if ! is_missing "$file_target"; then
                local count
                count=$(touch_count "$TOUCHED_FILE" "$file_target")
                [ "$count" -gt 1 ] && suffix="  ${YELLOW}(x${count})${NC}"
            fi
            local prefix_plain="[${now_str}] ${delta_str}  ${name} "
            local budget=$(( $(pane_width) - ${#prefix_plain} - 8 ))
            [ "$budget" -lt 10 ] && budget=10
            local shown
            if is_missing "$file_target"; then
                shown=$(truncate_target "$target" "$budget")
            else
                shown=$(truncate_path "$target" "$budget")
            fi
            printf '%b\n' "${BLUE}[${now_str}]${NC} ${delta_str}  ${BOLD}${name}${NC} ${shown}${suffix}"
            ;;
    esac

    PREV_EMS="$ems"
}

# process_new_lines <stream_file>
#
# Un ciclo de lectura incremental (CA-1/CA-2): emite con
# `sed -n "$((LAST_LINE+1)),\$p"` las lineas nuevas desde la ultima vez,
# parsea cada una con el filtro jq y renderiza sus filas via render_row.
#
# Tolerancia de CA-6: si una linea no parsea (jq exit != 0 -- lectura pillada
# a mitad de escritura del proceso productor), NO avanza LAST_LINE mas alla
# de ella y corta el resto del lote: esa linea (y cualquiera despues) se
# reintenta en el proximo ciclo, cuando ya este completa. Una linea vacia se
# cuenta como consumida sin renderizar nada.
process_new_lines() {
    local stream="$1"
    [ -f "$stream" ] || return 0

    local new_content
    new_content=$(sed -n "$((LAST_LINE + 1)),\$p" "$stream" 2>/dev/null)
    [ -z "$new_content" ] && return 0

    local line_num=$LAST_LINE
    local line rows rc
    while IFS= read -r line; do
        line_num=$((line_num + 1))

        if [ -z "$line" ]; then
            LAST_LINE=$line_num
            continue
        fi

        rows=$(printf '%s' "$line" | jq -r -f "$JQ_FILTER_PATH" 2>/dev/null)
        rc=$?

        if [ "$rc" -ne 0 ]; then
            break
        fi

        LAST_LINE=$line_num

        [ -z "$rows" ] && continue

        while IFS=$'\t' read -r kind ems a b c d e; do
            [ -z "$kind" ] && continue
            render_row "$kind" "$ems" "$a" "$b" "$c" "$d" "$e"
        done <<< "$rows"
    done <<< "$new_content"

    return 0
}

# main [<ruta-al-stream>]
#
# Bucle principal (CA-1/CA-5/CA-6): sin argumentos descubre y sigue el stream
# mas reciente, cambiando de stream cuando aparece uno mas nuevo; con un
# argumento seguido/inspecciona esa ruta fija sin descubrir otras. Nunca
# termina por si solo (Ctrl-C lo corta limpiamente via el trap de EXIT/INT/TERM,
# que borra el directorio temporal propio -- CA-6, "solo lectura y aislado").
main() {
    local pinned_path=""
    if [ $# -gt 0 ]; then
        pinned_path="$1"
        if [ ! -f "$pinned_path" ]; then
            echo "ERROR: no existe el stream indicado: $pinned_path" >&2
            return 1
        fi
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: este visor requiere jq (no encontrado en PATH). Instalalo (p.ej. 'brew install jq') y reintenta." >&2
        return 1
    fi

    TMP_STATE=$(mktemp -d "${TMPDIR:-/tmp}/mefisto-stream-watch.XXXXXX") || return 1
    trap 'rm -rf "$TMP_STATE"' EXIT
    trap 'rm -rf "$TMP_STATE"; exit 130' INT TERM

    TOUCHED_FILE="$TMP_STATE/touched.txt"
    : > "$TOUCHED_FILE"
    JQ_FILTER_PATH="$TMP_STATE/filter.jq"
    write_jq_filter "$JQ_FILTER_PATH"

    LAST_LINE=0
    PREV_EMS=""
    CURRENT_STREAM=""

    printf '%b\n' "${CYAN}${BOLD}Mefisto -- visor en vivo del stream de acciones (issue #434)${NC}"
    if [ -n "$pinned_path" ]; then
        echo "Inspeccionando: $pinned_path"
    else
        echo "Descubriendo el stream mas reciente en $LOG_DIR ..."
        # El pipeline escribe sus logs bajo la raiz desde la que se lanzo, no
        # dentro del worktree del issue: si el directorio no existe, el visor
        # se quedaria esperando en silencio para siempre -- exactamente el
        # sintoma que este issue viene a eliminar. Se avisa y se sigue
        # esperando (el directorio aparece en cuanto arranca un pipeline).
        if [ ! -d "$LOG_DIR" ]; then
            printf '%b\n' "${YELLOW}Aviso: $LOG_DIR todavia no existe. Se creara cuando arranque un pipeline;${NC}"
            printf '%b\n' "${YELLOW}si esperabas una corrida en curso, lanza el visor desde la raiz del repo principal.${NC}"
        fi
    fi
    echo ""

    while true; do
        local stream
        if [ -n "$pinned_path" ]; then
            stream="$pinned_path"
        else
            stream=$(discover_stream "$LOG_DIR")
        fi

        if [ -n "$stream" ] && [ "$stream" != "$CURRENT_STREAM" ]; then
            CURRENT_STREAM="$stream"
            LAST_LINE=0
            PREV_EMS=""
            : > "$TOUCHED_FILE"
            echo ""
            parse_stream_header "$CURRENT_STREAM"
            echo ""
        fi

        [ -n "$CURRENT_STREAM" ] && process_new_lines "$CURRENT_STREAM"

        sleep "$POLL_INTERVAL"
    done
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
