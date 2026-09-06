# runtime-claude.jq -- Traduccion de la traza stream-json cruda de Claude Code
# al JSONL neutral (MEF-ADR-0049 CA-1, issue #859). Programa jq invocado desde
# runtime_claude_translate (runtime-claude.sh) con `-R -s` (todo el archivo
# como un unico string) y `--arg runtime`/`--arg model_param`.
#
# Mapeo (CA-2): `assistant` con bloques `text` -> `message{role:"assistant"}`;
# bloques `tool_use` -> `tool.started{tool, input_summary:null}`; `user` con
# `tool_result` -> `tool.completed{tool, ok, duration_ms}` (tool resuelto por
# emparejamiento tool_use.id <-> tool_result.tool_use_id, mismo patron que
# compute_stage_metrics en _mefisto-common.sh); `result` -> terminal
# (run.completed/run.failed). El evento `system`/`init` NUNCA se re-emite como
# linea propia -- este adaptador jamas produce `run.started` (eso es
# responsabilidad exclusiva del runner, ver src/internal/contract/README.md,
# "Interfaz de adaptador"): solo se usa para extraer `session_id` y `model`,
# que via a parar al evento terminal (CA-4).
#
# `duration_ms` del terminal SIEMPRE null aqui: mefisto-run-agent.sh lo
# sobreescribe con el reloj de pared que mide el runner (unico dueno de ese
# dato), nunca un valor fabricado por el adaptador (mismo contrato que
# runtime-fake.sh).
#
# Clasificacion de fallo (CA-3), en el orden de classify_agent_failure
# (_mefisto-common.sh) hasta donde este archivo puede verlo -- SOLO tiene el
# stream de stdout (`raw_file`), nunca el exit code ni el stderr del proceso
# (la firma de runtime_<id>_translate, fijada por #858, no los recibe):
#   - `result.is_error==false` + `subtype=="success"` + `stop_reason==
#     "end_turn"` -> success. Verificado contra el CLI instalado (issue #425):
#     un 5xx/4xx real llega DENTRO del evento `result` (`api_error_status`),
#     nunca solo por stderr -- por eso alcanza con este evento para cubrir el
#     caso que de verdad ocurre.
#   - `result.is_error==true` -> api_error (detail con "API Error: <status>"
#     cuando el CLI trae `api_error_status`, mismo prefijo que ya leen
#     agent_log_has_stream_cut/classify_agent_failure).
#   - Sin evento `result` y la ultima linea no vacia del stream SI parseo como
#     JSON valido -> no_result (el proceso termino sin declarar nada).
#   - Sin evento `result` y la ultima linea no vacia NO parseo (corte a mitad
#     de escritura) -> stream_cut.
# `killed` (exit 137/143) queda fuera a proposito: sin el exit code en esta
# firma no hay como distinguirlo de `no_result` -- el exit code real de todos
# modos sobrevive como exit code del proceso completo (mefisto-run-agent.sh lo
# usa como FINAL_EXIT cuando el status no es "success"), asi que no se pierde
# informacion, solo la etiqueta mas especifica. Cerrar esa brecha es alcance
# de #869 (cuando el pipeline consuma este adaptador con mas contexto).

