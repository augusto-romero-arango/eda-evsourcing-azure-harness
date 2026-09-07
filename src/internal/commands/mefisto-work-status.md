---
{
  "kind": "command",
  "id": "mefisto-work-status",
  "description": "Dashboard de los pipelines INTERNOS de Mefisto (en tmux).",
  "profile": "fast"
}
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

1. `Glob .mefisto/pipeline/pipeline-status-mefisto-*.json` -- pipelines internos activos (si `.mefisto/pipeline/` aun no tiene datos, cae a su ubicacion legacy -- ver `mefisto-state.sh`)
2. `Read` cada archivo encontrado
3. `Read .mefisto/pipeline/pipeline-history.jsonl` -- historial (filtrara por `"pipeline": "mefisto-tooling"`; mismo fallback legacy que el paso anterior)
4. `Bash(date '+%Y-%m-%d %H:%M:%S')` -- hora actual
5. Si algun pipeline tiene `state == "running"`: `Read .mefisto/pipeline/events.log` con `offset` cerca del final (o `tail -n 60`) -- es el archivo COMPARTIDO por todas las corridas del checkout (nunca uno por issue), asi que basta su cola para ver la actividad mas reciente (mismo fallback legacy que el resto de este paso). Se usa en el Paso 2 para distinguir avanzando/en espera/sin novedades (issue #969).

## Paso 2: Generar el dashboard

Ancho maximo 78 columnas. Usa caracteres ASCII (`-`, `|`, `+`). NUNCA Unicode decorativo.

### Encabezado

```
Mefisto Work Status - {{fecha hora}}
```

### Panel principal -- pipelines internos activos

Cada JSON de status trae un campo `variant` (`null` en una corrida normal;
el label de `--variant` en una corrida de comparacion, issue #711). Cuando no
es `null`, sufija el numero de issue con `/{{variant}}` en toda fila donde
aparezca (`#711/exp-a`): sin eso, dos variantes simultaneas del mismo issue se
renderizan como dos filas identicas e indistinguibles. Aplica igual al
historial, que tambien lleva el campo.

#### Distinguir avanzando / en espera / sin novedades (issue #969)

Antes de dibujar el panel de un pipeline con `state == "running"`, clasifica su
situacion leyendo la cola de `events.log` (Paso 1, punto 5). `events.log` es
compartido por TODAS las corridas del checkout, asi que filtra por el
segmento `issue-{N}` de las lineas relevantes (`=== MEFISTO-TOOLING STAGE ...
===`, `[hold]`, `FALLO`, etc. -- el mismo nombrado que usan los logs de stage)
para no confundir la actividad de este pipeline con la de otro que corrio
antes en el mismo archivo:

1. Busca la ULTIMA linea `[hold]` de ese issue (formato fijo por el issue
   #967: `[HH:MM:SS][hold] <FAMILIA>: esperando, proxima sonda HH:MM:SS
   (techo HH:MM)`). Ignora las lineas `[hold][resume]` (issue #968, otro
   formato): son eventos de la reanudacion DENTRO de un ciclo de espera, no
   marcan un ciclo nuevo.
2. Si esa linea existe y la hora actual (Paso 1, punto 4) todavia no llego a
   su "proxima sonda", Y no hay ninguna linea POSTERIOR de ese issue en
   `events.log` (un nuevo `=== STAGE ===`, un `FALLO`, un `RECUPERADO`...):
   el pipeline esta **EN ESPERA**. Traduce la familia a una causa legible:
   `RATE_LIMIT` -> "limite de uso", `PROVIDER_UNAVAILABLE` -> "proveedor
   caido".
3. Si no esta en espera, compara la hora de la ULTIMA linea de `events.log`
   de ese issue con la hora actual:
   - Diferencia menor a ~2 minutos: **AVANZANDO** (el panel de siempre, con
     barra de progreso).
   - Diferencia mayor: **SIN NOVEDADES** desde hace esa diferencia (en
     minutos) -- no confundir con un fallo: el `state` del JSON sigue
     `"running"`, simplemente no hay rastro reciente de actividad (candidato
     a pipeline colgado, a diferencia de un hold, que SIEMPRE deja su propia
     linea antes de cada siesta).

**Si hay uno o mas pipelines con `state == "running"`:**

```
+--------------------------------------------------------------------+
| EN CURSO  N pipelines internos activos                             |
+--------------------------------------------------------------------+
|  MEFISTO  #12  Refactorizar tooling-pipeli  WRITER        2m 10s   |
|  MEFISTO  #13  Migrar script de purga       EN ESPERA (18:40)      |
+--------------------------------------------------------------------+
```

La ultima columna muestra el estado de cada fila segun la clasificacion de
arriba: la duracion transcurrida si esta AVANZANDO, `EN ESPERA (HH:MM)` con
la hora de la proxima sonda si esta en espera, o `SIN NOVEDADES Xm` si no.

Si solo hay 1 activo, panel detallado. **Avanzando** (barra de progreso, el
panel de siempre):

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

**En espera** (hold, issue #967/#969) -- sin barra de progreso, la causa y la
hora de la proxima sonda en su lugar:

```
+--------------------------------------------------------------------+
| EN ESPERA  MEFISTO  #12  Refactorizar tooling-pipeline.sh          |
+--------------------------------------------------------------------+
| limite de uso -- proxima sonda 18:40 (techo 21:15)                 |
| Iniciado 09:00  -  En espera desde 15:20                           |
+--------------------------------------------------------------------+
```

**Sin novedades** -- sin barra de progreso, con la hora del ultimo evento
visto en `events.log`:

```
+--------------------------------------------------------------------+
| SIN NOVEDADES  MEFISTO  #12  Refactorizar tooling-pipeline.sh      |
+--------------------------------------------------------------------+
| Sin actividad en events.log desde hace 34m (ultimo evento 14:10)   |
| Iniciado 09:00  -  Revisa si el pipeline sigue vivo                |
+--------------------------------------------------------------------+
```

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
- Logs viven en `.mefisto/pipeline/logs/mefisto-tooling-stage-{N}-{agent}-{TIMESTAMP}-issue-{N}.log`
  (mismo fallback legacy si `.mefisto/pipeline/` aun no tiene datos)
  -- en una corrida de variante, el segmento final es `issue-{N}-{variant}`.
- TIMESTAMP se extrae del campo `started` del JSON de status.
- Para errores: `Read <log_path>` con offset al final.

## Reglas

- **No muestres pipelines del consumidor** (sin prefijo `mefisto-`). Si encuentras `pipeline-status-tdd-*.json` o similares, ignoralos: este skill es exclusivo del lado interno.
- **Responde en espanol**, conciso, con listas o tablas cuando aplique.
