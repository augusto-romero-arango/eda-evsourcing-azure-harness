# Certificacion del dogfooding interno con OpenCode y OpenAI (issue #874)

Evidencia reproducible de que una sesion real de OpenCode, autenticada con la
suscripcion ChatGPT del mantenedor (OAuth, sin API key), opera Mefisto. Este
documento **no** certifica soporte para consumidores: la certificacion del
corte publicado vive separadamente en
[`opencode-consumer-cutover.md`](opencode-consumer-cutover.md), conforme al
rollout interno-primero de MEF-ADR-0049 (ver tambien "Que NO certifica este
documento" al final).

## Veredicto

**Certificacion PARCIAL en esta corrida (2026-09-06).**

| CA | Estado | Sintesis |
|---|---|---|
| CA-1 | pasa | OAuth OpenAI real, `.mefisto/models.json` local con los 3 perfiles probados, cero secretos en el PR y en los logs de la corrida |
| CA-2 | pasa (con una discrepancia registrada) | 10 comandos y **3** agentes internos descubiertos (el issue asumia 5); `/mefisto-work-status` y `/mefisto-plan` (backlog, read-only) corridos bajo OpenAI |
| CA-3 | **no ejecutado -- bloqueado por #879** | el pipeline de tooling todavia invoca `claude -p` directo; ninguna sesion puede procesar un issue con las etapas corriendo bajo OpenCode hoy |
| CA-4 | parcial | el adaptador de runtime emite `runtime`/`model` con datos reales; el `pipeline-history.jsonl` y las metricas de stage de una corrida real **no** los registran todavia (mismo bloqueo #879) |
| CA-5 | no ejecutado | smokes tmux/batch/Herdr bajo OpenCode: sin valor de certificacion mientras dure el bloqueo #879 (solo cambiarian un campo de metadato) |
| CA-6 | parcial | suite completa verde (67/67) y smoke Claude implicito en esta misma corrida; falta el smoke Claude dedicado con `mefisto-tmux-pipeline.sh --tooling` en variante |

Esta misma corrida del pipeline de tooling para el issue #874 se ejecuto con
Claude Code: es exactamente el camino de fallback que el issue #874 preveia en
su seccion "Notas tecnicas" -- *"si el writer falla, el fallback es
`MEFISTO_RUNTIME=claude` para terminar el PR de evidencia, dejando registrado
que la certificacion **no** paso"*. Se deja registrado aqui, sin ambiguedad:
la certificacion completa (los 6 CA) **no** paso en esta corrida.

## Entorno verificado

| Item | Valor |
|---|---|
| Fecha | 2026-09-06 |
| OpenCode | `1.18.29` |
| Runtime que proceso este issue | Claude Code (fallback; ver "Veredicto") |
| Proveedor autenticado | OpenAI, OAuth (`opencode providers list` -> 1 credential, `OpenAI oauth`) |
| Modelos OpenAI expuestos | 15 ids (`opencode models openai`): `gpt-5.3-codex-spark`, `gpt-5.4`, `gpt-5.4-fast`, `gpt-5.4-mini`, `gpt-5.4-mini-fast`, `gpt-5.5`, `gpt-5.5-fast`, `gpt-5.6-luna`, `gpt-5.6-luna-fast`, `gpt-5.6-sol`, `gpt-5.6-sol-fast`, `gpt-5.6-terra`, `gpt-5.6-terra-fast`, `gpt-6-astra`, `gpt-6-astra-fast` |

## CA-1: autenticacion OAuth, sin secretos, `.mefisto/models.json`

- `opencode providers list` confirma exactamente 1 credencial (`OpenAI
  oauth`), leida por OpenCode desde su propio almacen
  (`~/.local/share/opencode/auth.json`) -- Mefisto no lo lee ni lo copia
  (MEF-ADR-0049 decision 5).
- `.mefisto/models.json` (local, gitignored via `.gitignore:6`) quedo poblado
  con:

  ```json
  {
    "opencode": {
      "profiles": {
        "fast": "openai/gpt-5.4-mini-fast",
        "balanced": "openai/gpt-5.5",
        "deep": "openai/gpt-6-astra"
      },
      "agents": {}
    }
  }
  ```

- **Los tres ids se probaron con una invocacion real** (`opencode run --agent
  mefisto-investigator --format json --auto -m <id>`, prompt de solo
  conectividad, sin tools): los tres respondieron `LISTO`, exit 0, `cost: 0`
  (facturacion por suscripcion ChatGPT, no por API key), sin tocar el
  repositorio (`git status --porcelain` vacio antes y despues).
- **Grep de secretos sobre la salida cruda y el stderr de las tres
  corridas** (`auth.json`, `api[_-]?key`, `sk-`, `Bearer `): cero matches.
- **Grep de secretos sobre el PR** (`git diff main...HEAD`, patrones
  `sk-[A-Za-z0-9]{16,}`, `Bearer <token>`, `"access_token"`,
  `"refresh_token"`): cero matches. Las unicas apariciones literales de
  `auth.json` y `api_key` en el diff son las de esta misma prosa, describiendo
  los patrones buscados.
- **Grep de secretos sobre los logs de la corrida**
  (`.mefisto/pipeline/logs/*20260906*`, 10 archivos, mismos patrones): cero
  matches. Ningun token, auth file ni API key entro a este repo ni a los logs.

## CA-2: descubrimiento de agentes/comandos y turnos reales bajo OpenAI

- **Comandos**: `.opencode/commands/` expone **10** comandos internos, tal
  como preve CA-2 (`mefisto-bitacora`, `mefisto-bug`, `mefisto-fix-review`,
  `mefisto-merge`, `mefisto-plan`, `mefisto-release`, `mefisto-sequential`,
  `mefisto-tooling`, `mefisto-tooling-verbose`, `mefisto-work-status`).
- **Agentes -- discrepancia observada frente al issue**: `.opencode/agents/`
  expone **3** agentes internos (`mefisto-historiador`,
  `mefisto-investigator`, `mefisto-planner`), no 5 como asumia la redaccion
  original de CA-2. `opencode agent list` los confirma como `(primary)` junto
  a los agentes propios de OpenCode (`build`, `compaction`, `explore`,
  `general`, `plan`, `summary`, `title`, que no son de Mefisto). El repo solo
  tiene 3 agentes internos hoy (`src/internal/agents/` y `.claude/agents/`
  tambien tienen exactamente 3) -- el numero "5" de la redaccion del issue no
  corresponde al estado actual del repo; se deja constancia en vez de forzar
  una cuenta que no existe.
- **`/mefisto-work-status` bajo OpenAI activo** (`opencode run --command
  mefisto-work-status --agent mefisto-investigator -m
  openai/gpt-5.4-mini-fast --auto --format json`): exit 0. Herramientas
  usadas: `bash` (x4), `glob` (x4), `todowrite` (x2) -- ninguna escritura.
  Salida (dashboard correcto: el estado de pipelines vive en el repo
  principal, no en el worktree desde el que se corrio):

  ```
  (sin pipelines internos registrados)
  ...
  HISTORIAL (pipelines internos)
  (sin datos)
  Estado git: limpio en `worktree-mefisto-issue-874-...` (branch `origin/main`).
  No encontre `.mefisto/pipeline/pipeline-status-mefisto-*.json` ni
  `pipeline-history.jsonl` en este repo.
  ```

- **Turno read-only de `/mefisto-plan` (modo backlog) bajo OpenAI activo**
  (`opencode run --command mefisto-plan --agent mefisto-planner -m
  openai/gpt-5.4-mini-fast --auto --format json` con el mensaje "backlog"
  mas una instruccion explicita de solo lectura): exit 0. El comando delego
  en un subtask (`tool: task`, `subagent_type: mefisto-planner`, mismo
  `modelID: gpt-5.4-mini-fast` / `providerID: openai` heredado) que ejecuto
  `gh issue list --state open` real contra este repo y devolvio un backlog
  agrupado por componente con la lista real de issues abiertos (#861, #879,
  #873, #874, #849, #850, #829, #801, #798) y una priorizacion sugerida --
  sin invocar `gh issue edit/create/close/comment` en ningun momento
  (`git status --porcelain` vacio; ningun `tool_use` de tipo `gh issue
  edit|create|close|comment` en la traza).

## CA-3: procesar el issue #874 con `/mefisto-tooling 874` desde OpenCode

**No ejecutado, y hoy no es ejecutable: esta bloqueado por el issue #879**
(`Conectar el tooling pipeline interno al runner neutral con agentes headless
writer y reviewer`, abierto, `estado:listo`).

`src/internal/scripts/mefisto-tooling-pipeline.sh:487` sigue invocando
`claude -p` directamente para cada etapa; el pipeline **registra**
`MEFISTO_RUNTIME` pero todavia no lo usa para elegir CLI, como declara su
propio evento de arranque (linea 287): *"RUNTIME: <id> (registrado; todavia no
selecciona CLI -- #879)"*. Lanzar `/mefisto-tooling 874` con
`MEFISTO_RUNTIME=opencode` -- desde una sesion de OpenCode o desde cualquier
otra -- produciria writer y reviewer corriendo igualmente bajo Claude Code:
seria un falso positivo, no una certificacion.

A esto se suma que esta corrida ya es el pipeline de tooling del propio
issue #874: invocarlo de nuevo desde adentro seria recursivo (un segundo
worktree/PR para un issue en curso).

**Que falta para cerrar CA-3**: (1) que aterrice #879, conectando el pipeline
a `mefisto-run-agent.sh` (`lib/mefisto-runtime.sh`); (2) recien entonces, una
corrida real de `/mefisto-tooling <issue de prueba>` con
`MEFISTO_RUNTIME=opencode`, contra un issue de prueba distinto de #874 (para
no repetir el problema de recursividad), hasta un PR real.

## CA-4: `runtime`/modelo en el protocolo de eventos, `cost_usd`/`ttft_ms` nulos

**Nivel de adaptador: verificado con datos reales** (no sinteticos). Se tomo
la salida cruda capturada de la corrida `gpt-5.4-mini-fast` de CA-1 y se le
aplico `runtime_opencode_translate`
(`src/runtime/lib/runtime-opencode.sh`) directamente:

```json
{"v":1,"type":"message","role":"assistant","text":"LISTO", ...}
{"v":1,"type":"run.completed","status":"success","runtime":"opencode","model":"openai/gpt-5.4-mini-fast","session_id":"ses_...","duration_ms":null,"tokens":{"input":8449,"output":8},"cost_usd":0,"turns":null,"denials":null,"ttft_ms":null,"api_duration_ms":null,"error":null}
```

- `runtime` y `model` quedan poblados correctamente a partir de una sesion
  real.
- `cost_usd` viaja como `0`: es el costo real que reporta OpenCode para una
  sesion facturada por suscripcion ChatGPT, no un `null` disfrazado.
- `ttft_ms` (y `duration_ms`/`turns`/`denials`/`api_duration_ms`) quedan
  `null` en la traduccion directa -- `runtime_opencode_translate` no los
  sintetiza por si sola; eso es responsabilidad del runner
  (`mefisto-run-agent.sh`) al envolver la invocacion con el watchdog.
- `.claude/scripts/mefisto-metrics-report.sh:358` confirma en codigo
  (`if [ -z "$v" ] || [ "$v" = "null" ]; then echo "n/d"; return 0; fi`) que
  un valor ausente o `null` se muestra como `n/d`, nunca como `0` ni como
  error.

**Nivel de corrida real: no cumplido todavia** (mismo bloqueo #879). Estado
observado de los artefactos de esta misma corrida:

- `pipeline-history.jsonl` escribe `"runtime": ${MEFISTO_RUNTIME_JSON:-null}`
  (`mefisto-tooling-pipeline.sh:66-67,949`): sin `MEFISTO_RUNTIME` en el
  entorno queda `null`, y con la variable puesta registraria la cadena tal
  cual **aunque las etapas siguieran corriendo bajo Claude Code**. Ninguna
  entrada del historial tiene hoy `runtime` distinto de `null`.
- Las metricas de stage
  (`.mefisto/pipeline/metrics/mefisto-tooling-*-issue-874-stage-1-writer.json`)
  **no tienen campo `runtime`**: se derivan del stream de `claude -p`
  (`model`, `turns`, `cache_read`, ...). Registrar `runtime` ahi es parte de
  conectar el pipeline al runner neutral.

Cobertura vigente mientras tanto: el adaptador de runtime
(`runtime-opencode.sh`/`runtime-opencode.jq`) con datos reales, mas
`test-runtime-opencode.sh` y `test-metrics-report.sh` en la suite
automatizada.

## CA-5: smokes `mefisto-tmux-pipeline.sh --tooling`/`--batch` y `mefisto-herdr-pipeline.sh` bajo OpenCode

**No ejecutados.** Ademas del costo (issue de prueba desechable, sesiones
tmux/Herdr de larga duracion y un stub de `gh` para `--batch`), hoy no
certificarian nada: los tres pipelines desembocan en el mismo
`mefisto-tooling-pipeline.sh` que invoca `claude -p` directo (ver CA-3), asi
que `MEFISTO_RUNTIME=opencode` solo cambiaria un campo de metadato en el
historial. Tienen valor **despues** de #879.

## CA-6: suite completa y smoke Claude

- **Suite completa verde**: 31 suites de `scripts/tests/*.sh` + 36 de
  `.claude/scripts/tests/*.sh` = **67 suites, 0 fallos** (corrida del
  reviewer de este issue, 2026-09-06).
- **Smoke Claude**: esta misma certificacion, procesada por Claude Code
  dentro del pipeline de tooling real para el issue #874, **es** el smoke
  Claude -- la prueba viviente de que el runtime Claude Code no se rompio con
  la arquitectura neutral de MEF-ADR-0049. No sustituye el smoke dedicado que
  pide CA-6 (`mefisto-tmux-pipeline.sh --tooling` sobre un issue de prueba en
  variante), que queda en backlog.

### Que NO certifica este documento

- El plugin **publicado** (`commands/`, `agents/`, `scripts/`, `hooks/`) **no
  esta soportado en OpenCode**. Todo lo certificado aqui es exclusivamente el
  lado interno (`src/internal/`, `.opencode/`) del propio repo de Mefisto.
- Falta, para una fase publicada futura (posterior a este issue, ver
  MEF-ADR-0049 "Que queda fuera de este ADR"): el layout `dist/` para
  distribuir el harness a consumidores sobre OpenCode, la distribucion
  GitHub-only equivalente, y el concepto de "version activa global por
  usuario" para un runtime neutral.

## Backlog (pendiente para cerrar la certificacion completa)

1. **Prerrequisito de todo lo demas**: cerrar #879 (conectar
   `mefisto-tooling-pipeline.sh` a `mefisto-run-agent.sh`), para que
   `MEFISTO_RUNTIME` seleccione CLI en vez de solo registrarse.
2. Con (1) hecho, ejecutar CA-3: `/mefisto-tooling <issue de prueba>` con
   `MEFISTO_RUNTIME=opencode`, sin recursividad sobre el propio pipeline que
   lo ejecuta, hasta un PR real.
3. Con (1) hecho, ejecutar los tres smokes de CA-5 (`--tooling` variante,
   `--batch` con stub de `gh`, `mefisto-herdr-pipeline.sh` dentro de Herdr)
   bajo `MEFISTO_RUNTIME=opencode`, mas el smoke Claude dedicado de CA-6
   (`--tooling` en variante con `MEFISTO_RUNTIME=claude`).
4. Con (2) resuelto, capturar un `pipeline-history.jsonl` y unas metricas de
   stage reales de una corrida completa bajo OpenCode -- con `runtime` y
   `model` poblados en ambos -- para cerrar la parte de CA-4 que depende de
   una corrida end-to-end.
5. Decidir si el numero de agentes internos ("5" en la redaccion original de
   CA-2 vs. 3 reales hoy) fue un error de redaccion del issue o si faltan 2
   agentes por scaffoldear -- no se resuelve en este documento.