def parse_ts:
    if . == null or (type != "string") then null
    else
        ((capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.(?<frac>[0-9]+))?Z$")) // null) as $c
        | if $c == null then null
          else
              (($c.base + "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $sec
              | $sec * 1000 + (if $c.frac then (($c.frac + "000") | .[0:3] | tonumber) else 0 end)
          end
    end;

(now | todate) as $fallback_ts
| ($model_param | if . == "" then null else . end) as $model_param_or_null

| (split("\n")) as $raw_lines
| ($raw_lines | map(select(length > 0))) as $nonblank
| ($nonblank | map(try fromjson catch null)) as $parsed
| ($parsed | map(select(. != null and type == "object"))) as $events
| (
    ($nonblank | length) as $n
    | if $n == 0 then false else ($parsed[$n - 1] == null) end
  ) as $truncated

| ($events | map(select(.type == "system" and .subtype == "init")) | (.[0].session_id // null)) as $session_id
| ($events | map(select(.type == "system" and .subtype == "init")) | (.[0].model // null)) as $model_from_init
| ($events | map(select(.type == "assistant")) | (.[0].message.model // null)) as $model_from_assistant
| ($model_from_init // $model_from_assistant // $model_param_or_null) as $resolved_model

| (
    [ $events[] | select(.type == "assistant") | . as $ev
      | ($ev.message.content // [])[]?
      | select(.type == "tool_use")
      | {id: (.id // ""), name: (.name // "?"), ts: ($ev.timestamp | parse_ts)}
    ]
  ) as $tool_uses
| ($tool_uses | map({(.id): {name: .name, ts: .ts}}) | add // {}) as $tool_by_id

| [
    $events[] | . as $ev
    | if ($ev.type == "assistant") then
          ($ev.message.content // [])[]?
          | if .type == "text" then
                {v: 1, type: "message", ts: ($ev.timestamp // $fallback_ts), role: "assistant", text: (.text // "")}
            elif .type == "tool_use" then
                {v: 1, type: "tool.started", ts: ($ev.timestamp // $fallback_ts), tool: (.name // "?"), input_summary: null}
            else empty end
      elif ($ev.type == "user") then
          ($ev.message.content // [])[]?
          | select(.type == "tool_result")
          | (.tool_use_id // "") as $tid
          | ($tool_by_id[$tid].name // "?") as $tname
          | ($tool_by_id[$tid].ts) as $start_ms
          | ($ev.timestamp | parse_ts) as $end_ms
          | {
              v: 1, type: "tool.completed", ts: ($ev.timestamp // $fallback_ts),
              tool: $tname,
              ok: (if .is_error == true then false else true end),
              duration_ms: (if ($start_ms != null and $end_ms != null) then ($end_ms - $start_ms) else null end)
            }
      else empty end
  ] as $translated_events

| ($events | map(select(.type == "result")) | last) as $result
| (
    if $result == null then
        {
          status: "failed",
          error_kind: (if $truncated then "stream_cut" else "no_result" end),
          error_detail: (if $truncated
              then "el stream de Claude se corto a mitad de escritura"
              else "el stream de Claude termino sin un evento result" end)
        }
    elif ($result.is_error == false and $result.subtype == "success" and $result.stop_reason == "end_turn") then
        { status: "success", error_kind: null, error_detail: null }
    elif ($result.is_error == true) then
        {
          status: "failed",
          error_kind: "api_error",
          error_detail: (
              (if ($result.api_error_status // null) != null
                 then "API Error: " + ($result.api_error_status | tostring) + " "
                 else "" end)
              + ((($result.result) // $result.error // $result.terminal_reason // $result.subtype // "error") | tostring)
          )
        }
    else
        {
          status: "failed",
          error_kind: "nonzero_exit",
          error_detail: ("stop_reason=" + (($result.stop_reason // "?") | tostring) + " subtype=" + (($result.subtype // "?") | tostring))
        }
    end
  ) as $verdict

| {
    v: 1,
    type: (if $verdict.status == "success" then "run.completed" else "run.failed" end),
    ts: ($result.timestamp // $fallback_ts),
    status: $verdict.status,
    runtime: $runtime,
    model: $resolved_model,
    session_id: $session_id,
    duration_ms: null,
    tokens: { input: ($result.usage.input_tokens // null), output: ($result.usage.output_tokens // null) },
    cost_usd: ($result.total_cost_usd // null),
    turns: ($result.num_turns // null),
    denials: (if (($result.permission_denials // null) | type) == "array" then ($result.permission_denials | length) else null end),
    ttft_ms: ($result.ttft_ms // null),
    api_duration_ms: ($result.duration_api_ms // null),
    error: (if $verdict.error_kind == null then null else {kind: $verdict.error_kind, detail: $verdict.error_detail} end)
  } as $terminal

| $translated_events[], $terminal
