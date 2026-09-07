# runtime-opencode.jq -- Traduccion de la traza `--format json` cruda de
# OpenCode al JSONL neutral (MEF-ADR-0049, issue #860). Programa jq invocado
# desde runtime_opencode_translate (runtime-opencode.sh) con `-R -s` (el
# stream crudo entero como un unico string), `--arg runtime`,
# `--arg model_param`, `--arg exit_code` (exit code del proceso, "" si el
# caller no lo conoce) y `--rawfile stderr_text` (stderr crudo del proceso,
# "" si no hubo).
#
# Wire format (verificado con OpenCode 1.18.29, 2026-09-05, capturas reales
# congeladas en .claude/scripts/tests/fixtures/runtime-opencode/*-1.18.29.jsonl):
# una linea JSON compacta por evento, SIEMPRE con `.type`, `.timestamp` (epoch
# ms, NUNCA un string ISO) y `.sessionID` de nivel superior. Tipos observados:
#   - `step_start` / `step_finish`: limites de un paso de razonamiento.
#     `step_finish.part.tokens{input,output,...}` y `.part.cost` son la unica
#     fuente de metricas -- no hay un evento "result" unico como en Claude, y
#     cada `step_finish` reporta lo de SU paso, asi que el terminal los suma
#     (ver el bloque `$steps` mas abajo).
#   - `text`: `.part.text` es un fragmento de texto visible del asistente.
#   - `tool_use`: `.part.tool` (nombre), `.part.callID`, `.part.state.status`
#     ("completed"/"error", nunca observado en "pending"/"running" en las dos
#     capturas de referencia -- una corrida trivial y una con `bash sleep 2`)
#     y `.part.state.time{start,end}` (epoch ms). A diferencia de Claude
#     (`tool_use` + `tool_result` como DOS bloques separados que se emparejan
#     por id), OpenCode emite el ciclo de vida completo de la tool call en
#     UN SOLO evento ya resuelto: este programa sintetiza tool.started +
#     tool.completed a partir de esa unica linea en vez de emparejar por
#     `callID` contra un segundo evento que esta version del CLI no emite.
#     `input_summary` de `tool.started` (issue #863) se llena desde
#     `.part.state.input`: `.filePath` para los tools de archivo (`edit`,
#     `write`, `read` -- verificado en la captura de `read` con
#     `state.status:"error"` de test-runtime-opencode.sh, que trae
#     `input.filePath`), primeros 80 caracteres de `.command` para `bash`
#     (asumido por el esquema publico de la tool `bash` de OpenCode -- ningun
#     fixture congelado todavia captura una tool call de bash resuelta; si el
#     dogfooding, #874, revela un campo distinto, se corrige aqui y se agrega
#     el fixture que falta). Cualquier otro tool (p. ej. `glob`) deja
#     `input_summary` en `null`: nunca se inventa un resumen que el evento no
#     trae.
#   - `error`: evento de fallo a nivel de proceso (observado con un `-m`
#     invalido: `{"type":"error","error":{"name":...,"data":{"message":...}}}`,
#     exit 1, SIN nada por stderr). Deliberadamente NO se usa para clasificar
#     ni para `error.detail` (CA-3 de #860 solo autoriza stderr como fuente de
#     detalle): mezclar dos fuentes de verdad para el mismo campo haria el
#     detalle dependiente del orden en que a alguien se le ocurra mirarlas.
#     Se cuenta igual que cualquier tipo no traducido (ver `$raw_ignored`).
#
# Ningun evento trae un id de modelo (ni init, ni el mensaje, ni el step):
# a diferencia de runtime-claude.jq, `model` del terminal SIEMPRE degrada a
# `model_param` (lo que el runner pidio), nunca a una senal del wire format
# porque esa senal no existe en esta version del CLI.
#
# Clasificacion (CA-3 de #860), en el ORDEN LITERAL en que los enumera el
# issue -- la unica ambiguedad real es cuando dos condiciones coinciden (exit
# no-cero simultaneo con stream vacio o con una linea no-JSON), y ese orden
# ya la resuelve: un exit no-cero conocido eclipsa la clasificacion mas fina,
# igual que un CLI que muere no necesita ademas explicar POR QUE su stream
# quedo raro.
#   1. exit == 0 (conocido) y al menos un `message` de texto visible -> success.
#   2. exit != 0 (conocido): si stderr trae una senal textual de limite de
#      uso/rate limit -> failed{error.kind:rate_limit, resets_at:null}
#      (issue #965; patron CONSERVADOR y no un campo estructurado: a
#      diferencia de Claude Code, ningun transcript ni documentacion oficial
#      de OpenCode confirma un evento equivalente a `rate_limit_event` -- ver
#      anomalyco/opencode#42029, que solo muestra el mensaje suelto `Error:
#      429: {"type":"FreeUsageLimitError","message":"...Rate limit
#      exceeded..."}` por stderr/consola, y #8203, donde versiones viejas del
#      CLI ni siquiera llegaban a salir con exit != 0 ante un 429 -- se
#      quedaban colgadas. `resets_at` queda SIEMPRE null aqui: sin campo
#      estructurado no hay de donde derivarlo; la politica de espera pierde
#      la optimizacion de dormir exactamente hasta el reset y sondea en su
#      lugar). En cualquier otro caso -> failed{error.kind:nonzero_exit}, con
#      las ULTIMAS lineas de stderr como detalle (nunca el evento `error` del
#      propio stdout, ver arriba). Sin stderr, el detalle nombra el exit code.
#   3. TIMEOUT no se clasifica aqui: lo sintetiza mefisto-run-agent.sh con el
#      reloj de pared que envuelve la invocacion completa (ver
#      src/internal/contract/README.md, "Exactamente un evento terminal").
#   4. Stream vacio (cero lineas no vacias, incluido exit desconocido) ->
#      failed{error.kind:no_result}.
#   5. Alguna linea no vacia que no parseo como objeto JSON -> failed
#      {error.kind:protocol_invalid}, citando esa linea (recortada a 300
#      caracteres) en el detalle.
#   6. Cualquier otro caso (tipicamente exit 0 sin ningun texto visible, o
#      exit desconocido sin texto) -> failed{error.kind:no_result}.
#
# `raw_ignored` (CA-2): todo `.type` fuera de {text, tool_use, step_start,
# step_finish, error} se descarta EN SILENCIO del JSONL neutral -- nunca
# aborta, nunca se confunde con un evento reconocido. Su cardinalidad se
# cuenta y se imprime por el propio stderr de este programa jq via `debug`
# (diagnostico puro): run-events.schema.json fija
# `additionalProperties:false` con la lista exacta de campos de
# `run.completed`/`run.failed` y este issue NO lo modifica (ver "Impacto en
# archivos" de #860), asi que un campo `raw_ignored` en el JSONL que sí lee un
# pipeline violaria el contrato congelado -- por eso vive SOLO en el canal de
# diagnostico, que runtime_opencode_translate silencia con `2>/dev/null` en
# produccion (igual que runtime-claude.sh), y que solo se ve invocando el
# programa a mano sin esa redireccion.
#
# `duration_ms` del terminal SIEMPRE null aqui: mefisto-run-agent.sh lo
# sobreescribe con el reloj de pared que mide el runner (mismo contrato que
# runtime-claude.jq y runtime-fake.sh).
#
# Bash 3.2 + jq 1.7 (MEF-ADR-0049 CA-6): sin arrays asociativos.

