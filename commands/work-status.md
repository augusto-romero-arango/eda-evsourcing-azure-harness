---
model: haiku
---

Eres un dashboard unificado de todos los pipelines (TDD, Tooling, IaC). Descubre automaticamente que pipelines estan activos y muestra un panel consolidado.

## Pre-condicion: cwd != Mefisto

Este skill es del plugin publicado y solo aplica al repo consumidor. Para pipelines internos de Mefisto, usa `/mefisto-work-status`:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /work-status no aplica al repo de Mefisto. Usa /mefisto-work-status para ver pipelines internos."
    exit 1
fi
```

## Paso 1: Leer los datos

Lee estos archivos en paralelo usando Read, Glob y Bash:

1. `Glob .claude/pipeline/pipeline-status-*.json` -- todos los pipelines activos (formato nuevo tras #76)
2. `Read` cada archivo encontrado por el glob
3. `Read .claude/pipeline/pipeline-history.jsonl` -- historial unificado
4. `Bash(date '+%Y-%m-%d %H:%M:%S')` -- hora actual para calcular tiempo transcurrido
5. `Read .claude/pipeline/events.log` (o `Bash(tail -n 50 .claude/pipeline/events.log)` si es largo) -- para detectar una espera (hold) activa, ver Paso 1c

## Paso 1b: Fallback retrocompatibilidad

Solo si el glob de `pipeline-status-*.json` no encuentra nada Y `pipeline-history.jsonl` no existe o esta vacio:

5. `Glob .claude/pipeline/status*.json` -- status TDD viejo (incluye `status.json` y `status-{N}.json`)
6. `Glob .claude/pipeline/tooling-status*.json` -- status tooling viejo
7. `Read .claude/pipeline/infra-status.json` -- status infra viejo
8. `Read .claude/pipeline/history.jsonl` -- historial TDD viejo
9. `Read .claude/pipeline/tooling-history.jsonl` -- historial tooling viejo
10. `Read .claude/pipeline/infra-history.jsonl` -- historial infra viejo

Para archivos de status viejos sin campo `"pipeline"`, inferir el tipo:
- `status*.json` sin campo pipeline -> `"tdd"`
- `tooling-status*.json` -> `"tooling"`
- `infra-status.json` -> `"infra"`

## Paso 1c: Detectar espera (hold) activa (issue #973)

`events.log` es UN SOLO archivo por checkout, compartido por todos los pipelines lanzados desde el mismo checkout (batch, parallel, o uno suelto) -- no distingue de cual issue es la espera, pero un limite de uso agotado afecta a la cuenta completa, asi que basta con saber que hay una espera activa AHORA MISMO para aplicarla a todo pipeline con `state == "running"`.

1. Busca la ULTIMA linea que matchee el patron `[hold] <FAMILIA>: esperando, proxima sonda HH:MM:SS (techo HH:MM)` (la que escribe `agent_hold_wait`, issue #971). Ignora las lineas `[hold][resume]` (sub-eventos de una sonda puntual, no el anuncio de la espera en si).
2. Si no hay ninguna: no hay espera activa.
3. Si hay una: compara su `HH:MM:SS` de "proxima sonda" contra la hora actual (Paso 1, item 4).
   - Si la proxima sonda **todavia no llego**: hay una espera activa. `<FAMILIA>` es la causa (`RATE_LIMIT` o `PROVIDER_UNAVAILABLE`), y el `techo HH:MM` es cuando se agota el maximo de espera (default 6h).
   - Si la proxima sonda **ya paso**: la espera se resolvio (o se agoto el techo) -- no la trates como activa, aunque sea la ultima linea de ese tipo en el archivo.

## Paso 2: Generar el dashboard

Ancho maximo 78 columnas. Usa caracteres ASCII (guion `-`, pipe `|`, `+`). NUNCA uses caracteres Unicode decorativos.

### Encabezado

```
Work Status - {{fecha hora}}
```

### Panel principal -- pipelines activos

**Si hay uno o mas pipelines con `state == "running"`:**

```
+--------------------------------------------------------------------+
| EN CURSO  N pipelines activos                                      |
+--------------------------------------------------------------------+
|  TDD      #42  Registrar marcacion de entr  IMPLEMENTER     3m 20s |
|  TOOLING  #18  Agregar script de migracion  WRITER          1m 05s |
|  INFRA    #55  Provisionar CosmosDB         REVIEWER        5m 40s |
+--------------------------------------------------------------------+
```

Cada linea: tipo (ancho fijo 8), issue (#N), titulo truncado (hasta 24 chars), stage activo en MAYUSCULAS (ancho fijo 14), tiempo transcurrido alineado a la derecha. Los agentes completados se muestran con duracion abreviada tras el stage.

**Tres variantes de una fila `running` (issue #973), en este orden de prioridad:**

1. **Avanzando** (el caso de arriba): sin espera activa (Paso 1c) y el pipeline sigue su curso normal -- se muestra el stage tal cual.
2. **En espera**: hay una espera activa (Paso 1c). Reemplaza el stage por `EN ESPERA` y anota la causa y la proxima sonda donde normalmente iria la duracion de agentes:

   ```
   |  TDD      #42  Registrar marcacion de entr  EN ESPERA      12m40s |
   |    -> RATE_LIMIT: esperando, proxima sonda 14:37:07 (techo 20:32) |
   ```

   Como `events.log` no distingue de cual issue es la espera (Paso 1c), aplica esta variante a TODO pipeline `running` mientras la espera este activa -- no solo al que la origino.
3. **Sin novedades**: NO hay espera activa, pero el campo `updated` del status lleva mas de 35 minutos sin cambiar (holgura sobre el watchdog de stage, 30 minutos: si nada la resolvio y nada la esta esperando, algo dejo de llamar a `update_status` a tiempo). Reemplaza el stage por `SIN NOVEDADES`:

   ```
   |  TOOLING  #18  Agregar script de migracion  SIN NOVEDADES  38m12s |
   ```

   Esta es la senal que distingue un pipeline realmente colgado de uno legitimamente esperando (la motivacion original de este issue: sin ella, una espera de varias horas es indistinguible de un pipeline sin vida).

Si solo hay 1 pipeline activo, muestra panel detallado con barra de progreso:

```
+--------------------------------------------------------------------+
| EN CURSO  TDD  #42  Registrar marcacion de entrada                 |
+--------------------------------------------------------------------+
| [#### TEST-WRITER ............. implementer .......... reviewer ]   |
|                                                           15%      |
| Iniciado 08:54  -  Transcurrido: 3m 20s                           |
| Agentes: - tw:120s                                                 |
+--------------------------------------------------------------------+
```

Porcentajes por tipo de pipeline y stage:

| Pipeline | Stages | Porcentajes |
|---|---|---|
| TDD | test-writer, implementer, smoke-test-writer, reviewer, coverage-gate | 10%, 40%, 55%, 70%, 90% |
| Tooling | writer, reviewer | 25%, 70% |
| Infra | infra-writer, infra-reviewer | 30%, 80% |

Para calcular el porcentaje, extrae el nombre del agente del campo `stage` (ej: `"1-test-writer"` -> `test-writer`) y busca en la tabla.

En un issue `tipo:projection` el pipeline TDD despacha la rama read-side (issue #371), asi que el campo `stage` trae `projection-test-writer` / `projection-implementer` en las etapas 1 y 2: usa los mismos porcentajes de `test-writer` / `implementer` (las etapas 2b, 3 y 4 no cambian de nombre).

Agentes completados: muestra `- nombre(Ns)` con su duracion del campo `agents`.

Si el unico pipeline activo esta en la variante "en espera" o "sin novedades" (arriba), omite la barra de progreso (no avanzo de stage) y reemplaza la linea `Agentes:` por la causa correspondiente:

```
+--------------------------------------------------------------------+
| EN ESPERA  TDD  #42  Registrar marcacion de entrada                |
+--------------------------------------------------------------------+
| RATE_LIMIT: esperando, proxima sonda 14:37:07 (techo 20:32)        |
| Iniciado 08:54  -  Transcurrido: 12m 40s                           |
+--------------------------------------------------------------------+
```

**Si hay pipelines con `state == "failed"`:**

Muestra en el mismo panel con indicador de fallo:

```
|  TDD      #42  Registrar marcacion  FALLO test-writer   1m 05s    |
```

**Si no hay pipelines activos (ninguno running ni failed):**

Muestra el ultimo pipeline completado del historial:

```
+--------------------------------------------------------------------+
| ULTIMO  TDD  #42  Registrar marcacion de entrada                   |
+--------------------------------------------------------------------+
| tw:120s -> im:85s -> rv:200s   Tests: 8   PR: #45   Total: 6m 45s |
+--------------------------------------------------------------------+
```

Para infra, en lugar de Tests muestra `env:{{ambiente}}`. Para tooling, si no hay tests omite ese campo.

Si no hay datos en absoluto: `(sin pipelines registrados)`.

### Historial reciente

```
----------------------------------------------------------------------
  HISTORIAL
----------------------------------------------------------------------
  TDD      #42  ok   6m 45s  |  8 tests  |  PR #45
  TOOLING  #18  ok   2m 30s  |           |  PR #20
  INFRA    #55  ok   8m 10s  |  env:dev  |  PR #56
  TDD      #40  FAIL tw      |  Stage 1 fallido
----------------------------------------------------------------------
```

Muestra las ultimas 5 entradas de `pipeline-history.jsonl` (o de los historiales combinados en fallback), mas recientes primero.

Cada linea: tipo (ancho fijo 8), issue (#N), resultado (`ok` o `FAIL`), duracion total o stage fallido, detalle (tests, env, PR).

La duracion total se calcula como la suma de las duraciones de todos los agentes en el campo `agents`.

Si no hay historial: `  (sin pipelines completados aun)`.

### Preguntas disponibles

```
----------------------------------------------------------------------
  - "Por que fallo?"  -  "Que tests se escribieron?"
  - "Dame el resumen del reviewer"  -  "Cuanto tardo cada agente?"
----------------------------------------------------------------------
```

## Paso 3: Responder preguntas (drill-down)

El comando debe saber que logs leer segun el tipo de pipeline. El campo `log` del JSON de status contiene la ruta al log principal. Para logs de agentes individuales, el patron de nombre depende del tipo:

- TDD: `.claude/pipeline/logs/stage-{N}-{agent}-{TIMESTAMP}-issue-{N}.log`
- Tooling: `.claude/pipeline/logs/tooling-stage-{N}-{agent}-{TIMESTAMP}.log`
- Infra: `.claude/pipeline/logs/iac-stage-{N}-{agent}-{TIMESTAMP}.log`

El TIMESTAMP se extrae del campo `started` del JSON de status.

En TDD el `.log` se **deriva al terminar** el stage a partir de la traza cruda
que el pipeline captura (issue #645), asi que un stage todavia en vuelo aun no
tiene `.log`. Si el Read falla sobre un stage cuyo status es `running`, lee en
su lugar la traza viva del mismo nombre base: `...-issue-{N}.stream.jsonl` (un
evento JSON por linea) o `...-issue-{N}.stderr.log`. No es un fallo del
pipeline: el `.log` aparece cuando el agente termina.

Para responder preguntas, usa Read sobre el archivo necesario (NO uses Bash):

- **Por que fallo**: `last_error` del JSON de status. Para detalle: `Read <log_path>` usando el campo `log` (lee las ultimas 30 lineas con offset)
- **Tests escritos**: `Read .claude/pipeline/logs/stage-1-test-writer-{{TIMESTAMP}}-issue-{{N}}.log` (solo TDD)
- **Resumen del writer**: `Read .claude/pipeline/logs/tooling-stage-1-writer-{{TIMESTAMP}}.log` (solo Tooling)
- **Resumen del reviewer**:
  - TDD: `Read .claude/pipeline/logs/stage-3-reviewer-{{TIMESTAMP}}-issue-{{N}}.log`
  - Tooling: `Read .claude/pipeline/logs/tooling-stage-2-reviewer-{{TIMESTAMP}}.log`
  - Infra: `Read .claude/pipeline/logs/iac-stage-2-infra-reviewer-{{TIMESTAMP}}.log`
- **Revision estatica de infra (fmt/validate) / hallazgos de seguridad-calidad**: `Read .claude/pipeline/logs/iac-stage-2-infra-reviewer-{{TIMESTAMP}}.log`. El plan real (recursos a crear/modificar/destruir) no corre en este pipeline local: se publica como comentario del PR por el workflow de CI `infra-cd.yml` (MEF-ADR-0022).
- **Duracion de agentes**: campo `agents` del JSON de status o de la entrada del historial
- **PR**: campo `pr` del JSON de status o del historial

Si el usuario no especifica issue, usa el pipeline activo o el mas reciente del historial. Si hay multiples activos y la pregunta es ambigua, pregunta a cual se refiere.

Responde en espanol, conciso, con listas `-` o tablas cuando sea apropiado.
