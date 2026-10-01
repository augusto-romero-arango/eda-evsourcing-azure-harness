---
fecha: 2026-09-22
hora: 20:45
sesion: mefisto-planner
tema: Brecha de neutralizacion para OpenCode y plan de migracion de /merge
---

## Contexto
El usuario pregunto que falta neutralizar de Mefisto para que funcione en OpenCode; luego pidio planear solo `/merge`.

## Descubrimientos
- Lado interno casi completo: quedan `mefisto-scope-hook.sh` (solo PostToolUse de Claude, sin plugin en `.opencode/`), `mefisto-metrics-report.sh` y `mefisto-stream-watch.sh` (`not_migrated`).
- Lado publicado muy parcial: 3/26 comandos, 9/22 agentes y 6/24 scripts en `src/published/` y `dist/opencode`. Scripts con `claude -p`/`CLAUDE_*`: `pr-sync`, `iac-pipeline`, `scaffold-pipeline`, `herdr-workspace`. El gate de neutralidad no escanea `scripts/`.
- El binding de hook `remind-field-notes` no tiene soporte en OpenCode.
- No habia issues abiertos cubriendo esta brecha.

## Decisiones
- Refinado #1582: runner resuelto relativo al script, `--system-file` no interactivo, modelo por perfil `balanced` del implementer, exito exige terminal en el JSONL; el test nuevo extrae `run_agent` (los tests existentes nunca lo ejercitan).
- Refinado #1583: pr-sync no lee estado (solo escribe logs); ahora depende de #1582 porque este retira el otro literal `.claude/pipeline` y reescribe `run_agent`; el test corre `pr-sync.sh --all` con stubs y verifica `.mefisto/pipeline/logs/`.
- Refinado #1584: `state-path` no admite `<ts>` (se usa `{{mefisto:state-path logs}}`); los comandos OpenCode no llevan `permission` (se quito el CA de permisos); hay que agregar el espejo a `CLAUDE_ROOT_MIRRORS`; los tests de comando viven en `src/published/scripts/tests/` con shim.
- Hold/retry ante limite de uso (MEF-ADR-0051) en pr-sync queda fuera de #1582, en el draft #1586.
- Refinado #1586 (draft -> listo): reanudar la sesion y aceptar el trabajo por las postcondiciones de pr-sync (sin U / validate_tests) en vez del resumen de stage; enmienda MEF-ADR-0051 seccion 2 en el mismo issue. No se extrae un bucle de hold comun; la espera se ve en `events.log`, sin status file.
- `/merge` se migra en 3 pasos, siguiendo el molde de `/tooling` (#1142, #1156, #1143): runner neutral en pr-sync, estado en `.mefisto/pipeline`, y comando + empaquetado juntos.
- Verificado: el release OpenCode empaqueta `dist/opencode` completo y la proyeccion enumera `commands/`, asi que `/mefisto:merge` sale en el primer release tras #1584. La verificacion manual en OpenCode real la hace el usuario; no se crea issue ni CA para ella.
- `/sequential`: batch-pipeline.sh ya es casi neutral (solo exige `claude` en deps); falta empaquetarlo (tmux/herdr `--batch` lo invocan) y migrar el comando. `/batch-stop` y `/work-status` pasan a la siguiente etapa. Por pedido del usuario, los issues de esta etapa se crean como borrador.
- Refinado #1591 (-> listo): runtime ambiguo aborta (sin herencia implicita); se agrega chequeo de CLI del runtime resuelto porque `mefisto_resolve_runtime` no lo valida con `MEFISTO_RUNTIME` explicito; los tests E-G de batch-stop fijan `MEFISTO_RUNTIME=claude`.
- Refinado #1592 (-> listo): `/work-status` y `/batch-stop` se cablean ya con `{{mefisto:command}}` (degradacion aceptada en OpenCode hasta la siguiente etapa); la regla `--stop-on-error` se conserva y apunta a `{{mefisto:package-root}}/scripts/batch-pipeline.sh`.
- Refinado #1593 (-> listo, bug): verificado en vivo con tmux 3.6a que una sesion nueva en un servidor ya corriendo NO hereda `MEFISTO_RUNTIME` del cliente. tmux-pipeline.sh resolvera el runtime y lo antepondra en sus 4 send-keys, como herdr. Draft #1594: los comandos generados no exportan su propio runtime (ambiguo con ambos CLIs).
- Refinado #1594 (-> listo, bug): el adaptador IMPONE su runtime con prefijo en linea `MEFISTO_RUNTIME=<id>` sobre cada `{{mefisto:run}}`, replicando el precedente del lado interno; descartado `${MEFISTO_RUNTIME:-<id>}` y el export en el preambulo.
- Etapa batch-stop/work-status (drafts): batch-stop ya es neutral en mecanica (pgrep + pipeline-state), solo falta el formato. work-status no puede migrarse tal cual: el validador prohibe `.claude` en el body y la lectura legacy es obligatoria, asi que se extrae a `work-status-collect.sh` (#1597) antes de migrar el comando (#1598).
- Hallazgo: #1586 CA-4 asume que /work-status muestra EN ESPERA desde events.log, pero el fallback textual es solo para filas legacy; pr-sync no tiene status estructurado. Corregido: #1586 CA-4 exige ahora `pipeline-status-pr-sync-<PR>.json` con hold estructurado (esquema de tooling-pipeline), y CA-5 agrega el escenario (e).
- Refinado #1596 (-> listo): deteccion inline sin script nuevo y se conserva el texto de parallel-pipeline.sh (paridad; en OpenCode pgrep no lo encuentra).
- Refinado #1597 (-> listo): el script entrega datos (activity, progress_pct, log resuelto incl. reconstruccion legacy) y el comando solo renderiza; reutiliza last_hold_line/hold_recently_active. Draft #1600: tdd-pipeline.sh no escribe hold estructurado en su status canonico.
- Refinado #1600 (-> listo, bug): replica el molde de hold estructurado de tooling-pipeline.sh en tdd-pipeline.sh; iac queda fuera (escribe en root legacy, cubierto por el fallback textual). Sin helper comun.
- #1586 se cerro (PR #1599) sin el status estructurado del CA-4 corregido: la corrida tomo el body anterior a la correccion. Draft #1601.
- Refinado #1601 (-> listo, bug): no se reabre #1586 (el resto de sus CAs si se cumplio). Status por PR con `issue`=PR como clave de dedup; funcion nueva `write_pr_status_file` (el `set_status` en memoria se conserva); trap marca `failed` al interrumpirse.
- Refinado #1598 (-> listo): el comando solo renderiza y hace drill-down; sin fila de batch (paridad). Descubierto: `{{mefisto:run}}` exige >=1 argumento, asi que #1597 se ajusto para aceptar `--json` obligatorio.
- El agente `pr-sync.md`, `/bitacora` y `batch-pipeline.sh` quedan fuera de alcance.

## Descartado
- Instrumentar el batch (historial/metricas): el usuario aclaro que solo busca paridad funcional con Claude.
- Un PR previo de registro de rutas: `src/published/commands/` y `dist/` ya estan registrados (#1071).
- Juntar los issues 1 y 2: se mantuvo el corte en tres.

## Preguntas abiertas
- Orden y prioridad del resto de comandos y agentes publicados (propuesta: draft+planner, bug+investigadores, sequential/batch, infra/scaffolders).
- Si hay que ampliar el gate de neutralidad a `scripts/`.
- Posible regla desactualizada: `--stop-on-error` parece viajar por `tmux-pipeline.sh --batch` hasta batch-pipeline.sh (sin verificar).
- Atribuir por issue las horas de hold de pr-sync en el reporte del batch (pr-sync solo conoce el PR).

## Referencias
Issues creados: #1582, #1583, #1584, #1586, #1591 (draft), #1592 (draft), #1593 (hueco tmux), #1594 (runtime en comandos generados), #1596 (draft), #1597 (draft), #1598 (draft), #1600 (hold en status TDD), #1601 (draft, status pr-sync)
Issues refinados: #1582, #1583, #1584, #1586, #1591, #1592, #1593, #1594, #1596, #1597, #1600, #1601, #1598
