# Contrato comun de eventos de runtime (`src/runtime/contract/`)

Esta es la fuente canonica, comun a los lados publicado e interno, del JSONL
neutral que describe una ejecucion de agente. Es independiente del caller y
versionado es `run-events.schema.json`; una linea del stream es un objeto que
valida contra `definitions[.type]`.

## Vocabulario y version

Todo evento lleva `v: 1` y un `type` del vocabulario cerrado:

| `type` | Campos propios |
|---|---|
| `run.started` | `ts`, `runtime`, `agent`, `model|null`, `cwd` |
| `message` | `ts`, `role`, `text`, `kind?: "text"|"thinking"` |
| `tool.started` | `ts`, `tool`, `input_summary|null` |
| `tool.completed` | `ts`, `tool`, `ok`, `duration_ms|null` |
| `run.completed` / `run.failed` | `status`, `runtime`, `model|null`, `session_id|null`, `duration_ms`, `tokens`, metricas opcionales, `error|null` y `resets_at?` |

Los campos que un runtime no puede informar se representan con `null`, nunca
con un valor inventado. `additionalProperties: false` fija la forma de cada

## Terminales, estado y fallo

Los terminales son `run.completed` y `run.failed`. La relacion entre `type` y
`status` es deliberadamente cerrada:

| Terminal | Estados validos |
|---|---|
| `run.completed` | `success` |
| `run.failed` | `failed`, `timeout`, `protocol_invalid` |

Una corrida completa tiene exactamente un evento terminal. Esta cardinalidad
es una invariante del stream, no expresable por el schema de una linea: el
runner o caller debe contar los terminales y rechazar cero o mas de uno
(MEF-ADR-0031). Los eventos no terminales ya ocurridos se conservan incluso si
el desenlace final es un timeout o un protocolo invalido.

Cuando `error` no es `null`, es `{kind, detail}`. `error.kind` pertenece a la
`provider_unavailable`, `stream_cut`, `nonzero_exit`, `no_result` o
`protocol_invalid`. `rate_limit` y `provider_unavailable` preservan la

## Validacion y fixtures

El validador ligero existente selecciona `definitions[.type]` antes de llamar

`fixtures/run-events/valid-*.jsonl` contiene corridas completas validas con un

La interfaz ejecutable del runner y de sus adaptadores sigue documentada en
