# Contratos comunes de runtime (`src/runtime/contract/`)

Esta carpeta es la fuente canonica, comun a callers publicados e internos, del
stream JSONL neutral que describe una ejecucion de agente. El protocolo esta
versionado en `run-events.schema.json`: cada linea es un objeto y valida contra
`definitions[.type]`. El contrato no presupone un runtime, proveedor ni modelo
concretos (MEF-ADR-0049 y MEF-ADR-0050).

## Vocabulario y version

Todo evento lleva `v: 1` y un `type` del vocabulario cerrado declarado en
`types`:

| `type` | Campos propios |
|---|---|
| `run.started` | `ts`, `runtime`, `agent`, `model|null`, `cwd` |
| `message` | `ts`, `role`, `text`, `kind?` (`text` o `thinking`) |
| `tool.started` | `ts`, `tool`, `input_summary|null` |
| `tool.completed` | `ts`, `tool`, `ok`, `duration_ms|null` |
| `run.completed` / `run.failed` | `ts`, `status`, `runtime`, `model|null`, `session_id|null`, `duration_ms`, `tokens`, `cost_usd|null`, `turns|null`, `denials|null`, `ttft_ms|null`, `api_duration_ms|null`, `error|null`, `resets_at?` |

`tokens` contiene exactamente `input` y `output`, ambos numero o `null`. Los
datos que un runtime no puede informar se representan con `null`, nunca con un
cero ni otro valor inventado. Cada definicion cierra su forma con
`additionalProperties: false`; lo mismo hacen `tokens` y `error`.

## Relacion entre terminal y estado

Los unicos terminales son `run.completed` y `run.failed`. `type` y `status` no
son dos veredictos independientes: el schema divide deliberadamente el
vocabulario de estados entre ambos.

| Terminal | `status` valido |
|---|---|
| `run.completed` | `success` |
| `run.failed` | `failed`, `timeout`, `protocol_invalid` |

Combinaciones como `run.completed{status:"timeout"}` son invalidas. Una corrida
completa tiene **exactamente un** terminal. La cardinalidad es una invariante
del stream y no puede expresarse en el schema de una linea: el caller debe
contar terminales y rechazar tanto cero como mas de uno (MEF-ADR-0031). Los
eventos no terminales completos se conservan aunque el desenlace sea timeout o
protocolo invalido.

## Taxonomia de `error.kind`

`error` es `null` o un objeto `{kind, detail}`. `kind` pertenece al vocabulario
cerrado siguiente (MEF-ADR-0051):

| `error.kind` | Significado neutral |
|---|---|
| `timeout` | El caller agoto el tiempo permitido |
| `killed` | El proceso termino por una senal externa |
| `api_error` | El proveedor informo un error de API no clasificado en otra familia |
| `rate_limit` | Se agoto una ventana de uso |
| `provider_unavailable` | El proveedor informo indisponibilidad transitoria |
| `stream_cut` | El stream termino antes de declarar un desenlace confiable |
| `nonzero_exit` | El proceso salio distinto de cero sin una causa mas especifica |
| `no_result` | No hubo resultado util del runtime |
| `protocol_invalid` | La traduccion produjo un stream que viola el contrato |

La distincion entre `rate_limit`, `provider_unavailable`, `stream_cut` y las
demas causas preserva la frontera de politica fijada por MEF-ADR-0051; un
caller consume la clasificacion y no vuelve a inferirla desde texto crudo.
`resets_at` es opcional y contiene un instante ISO 8601 o `null`: solo aporta
el fin de la ventana cuando el runtime lo conoce. Que un runtime carezca de esa
senal no cambia la taxonomia ni obliga a inventar el dato.

Un `run.completed` puede conservar excepcionalmente un `error` para registrar
una muerte posterior a que el runtime ya declarara exito. Esto no contradice
`status: "success"`; documenta el incidente posterior sin invalidar evidencia
ya emitida.

## Validacion

El schema no usa `oneOf`: el `oneOf` del validador ligero
`src/internal/scripts/lib/jsonschema-lite.jq` despacha por `kind`, mientras que
este contrato discrimina por `type`. Quien valida una linea comprueba primero
que `.type` pertenezca a `types`, selecciona `definitions[.type]` y pasa esa
definicion al validador. `validate_event_line` de
`.claude/scripts/tests/test-mefisto-run-agent.sh` es la implementacion de
referencia vigente.