def ms_to_iso:
    if . == null then null
    else (. / 1000 | todate)
    end;

# Los detalles de error viajan a un JSONL que se lee en terminal: una linea
# de varios KB no aporta nada por encima de su encabezado y si arruina la
# legibilidad de todo el log neutral (mismo criterio que runtime-claude.jq).
def clip: if . == null then null else (tostring | .[0:300]) end;

# input_summary de un tool_use (issue #863): ver comentario de cabecera sobre
# `.part.state.input`. Nunca se inventa un resumen para un tool sin mapeo.
def opencode_input_summary($tool; $input):
    if ($tool == "edit" or $tool == "write" or $tool == "read") then ($input.filePath // null)
    elif ($tool == "bash") then (($input.command // null) | if . == null then null else (tostring | .[0:80]) end)
    else null end;

(now | todate) as $fallback_ts
| ($model_param | if . == "" then null else . end) as $model_param_or_null
| ($exit_code | if . == "" then null else (tonumber? // null) end) as $exit

| (split("\n")) as $lines
| ($lines | map(select(length > 0))) as $raw_lines
| ($raw_lines | length) as $raw_line_count
| ($raw_lines | map({line: ., parsed: (try fromjson catch null)})) as $attempts
| ($attempts | map(select(.parsed == null or (.parsed | type) != "object"))) as $bad_lines
| ($attempts | map(select(.parsed != null and (.parsed | type) == "object") | .parsed)) as $events
# Metricas del terminal (CA-4): OpenCode no emite un evento "result" unico con
# el acumulado de la corrida -- cada `step_finish` reporta lo de SU paso (en la
# captura de referencia con tool call: input 6127+6167, output 17+10, cada uno
# su propio `cost`). El terminal por lo tanto SUMA todos los `step_finish`, no
# toma el ultimo: cada paso es una llamada facturada aparte, y quedarse con el
# ultimo reportaria el costo del cierre de la corrida como si fuera el de la
# corrida entera -- un sesgo que mefisto-metrics-report.sh propaga directo a
# `cost_usd_total`/`cost_usd_mean`. `add` sobre una lista vacia o toda-null
# devuelve null, que es exactamente lo que CA-4 pide cuando el wire format no
# trae el dato (nunca un cero fabricado).
| ($events | map(select(.type == "step_finish"))) as $steps

| ($stderr_text | split("\n") | map(select(length > 0))) as $stderr_lines
| ($stderr_lines | (if length > 5 then .[-5:] else . end) | join("\n") | clip) as $stderr_tail

# Ventana de uso agotada (issue #965): ver comentario de cabecera, punto 2.
# Patron textual conservador sobre TODO el stderr (no solo $stderr_tail, que
# puede recortar la linea relevante si el proceso escribio ruido despues):
# busca a la vez un indicio de codigo 429 y de "rate limit" -- exigir ambos
# evita que un 4xx no relacionado (que tambien puede traer un 429 propio de
# OTRO significado) o un mensaje generico que solo mencione "limit" disparen
# un falso positivo.
| ($stderr_lines | join("\n")) as $stderr_joined
| ($stderr_joined | test("429")
    and ($stderr_joined | test("rate.?limit|usage.?limit"; "i"))) as $stderr_rate_limit_signal

# Diagnostico de tipos no reconocidos (CA-2): ver comentario de cabecera.
# `IN(...)` y no `[.type] | inside([...])`: `inside` compara strings por
# SUBCADENA, asi que un tipo futuro como "step" o "tool" (subcadena de
# "step_start"/"tool_use") se contaria como reconocido y `raw_ignored`
# quedaria por debajo de lo que realmente se descarto -- justo el numero que
# este diagnostico existe para no falsear.
| ($events | map(select(.type | IN("text", "tool_use", "step_start", "step_finish", "error") | not)) | length) as $raw_ignored
| (if $raw_ignored > 0
   then ($raw_ignored | debug("runtime-opencode.jq: raw_ignored=" + ($raw_ignored | tostring)))
   else $raw_ignored end) as $_raw_ignored_diag

| [
    $events[] | . as $ev
    | if ($ev.type == "text") then
          ($ev.part.text // "") as $txt
          | select($txt != "")
          | {v: 1, type: "message", ts: (($ev.timestamp | ms_to_iso) // $fallback_ts), role: "assistant", text: $txt}
      elif ($ev.type == "tool_use") then
          ($ev.part.tool // "?") as $tool
          | ($ev.part.state.status // "") as $status
          | ($ev.part.state.input // {}) as $input
          | ($ev.part.state.time.start) as $start_raw
          | ($ev.part.state.time.end) as $end_raw
          | ($ev.timestamp | ms_to_iso) as $ev_ts
          | (
              {
                v: 1, type: "tool.started",
                ts: (($start_raw | ms_to_iso) // $ev_ts // $fallback_ts),
                tool: $tool, input_summary: (opencode_input_summary($tool; $input))
              },
              (
                if ($status == "completed" or $status == "error") then
                    {
                      v: 1, type: "tool.completed",
                      ts: (($end_raw | ms_to_iso) // $ev_ts // $fallback_ts),
                      tool: $tool,
                      ok: ($status != "error"),
                      duration_ms: (if ($start_raw != null and $end_raw != null) then ($end_raw - $start_raw) else null end)
                    }
                else empty end
              )
            )
      else empty end
  ] as $translated_events

| ($raw_line_count == 0) as $stream_empty
| (($bad_lines | length) > 0) as $has_malformed
| ($exit != null and $exit != 0) as $nonzero
| (($translated_events | map(select(.type == "message")) | length) > 0) as $has_text

| (
    if ($exit == 0 and $has_text) then
        { status: "success", error_kind: null, error_detail: null }
    elif ($nonzero and $stderr_rate_limit_signal) then
        {
          status: "failed", error_kind: "rate_limit",
          error_detail: (
              if ($stderr_tail // "") != "" then $stderr_tail
              else "el proceso de OpenCode aviso un limite de uso (exit " + ($exit | tostring) + ") sin mas detalle por stderr"
              end
          )
        }
    elif $nonzero then
        {
          status: "failed", error_kind: "nonzero_exit",
          error_detail: (
              if ($stderr_tail // "") != "" then $stderr_tail
              else "el proceso de OpenCode termino con exit " + ($exit | tostring) + " sin nada por stderr"
              end
          )
        }
    elif $stream_empty then
        { status: "failed", error_kind: "no_result", error_detail: "el stream de OpenCode no emitio ninguna linea" }
    elif $has_malformed then
        {
          status: "failed", error_kind: "protocol_invalid",
          error_detail: ("el stream de OpenCode incluyo una linea que no parseo como objeto JSON: " + ($bad_lines[0].line | clip))
        }
    else
        {
          status: "failed", error_kind: "no_result",
          error_detail: (
              if $exit == 0 then "el proceso de OpenCode termino con exit 0 pero el stream no incluyo ningun texto visible del asistente"
              else "el stream de OpenCode no incluyo ningun texto visible del asistente (exit code desconocido)"
              end
          )
        }
    end
  ) as $verdict

| {
    v: 1,
    type: (if $verdict.status == "success" then "run.completed" else "run.failed" end),
    ts: $fallback_ts,
    status: $verdict.status,
    runtime: $runtime,
    model: $model_param_or_null,
    session_id: (($events | map(.sessionID) | map(select(. != null)) | first) // null),
    duration_ms: null,
    tokens: {
        input: ($steps | map(.part.tokens.input) | add),
        output: ($steps | map(.part.tokens.output) | add)
    },
    cost_usd: ($steps | map(.part.cost) | add),
    turns: null,
    denials: null,
    ttft_ms: null,
    api_duration_ms: null,
    error: (if $verdict.error_kind == null then null else {kind: $verdict.error_kind, detail: $verdict.error_detail} end),
    resets_at: null
  } as $terminal

| $translated_events[], $terminal
