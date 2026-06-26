---
model: haiku
---

Dashboard de los pipelines INTERNOS de Mefisto (en tmux). Solo opera dentro del repo de Mefisto.

## Paso 0: Verificar que estas en el repo de Mefisto

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git"; exit 1;
}
[ -f "$REPO_ROOT/.claude-plugin/plugin.json" ] || {
    echo "ERROR: este skill solo se ejecuta en el repo de Mefisto."
    exit 1
}
```

## Paso 1: Leer los datos

Lee estos archivos en paralelo:

1. `Glob .claude/pipeline/pipeline-status-mefisto-*.json` -- pipelines internos activos
2. `Read` cada archivo encontrado
3. `Read .claude/pipeline/pipeline-history.jsonl` -- historial (filtrara por `"pipeline": "mefisto-tooling"`)
4. `Bash(date '+%Y-%m-%d %H:%M:%S')` -- hora actual

## Paso 2: Generar el dashboard

Ancho maximo 78 columnas. Usa caracteres ASCII (`-`, `|`, `+`). NUNCA Unicode decorativo.

### Encabezado

```
Mefisto Work Status - {{fecha hora}}
```

### Panel principal -- pipelines internos activos

**Si hay uno o mas pipelines con `state == "running"`:**

```
+--------------------------------------------------------------------+
| EN CURSO  N pipelines internos activos                             |
+--------------------------------------------------------------------+
|  MEFISTO  #12  Refactorizar tooling-pipeli  WRITER        2m 10s   |
+--------------------------------------------------------------------+
```

Si solo hay 1 activo, panel detallado con barra de progreso:

```
+--------------------------------------------------------------------+
| EN CURSO  MEFISTO  #12  Refactorizar tooling-pipeline.sh           |
+--------------------------------------------------------------------+
| [#### WRITER .............. reviewer ............................. ] |
|                                                           25%      |
| Iniciado 09:00  -  Transcurrido: 2m 10s                            |
+--------------------------------------------------------------------+
```

Porcentajes (pipeline mefisto-tooling tiene 2 stages):
- `writer` -> 25%
- `reviewer` -> 70%
- `done` -> 100%

**Si no hay activos**, muestra el ultimo completado del historial filtrando por `"pipeline": "mefisto-tooling"`:

```
+--------------------------------------------------------------------+
| ULTIMO  MEFISTO  #12  Refactorizar tooling-pipeline.sh             |
+--------------------------------------------------------------------+
| wr:120s -> rv:200s   PR: #15   Total: 5m 20s                       |
+--------------------------------------------------------------------+
```

Si no hay datos: `(sin pipelines internos registrados)`.

### Historial reciente

```
----------------------------------------------------------------------
  HISTORIAL (pipelines internos)
----------------------------------------------------------------------
  MEFISTO  #12  ok    5m 20s  |  PR #15
  MEFISTO  #11  FAIL  writer  |  Stage 1 fallido
----------------------------------------------------------------------
```

Filtra `pipeline-history.jsonl` por `"pipeline": "mefisto-tooling"` y muestra las 5 mas recientes.

## Paso 3: Drill-down

Para responder preguntas como "por que fallo?":
- Logs viven en `.claude/pipeline/logs/mefisto-tooling-stage-{N}-{agent}-{TIMESTAMP}-issue-{N}.log`.
- TIMESTAMP se extrae del campo `started` del JSON de status.
- Para errores: `Read <log_path>` con offset al final.

## Reglas

- **No muestres pipelines del consumidor** (sin prefijo `mefisto-`). Si encuentras `pipeline-status-tdd-*.json` o similares, ignoralos: este skill es exclusivo del lado interno.
- **Responde en espanol**, conciso, con listas o tablas cuando aplique.
