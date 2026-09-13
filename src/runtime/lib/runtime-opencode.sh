#!/usr/bin/env bash
# runtime-opencode.sh -- Adaptador de runtime OpenCode (MEF-ADR-0049, issue
# #860). Unico lugar del repo (fuera de tests/fixtures/shims generados) que
# compone la invocacion `opencode run` y traduce su `--format json` ("raw
# JSON events", verificado en OpenCode 1.18.29) al JSONL neutral de
# src/runtime/contract/run-events.schema.json -- ver
# src/runtime/contract/README.md.
#
# OpenCode es el runtime del dogfooding interno (MEF-ADR-0049 CA-5, #851):
# ningun otro archivo del harness debe nombrar `opencode`, `--agent`, `--auto`
# ni `--format json` -- eso vive aqui. Autenticacion/credenciales (el
# almacen de credenciales local de OpenCode, OAuth de proveedor) son
# responsabilidad EXCLUSIVA de OpenCode: este adaptador no los lee, copia,
# valida ni menciona (CA-5 de #860, verificado por
# .claude/scripts/tests/test-runtime-opencode.sh seccion [E]: ni la ruta de
# ese almacen ni ninguna variable de API key de proveedor aparecen en este
# archivo ni en runtime-opencode.jq) -- la disponibilidad del provider la
# valida OpenCode al ejecutar, no Mefisto.
#
# Implementa la interfaz de funciones que todo adaptador de runtime debe
# exponer (ver src/runtime/contract/README.md, "Interfaz de adaptador"):
#   runtime_opencode_build_cmd <agent> <cwd> <prompt_file> <model> <system_file>
#                              [<resume_session_id>]
#     Rellena MEFISTO_RUNTIME_CMD con el argv de `opencode run` (sin `eval`,
#     paridad con run_agent_with_watchdog): el mensaje viaja como UN elemento
#     del array bash, sin volver a interpretarse. A diferencia de
#     runtime-claude.sh, aqui <agent> y <cwd> SI participan del argv
#     (`--agent <id> --dir <cwd>`) porque `opencode run` los exige como flags
#     propios -- `run_agent_with_watchdog` sigue haciendo `cd "$workdir"`
#     antes de invocar, pero OpenCode ademas necesita que se le diga
#     explicitamente donde correr (CA-1). <resume_session_id> (issue #968,
#     CA-1/CA-2) es OPCIONAL y opaco -- vacio/ausente = comportamiento
#     identico a antes de #968 (sin `--session` en el argv); no vacio agrega
#     `--session <id>` (verificado en `opencode run --help` local). `--fork`
#     queda deliberadamente sin usar: reusar el id original mantiene la
#     trazabilidad del stage en un solo transcript (notas tecnicas de #968).
#   runtime_opencode_translate <raw_file> <runtime_id> <model>
#                              [<exit_code>] [<stderr_file>]
#     Delega en runtime-opencode.jq (`jq -R -s -c`, mismo idiom que
#     runtime-claude.sh). Nunca emite `run.started` -- eso lo hace
#     mefisto-run-agent.sh directo (issue #858).
#     A diferencia de Claude Code, el wire format de OpenCode no trae ninguna
#     senal propia de exito/fallo (no hay equivalente a `is_error`/`subtype`/
#     `stop_reason`): la clasificacion completa de CA-3 depende del exit code
#     y del stderr crudo que este runner SIEMPRE pasa (ver
#     src/runtime/contract/README.md, "Interfaz de adaptador"), asi que los
#     dos ultimos argumentos son mucho mas centrales aqui que en el adaptador
#     Claude Code.
#
# Flags que compone build_cmd (CA-1): `--agent <agent> --dir <cwd> --format
# json --auto` siempre; `-m <model>` solo si el runner entrego un modelo no
# vacio (heredar = el CLI real nunca ve un `-m` vacio); el mensaje final es
# SIEMPRE el ultimo elemento del argv. `--auto` ("auto-approve permissions
# that are not explicitly denied") es el UNICO flag de permisos que este
# adaptador conoce -- la politica deny-por-defecto la genera #862 en el
# frontmatter del agente, nunca este archivo.
#
# `--system-file` no tiene flag equivalente en `opencode run` (verificado:
# `opencode run --help` no lista nada parecido a `--append-system-prompt`):
# se inyecta como PREFIJO del mensaje ("$system\n\n$prompt"), paridad con
# `claude -p "$prompt"` en que el prompt completo viaja como un unico
# argumento posicional, nunca como flag.
#
# El valor de <model> es OPACO para este adaptador (CA-1): viaja tal cual a
# `-m`, con `/`, `.`, `-` o espacios, sin interpretarlo ni validarlo -- la
# disponibilidad real del provider/modelo la resuelve OpenCode al ejecutar.
#
# Bash 3.2 (macOS): sin arrays asociativos, sin novedades de bash 4+.

