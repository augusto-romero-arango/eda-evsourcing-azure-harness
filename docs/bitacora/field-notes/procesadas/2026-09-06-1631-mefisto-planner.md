---
fecha: 2026-09-06
hora: 16:31
sesion: mefisto-planner
tema: visor en vivo tras el runner neutral (refinar #924, crear #925 y #926)
---

## Contexto

El mantenedor pidio refinar el draft #924: desde que `run_agent` pasa por el
runner neutral (#910, PR #919) el visor `mefisto-stream-watch.sh` queda vacio
durante todo el stage y muestra los 100+ eventos de golpe al cierre. Durante la
conversacion aparecio la necesidad real: una sola vista en vivo con los
"subtitulos" del agente, sus tool calls con marca de tiempo, el issue explicito
y los hitos del pipeline (PR creado, merge, resumen del batch), que hoy se cubre
con un paliativo gitignored (`.mefisto/pipeline/follow-stream.sh`) acoplado al
wire format de Claude.

## Descubrimientos

- Causa raiz verificada en `mefisto-run-agent.sh`: `run.started` se escribe al
  arrancar, el stdout del CLI va a `RAW_LOG`, y la traduccion (`$TRANSLATE_FN`)
  y el volcado de eventos ocurren solo al cierre (L341, L412-413). Evidencia:
  stage 1 de #914, 127 eventos con `ts` de 14 minutos escritos en un instante.
- `--events-log` (telemetria humana de #863, la lee `/mefisto-work-status`)
  sufre el mismo apagon: tambien se escribe al cierre.
- El visor neutral se queda corto frente al paliativo por **renderizado**, no
  por datos: imprime `(texto)` sin el texto y una linea por tool solo al
  `tool.completed`, sin `input_summary`. El JSONL neutral ya trae
  `message.text`, `tool.started.input_summary` y `run.started.cwd`.
- En herdr, `cmd_pane_runner` manda el stdout del pipeline a un `.report.log`
  y muestra solo sus ultimas 40 lineas al final: por eso PR/merge/resumen no se
  ven en vivo y se recortan en batches largos. En tmux ese stdout si es visible
  en su propio pane.
- Medido: `runtime_claude_translate` sobre un raw de 1.4 MB tarda 0.034 s.
  Ambos traductores toleran ultima linea parcial y emiten igual los no
  terminales; el terminal que fabrican sobre un raw parcial se descarta.
- Cero impacto en tokens/costo del agente en las tres piezas: todo ocurre en el
  host sobre archivos que el CLI ya escribe; el agente corre en el worktree y
  los logs viven en el checkout principal.

## Decisiones

- **1b (re-traducir periodicamente)** sobre 1a (traductor linea a linea por
  runtime) y 2 (visor lee el raw): reutiliza el traductor existente, no agrega
  interfaz de adaptador, es neutral por construccion y deja el archivo final
  identico al de hoy. Append por posicion (N+1), nunca reescritura; parada por
  archivo `live.stop` + `wait`, nunca `kill` a mitad de escritura.
- Particion en tres issues independientes por componente: #924 runner (bug),
  #925 visor (render rico: texto completo, `tool.started` con resumen relativo
  a `cwd`, `tool.completed` solo si fallo), #926 pane herdr (`tail -f` del
  `.report.log` junto al visor; se elimina el bloque "ultimas 40 lineas").
- En #926 se prefiere `tail -f` sobre `tee`/pipe para no alterar `$!`/`wait`/
  `rc` ni depender de que todos los descendientes cierren stdout.
- Ninguno declara dependencia de otro: el orden del batch es libre
  (`/mefisto-sequential 924 925 926` sugerido).

## Descartado

- Traductor de streaming por runtime (1a): dos traductores que pueden divergir
  y test de paridad extra; dos issues en vez de uno.
- Visor leyendo `.stream.jsonl` con el adaptador (2): rompe CA-6 de #878 y no
  arregla `--events-log`.
- `events.log` como unico feed consolidado (runner + pipeline + batch
  escribiendo hitos ahi): toca cinco componentes y el formato que consume
  `/mefisto-work-status`.
- Filtrar el stdout del pipeline a "solo hitos" en el pane herdr: patrones
  fragiles sobre texto humano; el mantenedor acepta el log completo.

## Preguntas abiertas

- Llevar `--events-log` a escritura en vivo (para `/mefisto-work-status`):
  candidato a issue posterior una vez aterrice #924.
- Retirar el paliativo `.mefisto/pipeline/follow-stream.sh` cuando #924 + #925
  esten mergeados (local, gitignored: no requiere PR).
- Si en Bash conviene tambien sustituir `<cwd>` por `.` dentro del comando
  (#925 solo relativiza rutas de tools de archivo).

## Referencias

Issues creados: #925 (visor rico), #926 (pane herdr en vivo).
Issues refinados: #924 (draft -> `estado:listo`, `bug`, retitulado).
Issues cerrados: ninguno.
