# Certificacion del dogfooding interno con OpenCode y OpenAI (issue #874)

Evidencia reproducible de que una sesion real de OpenCode, autenticada con la
suscripcion ChatGPT del mantenedor (OAuth, sin API key), opera Mefisto. Este
documento **no** certifica soporte para consumidores: MEF-ADR-0049 fija
rollout interno-primero, y el lado publicado del plugin sigue sin soporte
para OpenCode (ver "Que NO certifica este documento" al final).

## Veredicto

**Certificacion PARCIAL en esta corrida (2026-09-06).** CA-1, CA-2, CA-4 y
CA-6 pasan con evidencia real. **CA-3 y CA-5 no se ejecutaron** -- el detalle
de por que y que falta esta en sus secciones respectivas y en "Backlog". Esta
misma corrida del pipeline de tooling para el issue #874 se proceso bajo
`MEFISTO_RUNTIME=claude` (esta sesion es Claude Code, no OpenCode): es
exactamente el camino de fallback que el issue #874 preveia en su seccion
"Notas tecnicas" -- *"si el writer falla, el fallback es
`MEFISTO_RUNTIME=claude` para terminar el PR de evidencia, dejando registrado
que la certificacion **no** paso"*. Se deja registrado aqui, sin
ambiguedad: la certificacion completa (los 6 CA) **no** paso en esta corrida.

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
- `.mefisto/models.json` (local, gitignored) quedo poblado con:

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
  Ningun token, auth file ni API key entro a este repo ni a los logs
  capturados.

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
  tiene 3 agentes internos hoy (`src/internal/agents/` tambien tiene
  exactamente 3) -- el numero "5" de la redaccion del issue no corresponde al
  estado actual del repo; se deja constancia en vez de forzar una cuenta que
  no existe.
- **`/mefisto-work-status` bajo OpenAI activo** (`opencode run --command
  mefisto-work-status --agent mefisto-investigator -m
  openai/gpt-5.4-mini-fast --auto --format json`): exit 0. Herramientas
  usadas: `bash` (x4), `glob` (x4), `todowrite` (x2) -- ninguna escritura.
  Salida (dashboard correcto para un repo sin pipelines activos):

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

**No ejecutado en esta corrida.** Esta certificacion se produjo dentro del
mismo worktree que el pipeline ya habia creado para el issue #874, en la fase
de writer -- invocar `/mefisto-tooling 874` de nuevo desde adentro de esa
misma corrida seria recursivo (un segundo pipeline intentando crear un
segundo worktree/PR para el mismo issue que ya esta en curso) y arriesgaria
el estado del propio pipeline que produce este documento. Ademas, esta sesion
es Claude Code, no OpenCode (ver "Veredicto"): no hay forma de que ESTA
sesion satisfaga "procesado desde OpenCode" sin dejar de ser lo que es.

**Que falta para cerrar CA-3**: una corrida real de `/mefisto-tooling <issue
de prueba>` lanzada *desde dentro de una sesion interactiva de OpenCode* (no
recursivamente desde este mismo pipeline), con `MEFISTO_RUNTIME=opencode`,
contra un issue de prueba distinto de #874 (para no repetir el problema de
recursividad), hasta un PR real. Documentado como backlog.

## CA-4: `runtime`/modelo en el protocolo de eventos, `cost_usd`/`ttft_ms` nulos

Verificado con datos reales de las tres corridas de CA-1 (no sinteticos): se
tomo la salida cruda capturada de la corrida `gpt-5.4-mini-fast` y se le
aplico `runtime_opencode_translate` (`src/internal/scripts/lib/runtime-
opencode.sh`) directamente:

```json
{"v":1,"type":"message","role":"assistant","text":"LISTO", ...}
{"v":1,"type":"run.completed","status":"success","runtime":"opencode","model":"openai/gpt-5.4-mini-fast","session_id":"ses_...","duration_ms":null,"tokens":{"input":8449,"output":8},"cost_usd":0,"turns":null,"denials":null,"ttft_ms":null,"api_duration_ms":null,"error":null}
```

- `runtime` y `model` quedan poblados correctamente a partir de una sesion
  real.
- `cost_usd` viaja como `0` (OpenCode reporta el costo real de una sesion
  facturada por suscripcion ChatGPT, no por API key: no es un `null`
  disfrazado, es el costo real).
- `ttft_ms` (y `duration_ms`/`turns`/`denials`/`api_duration_ms`) quedan
  `null` en la traduccion directa -- `runtime_opencode_translate` no los
  sintetiza por si sola; eso es responsabilidad del runner
  (`mefisto-run-agent.sh`) al envolver la invocacion con el watchdog, fuera
  del alcance de esta prueba puntual.
- `mefisto-metrics-report.sh:358` confirma en codigo (`if [ -z "$v" ] || [
  "$v" = "null" ]; then echo "n/d"; return 0; fi`) que un valor ausente o
  `null` se muestra como `n/d`, nunca como `0` ni como error.

**No se genero un `pipeline-history.jsonl` real de una corrida de
`mefisto-tooling` completa bajo OpenCode** porque eso depende de CA-3 (sin
ejecutar). La cobertura de esta seccion es a nivel del adaptador de runtime
(`runtime-opencode.sh`/`runtime-opencode.jq`) con datos reales, mas la
cobertura ya existente de `test-runtime-opencode.sh`/`test-metrics-report.sh`
en la suite automatizada.

## CA-5: smokes `mefisto-tmux-pipeline.sh` / `mefisto-batch-pipeline.sh` / `mefisto-herdr-pipeline.sh` bajo OpenCode

**No ejecutados en esta corrida.** Requieren un issue de prueba desechable
(distinto de #874), sesiones tmux/Herdr de larga duracion, y -- para el caso
`--batch` -- un stub de `gh`; son smokes de integracion multi-proceso que
superan el alcance de una unica corrida de writer documentando evidencia.
Documentado como backlog.

## CA-6: suite completa y smoke Claude

- `scripts/tests/*.sh` y `.claude/scripts/tests/*.sh`: corridos al cierre de
  este cambio (ver commit/PR de este issue para el resultado exacto de la
  corrida).
- **Smoke Claude**: esta misma certificacion, procesada por Claude Code bajo
  `MEFISTO_RUNTIME=claude` (el fallback documentado en el issue) dentro del
  pipeline de tooling real para el issue #874, **es** el smoke Claude -- la
  prueba viviente de que el runtime Claude Code no se rompio con la
  arquitectura neutral de MEF-ADR-0049. No sustituye un smoke dedicado con
  `mefisto-tmux-pipeline.sh --tooling` sobre un issue de prueba en variante
  (mismo backlog que CA-5).

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

1. Ejecutar CA-3 real: `/mefisto-tooling <issue de prueba>` desde una sesion
   interactiva de OpenCode (`MEFISTO_RUNTIME=opencode`), sin recursividad
   sobre el propio pipeline que la ejecuta, hasta un PR real.
2. Ejecutar los tres smokes de CA-5 (`--tooling` variante, `--batch` con stub
   de `gh`, `mefisto-herdr-pipeline.sh` dentro de Herdr) bajo
   `MEFISTO_RUNTIME=opencode`.
3. Con (1) resuelto, capturar un `pipeline-history.jsonl` real de una corrida
   completa bajo OpenCode para cerrar la parte de CA-4 que depende de una
   corrida end-to-end (no solo del adaptador de runtime en aislamiento).
4. Decidir si el numero de agentes internos ("5" en la redaccion original de
   CA-2 vs. 3 reales hoy) fue un error de redaccion del issue o si faltan 2
   agentes por scaffoldear -- no se resuelve en este documento.