runtime_opencode_is_available() {
    command -v opencode >/dev/null 2>&1
}

runtime_opencode_default_model() {
    case "$1" in
        fast) printf '%s' "openai/gpt-5.6-luna" ;;
        balanced) printf '%s' "openai/gpt-5.6-terra" ;;
        deep) printf '%s' "openai/gpt-5.6-sol" ;;
        *) return 1 ;;
    esac
}

# --- Catalogo de tarifas Models.dev ------------------------------------------
#
# La estimacion es telemetria auxiliar: este adaptador conserva una copia
# validada, propia de Mefisto, sin consultar el estado ni las credenciales de
# OpenCode (MEF-ADR-0054 secciones 3 y 4). La integracion que traduce pasos y
# calcula el importe consume la ruta global que deja esta preparacion.
RUNTIME_OPENCODE_PRICING_URL="https://models.opencode.ai/api.json"
MEFISTO_OPENCODE_PRICING_CATALOG=""

runtime_opencode_pricing_cache_is_valid() {
    local cache="$1"
    [ -s "$cache" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1

    jq -e '
        def price: type == "number" and isfinite and . >= 0;
        def price_set: (.input | price) and (.output | price)
          and (.cache_read | price) and (.cache_write | price);
        type == "object" and .schema == 1
        and (.source_url == "https://models.opencode.ai/api.json")
        and (.validated_utc | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
        and (.models | type == "object" and length > 0)
        and all(.models | to_entries[];
            (.key | test("^[^/]+/.+$"))
            and (.value | type == "object" and price_set)
            and ((.value.context == null) or (.value.context | price))
            and (.value.tiers | type == "array")
            and all(.value.tiers[];
                type == "object" and (.context | price) and price_set))
    ' "$cache" >/dev/null 2>&1
}

# runtime_opencode_prepare_pricing
#
# Imprime la ruta de la ultima cache valida (o nada si no existe) y retorna
# siempre cero. El marker de intento se escribe bajo el lock ANTES de curl:
# incluso una descarga fallida queda acotada a una por dia UTC.
runtime_opencode_prepare_pricing() {
    MEFISTO_OPENCODE_PRICING_CATALOG=""
    [ -n "${MEFISTO_STATE_DIR:-}" ] || return 0

    local cache_dir cache_file attempt_file lock_dir today tmp fetched=false lock_owned=false
    cache_dir="$MEFISTO_STATE_DIR/cache/model-pricing"
    cache_file="$cache_dir/catalog.json"
    attempt_file="$cache_dir/attempted-utc"
    lock_dir="$cache_dir/.refresh.lock"
    today="$(date -u +%Y-%m-%d 2>/dev/null)"
    [ -n "$today" ] || return 0
    mkdir -p "$cache_dir" 2>/dev/null || {
        echo "AVISO: no se pudo preparar la cache de tarifas de OpenCode; se omite la estimacion." >&2
        return 0
    }

    # Un proceso que no obtiene el lock espera brevemente al que refresca: asi
    # dos pipelines simultaneos comparten su resultado, sin que el segundo haga
    # otra consulta. Un lock abandonado solo degrada a la ultima cache valida.
    if mkdir "$lock_dir" 2>/dev/null; then
        lock_owned=true
    else
        local wait_count=0
        while [ -d "$lock_dir" ] && [ "$wait_count" -lt 200 ]; do
            sleep 0.05
            wait_count=$((wait_count + 1))
        done
    fi

    if [ "$lock_owned" = "false" ]; then
        # El propietario puede haber terminado mientras esperabamos; intentar
        # adquirir una vez evita escribir sin lock si acaba de liberarlo.
        if mkdir "$lock_dir" 2>/dev/null; then
            lock_owned=true
        else
            if runtime_opencode_pricing_cache_is_valid "$cache_file"; then
                MEFISTO_OPENCODE_PRICING_CATALOG="$cache_file"
                printf '%s\n' "$cache_file"
            else
                echo "AVISO: el catalogo de tarifas de OpenCode no esta disponible; se omite la estimacion." >&2
            fi
            return 0
        fi
    fi

    # Somos propietarios del lock. Revalidar fecha dentro de la seccion critica
    # es lo que hace efectiva la cota diaria bajo concurrencia.
    if [ -f "$attempt_file" ] && [ "$(cat "$attempt_file" 2>/dev/null)" = "$today" ]; then
        :
    elif runtime_opencode_pricing_cache_is_valid "$cache_file" \
        && [ "$(jq -r '.validated_utc' "$cache_file" 2>/dev/null)" = "$today" ]; then
        : > "$attempt_file"
        printf '%s\n' "$today" > "$attempt_file"
    else
        printf '%s\n' "$today" > "$attempt_file"
        tmp="$(mktemp "$cache_dir/.catalog.XXXXXX" 2>/dev/null)"
        if [ -n "$tmp" ] && command -v curl >/dev/null 2>&1 \
            && curl --fail --silent --show-error --location "$RUNTIME_OPENCODE_PRICING_URL" > "$tmp" 2>/dev/null \
            && jq -e --arg day "$today" '
                def price: type == "number" and isfinite and . >= 0;
                def cost: .cost // {};
                def tier_cost: (.cost // .);
                {
                  schema: 1, source_url: "https://models.opencode.ai/api.json", validated_utc: $day,
                  models: [
                    .providers | to_entries[] as $provider
                    | $provider.value.models | to_entries[] as $model
                    | ($model.value.cost // {}) as $base
                    | {
                        key: ($provider.key + "/" + $model.key),
                        value: {
                          input: $base.input, output: $base.output,
                          cache_read: $base.cache_read, cache_write: $base.cache_write,
                          context: ($model.value.limit.context // null),
                          tiers: [($base.tiers // $model.value.tiers // [])[]
                            | . as $tier_entry | ($tier_entry.cost // $tier_entry) as $tier
                            | {context: ($tier_entry.context // $tier_entry.limit.context), input: $tier.input,
                               output: $tier.output, cache_read: $tier.cache_read,
                               cache_write: $tier.cache_write}]
                        }
                      }
                  ] | from_entries
                }
            ' "$tmp" > "$tmp.normalized" 2>/dev/null \
            && runtime_opencode_pricing_cache_is_valid "$tmp.normalized"; then
            mv "$tmp.normalized" "$cache_file"
            fetched=true
        fi
        rm -f "$tmp" "$tmp.normalized" 2>/dev/null || true
    fi
    rmdir "$lock_dir" 2>/dev/null || true

    if runtime_opencode_pricing_cache_is_valid "$cache_file"; then
        MEFISTO_OPENCODE_PRICING_CATALOG="$cache_file"
        printf '%s\n' "$cache_file"
        if [ "$(jq -r '.validated_utc' "$cache_file" 2>/dev/null)" != "$today" ]; then
            echo "AVISO: se usa una cache de tarifas de OpenCode desactualizada." >&2
        fi
    else
        echo "AVISO: el catalogo de tarifas de OpenCode no esta disponible; se omite la estimacion." >&2
    fi
    return 0
}

# --- runtime_opencode_build_cmd ---------------------------------------------

runtime_opencode_build_cmd() {
    local agent="$1" cwd="$2" prompt_file="$3" model="$4" system_file="$5" resume_session_id="${6:-}"
    local prompt message

    prompt="$(cat "$prompt_file")"
    if [ -n "$system_file" ]; then
        message="$(cat "$system_file")"$'\n\n'"$prompt"
    else
        message="$prompt"
    fi

    MEFISTO_RUNTIME_CMD=(opencode run --agent "$agent" --dir "$cwd" --format json --auto)

    if [ -n "$model" ]; then
        MEFISTO_RUNTIME_CMD+=(-m "$model")
    fi

    if [ -n "$resume_session_id" ]; then
        MEFISTO_RUNTIME_CMD+=(--session "$resume_session_id")
    fi

    MEFISTO_RUNTIME_CMD+=("$message")
}

# runtime_opencode_supports_resume (issue #968, CA-4 caso b)
#
# OpenCode soporta reanudacion de sesion en modo headless via `-s/--session
# <id>` (con `--fork` opcional para bifurcar en vez de continuar la misma
# sesion, que este adaptador no usa) -- verificado en `opencode run --help`
# local. Retorna 0 siempre; consumida por `runtime_supports_resume`
# (mefisto-tooling-pipeline.sh) para decidir si el hold de #967 puede
# reanudar en vez de repetir el stage desde cero.
runtime_opencode_supports_resume() {
    return 0
}

# --- runtime_opencode_translate ----------------------------------------------

runtime_opencode_translate() {
    local raw_file="$1" runtime_id="$2" model="$3" exit_code="${4:-}" stderr_file="${5:-}"
    [ -f "$raw_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    local self_dir
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local jq_program="$self_dir/runtime-opencode.jq"
    [ -f "$jq_program" ] || return 0

    # `--rawfile` exige un archivo legible: sin stderr conocido se apunta a
    # /dev/null, que jq lee como cadena vacia (ningun patron casa y la
    # clasificacion cae en lo que el exit code/stream si permitan afirmar).
    local stderr_src="/dev/null"
    if [ -n "$stderr_file" ] && [ -f "$stderr_file" ]; then
        stderr_src="$stderr_file"
    fi

    jq -R -s -c \
        --arg runtime "$runtime_id" \
        --arg model_param "$model" \
        --arg exit_code "$exit_code" \
        --rawfile stderr_text "$stderr_src" \
        -f "$jq_program" \
        "$raw_file" 2>/dev/null
    return 0
}
