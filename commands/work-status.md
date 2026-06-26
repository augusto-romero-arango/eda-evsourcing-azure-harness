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
| Infra | infra-writer, infra-reviewer, infra-applier | 20%, 55%, 85% |

Para calcular el porcentaje, extrae el nombre del agente del campo `stage` (ej: `"1-test-writer"` -> `test-writer`) y busca en la tabla.

Agentes completados: muestra `- nombre(Ns)` con su duracion del campo `agents`.

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

- TDD: `.claude/pipeline/logs/stage-{N}-{agent}-{TIMESTAMP}.log`
- Tooling: `.claude/pipeline/logs/tooling-stage-{N}-{agent}-{TIMESTAMP}.log`
- Infra: `.claude/pipeline/logs/iac-stage-{N}-{agent}-{TIMESTAMP}.log`

El TIMESTAMP se extrae del campo `started` del JSON de status.

Para responder preguntas, usa Read sobre el archivo necesario (NO uses Bash):

- **Por que fallo**: `last_error` del JSON de status. Para detalle: `Read <log_path>` usando el campo `log` (lee las ultimas 30 lineas con offset)
- **Tests escritos**: `Read .claude/pipeline/logs/stage-1-test-writer-{{TIMESTAMP}}.log` (solo TDD)
- **Resumen del writer**: `Read .claude/pipeline/logs/tooling-stage-1-writer-{{TIMESTAMP}}.log` (solo Tooling)
- **Resumen del reviewer**:
  - TDD: `Read .claude/pipeline/logs/stage-3-reviewer-{{TIMESTAMP}}.log`
  - Tooling: `Read .claude/pipeline/logs/tooling-stage-2-reviewer-{{TIMESTAMP}}.log`
  - Infra: `Read .claude/pipeline/logs/iac-stage-2-infra-reviewer-{{TIMESTAMP}}.log`
- **Plan de infra / recursos creados**: `Read .claude/pipeline/logs/iac-stage-2-infra-reviewer-{{TIMESTAMP}}.log`
- **Duracion de agentes**: campo `agents` del JSON de status o de la entrada del historial
- **PR**: campo `pr` del JSON de status o del historial

Si el usuario no especifica issue, usa el pipeline activo o el mas reciente del historial. Si hay multiples activos y la pregunta es ambigua, pregunta a cual se refiere.

Responde en espanol, conciso, con listas `-` o tablas cuando sea apropiado.
