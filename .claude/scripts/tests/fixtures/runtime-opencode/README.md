# Fixtures del wire format de OpenCode (`opencode run --format json`)

Capturas **reales** del stream crudo de `opencode run --format json`, congeladas
para que `.claude/scripts/tests/test-runtime-opencode.sh` ejerza
`src/runtime/lib/runtime-opencode.{sh,jq}` sin invocar el CLI real
(MEF-ADR-0049, issue #860).

`--format json` esta documentado como "raw JSON events" (<https://opencode.ai/docs/cli/>)
y **no** tiene una especificacion estable publicada: la unica fuente de verdad
del formato es lo que el CLI emitio en una version concreta. De ahi el sufijo
de version en cada nombre de archivo.

## Version del CLI capturada

| | |
|---|---|
| CLI | `opencode` **1.18.29** |
| Fecha de captura | 2026-09-05 |
| Provider usado | OpenAI, ya conectado por OAuth en la maquina del mantenedor |

## Archivos

| Fixture | Que reproduce | Como se capturo |
|---|---|---|
| `success-1.18.29.jsonl` | Corrida trivial de exito: `step_start` -> `text` -> `step_finish`. | `opencode run --format json --agent build --dir <tmp> "Responde solo: ok"` |
| `success-tool-1.18.29.jsonl` | Corrida con una tool call resuelta (`tool_use` con `state.status:"completed"`) y **dos** `step_finish`, cada uno con los tokens/costo de SU paso. | `opencode run --format json --agent build --dir <tmp> "lista los archivos del directorio"` |
| `no-visible-text-1.18.29.jsonl` | Exit 0 sin ningun bloque `text`: solo tool call y cierre. Derivado de la misma corrida con tool, recortado antes del segundo paso. | (recorte de `success-tool-1.18.29.jsonl`) |
| `malformed-1.18.29.jsonl` | Linea no-JSON: el `text` cortado a mitad de escritura. Derivado de `success-1.18.29.jsonl` truncando su segunda linea. | (recorte de `success-1.18.29.jsonl`) |
| `empty-1.18.29.jsonl` | Stream vacio (cero lineas). | (archivo vacio a proposito) |

## Regla de mantenimiento

**Un fixture capturado nunca se edita.** Si una version futura de OpenCode
cambia el wire format, se agrega un archivo nuevo con su propia version en el
nombre (`*-<version>.jsonl`) y se actualiza esta tabla; el fixture viejo se
conserva como evidencia de lo que esa version emitia. Es la unica forma de que
una regresion del adaptador se distinga de un cambio del CLI.

Los fixtures **derivados** (recortes) se marcan como tales en la tabla: no son
salida literal de una corrida, sino un caso limite construido a partir de una
que si lo es. Los casos que no requieren un formato real (tipos de evento
desconocidos, `tool_use` en `state.status:"error"`, varios `step_finish` con
costos distintos) se construyen inline en el test, no aqui.