El validador ligero no soporta uniones de tipos. Por eso los campos
documentados como valor o `null` omiten `type` en su sub-schema. Esta es una
limitacion conocida del toolchain Bash 3.2 + jq existente, no una autorizacion
para que los productores emitan tipos arbitrarios.

## Fixtures

`fixtures/run-events/valid-*.jsonl` contiene corridas validas. Los casos de
limite de uso muestran `resets_at` poblado cuando el runtime ofrece esa senal y
`null` cuando no la ofrece. `invalid-missing-field.jsonl`,
`invalid-unknown-type.jsonl` e `invalid-status-mismatch.jsonl` son rechazables
linea a linea.

`invalid-two-terminals.jsonl` tiene lineas individualmente validas, pero viola
la cardinalidad de exactamente un terminal; existe para comprobar el gate
cross-linea. Los tests recorren todos los fixtures `valid-*` e `invalid-*` sin
mantener una segunda copia del contrato.

## Runner y adaptadores

`src/runtime/mefisto-run-agent.sh` recibe `--agent`, `--cwd`, `--prompt-file`
y `--event-log`; acepta `--runtime`, modelo opaco, system prompt, timeout,
raw/stderr logs, `--events-log`, `--resume-session` y
`--redact-observability`. Este ultimo es opt-in y transforma por igual los
anexos en vivo y el stream final: omite `message`, deja
`tool.started.input_summary` en `null` y reemplaza `error.detail` por el texto
estable `detalle redactado: <error.kind>`. Conserva el terminal, su `type`,
`status`, `error.kind` y el exit del runner. No vuelve seguros `--raw-log` ni
`--stderr-log`: si se combinan, el runner avisa explícitamente que esos destinos
no estan redactados. `--events-log` es opt-in:
el nucleo no deriva rutas de estado. Sus exits son 0 (exito), 64 (uso), 65
(protocolo invalido), 69 (runtime/dependencia), 124 (timeout), o el exit no
cero del adaptador.

Cada `lib/runtime-<id>.sh` implementa `runtime_<id>_is_available` (probe sin
leer credenciales), `runtime_<id>_build_cmd` y `runtime_<id>_translate`; puede
implementar `runtime_<id>_supports_resume` y
`runtime_<id>_default_model <profile>`. La ausencia de esta ultima funcion
significa heredar el modelo activo. El resolutor respeta `--runtime` ->
`MEFISTO_RUNTIME` -> autodeteccion. Esta ultima escanea adaptadores y ejecuta
sus probes: un runtime nuevo no exige modificar el runner ni el resolutor.

`lib/mefisto-process.sh` es la fuente unica del watchdog: ejecuta el argv sin
`eval`, separa stdout/stderr y crea una sesion sin TTY de control. El runner
decide timeout mediante la senal del watchdog y su reloj de pared conforme a
MEF-ADR-0031.

## Mapping de modelos

`models.validate.jq` valida el mapping abierto que entrega cada caller al
resolutor `lib/mefisto-models.sh`. La forma es `<runtime-id> -> {profiles,
agents}`; `profiles` solo admite `fast`, `balanced` y `deep`, y cada modelo es
un string no vacio (se preservan espacios). `models.example.json` usa
placeholders y no declara un conjunto cerrado de runtimes.
El placeholder `<runtime-id>` debe sustituirse por un id valido antes de pasar
la plantilla al validador.

`mefisto_resolve_model <runtime> <agent-id> <profile> [explicit-model]
[mapping-file]` conserva el resultado y el motivo de error en
`MEFISTO_RESOLVED_MODEL` y `MEFISTO_MODELS_ERROR`. Su precedencia es override
explicito, agente, perfil, `runtime_<id>_default_model` y herencia (cadena
vacia). Una ruta omitida, inexistente o vacia equivale a no tener mapping; JSON
o forma invalidos fallan como `<archivo>: <campo>: <motivo>`. El nucleo no
deriva la ruta ni consulta estado, Git o cwd.
