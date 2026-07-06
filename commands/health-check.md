---
model: sonnet
---

Dashboard de salud del entorno desplegado. Ejecuta queries contra App Insights, verifica el ultimo apply de infraestructura en CI (workflow `infra-cd.yml`, ADR-0021/ADR-0022) y presenta un resumen con semaforos. Comunicate en **espanol**.

## Pre-condicion: cwd != Mefisto

Este skill es del plugin publicado y solo aplica al repo consumidor. Mefisto no tiene entorno desplegado ni App Insights:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /health-check no aplica al repo de Mefisto."
    exit 1
fi
```

## Proceso

### 1. Validar prerequisitos

Verifica que el script existe y es ejecutable:

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"
test -x "$PLUGIN_SCRIPTS/appinsights-query.sh" && echo "OK" || echo "FAIL"
```

Si falla, responde:

```
El script appinsights-query.sh del plugin no se encontro o no es ejecutable.
Asegurate de que mefisto este instalado y que el issue #33 esta mergeado.
```

Y termina.

Verifica que hay sesion activa de Azure CLI:

```bash
az account show --query name -o tsv 2>/dev/null
```

Si falla, responde:

```
No hay sesion activa de Azure. Ejecuta:
  az login
```

Y termina.

### 2. Verificar el ultimo apply de infraestructura (workflow Infra CD)

El `apply` de infraestructura ya no corre en local: corre en CI, en el job `apply` de `.github/workflows/infra-cd.yml` al mergear a `main` (ADR-0021, ADR-0022). Consulta el ultimo run de ese workflow sobre `main`:

```bash
gh run list --workflow=infra-cd.yml --branch main --limit 1 --json status,conclusion,createdAt,url -q '.[0] // empty'
```

Interpreta la salida:
- **Vacia** (el workflow aun no existe o nunca corrio en `main`): reporta `NO VERIFICADO` -- normal en un proyecto greenfield que aun no hizo su primer merge de infra. No lo trates como fallo.
- `status` distinto de `completed`: el run esta en curso; reporta `EN CURSO`.
- `conclusion == "success"`: el ultimo apply fue exitoso.
- Cualquier otro `conclusion` (`failure`, `cancelled`, `timed_out`, ...): el ultimo apply fallo.

Si `gh` no esta autenticado o el comando falla, reporta `NO VERIFICADO` (mismo criterio tolerante que el resto del dashboard) y continua.

### 3. Ejecutar queries

Ejecuta las 3 queries en secuencia. Captura la salida completa de cada una. Cada bloque resuelve la ruta del plugin por su cuenta, porque los bloques no comparten variables de shell entre invocaciones:

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"
"$PLUGIN_SCRIPTS/appinsights-query.sh" health-summary --hours 24
```

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"
"$PLUGIN_SCRIPTS/appinsights-query.sh" dead-letters --hours 24
```

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"
"$PLUGIN_SCRIPTS/appinsights-query.sh" function-errors --hours 24
```

Si alguna query falla, reporta el error pero continua con las demas.

### 4. Parsear resultados y construir dashboard

Analiza la salida tabular de cada query para extraer las metricas:

**De `health-summary`**:
- `totalExceptions` y `distinctTypes` de la seccion "Excepciones"
- `totalRequests`, `failedRequests` y `availabilityPct` de la seccion "Requests fallidas"

**De `dead-letters`**:
- Cuenta el numero de filas de datos en la tabla (excluyendo headers y separadores)

**De `function-errors`**:
- Cuenta el numero de funciones distintas con fallos en la tabla (excluyendo headers y separadores)

**Del paso 2 (Infra CD)**:
- `conclusion` y `createdAt` del ultimo run sobre `main` (o "sin runs" si la salida vino vacia)

### 5. Aplicar semaforos

Criterios:

- **Exceptions**: verde = 0, amarillo = 1-5, rojo = >5
- **Requests**: verde = >99% exito, amarillo = 95-99%, rojo = <95%
- **Dead Letters**: verde = 0 filas de datos, amarillo = 1-5 filas, rojo = >5 filas
- **Function Errors**: verde = 0 funciones con fallos, rojo = cualquier fallo
- **Infra CD**: verde = ultimo run `conclusion == success`, amarillo = sin runs (`NO VERIFICADO`) o en curso, rojo = ultimo run fallido

Determina el estado general:
- Si todo es verde: "OK"
- Si hay amarillos pero no rojos: "ATENCION"
- Si hay algun rojo: "CRITICO"

### 6. Presentar dashboard

Muestra el dashboard en este formato exacto:

```
HEALTH CHECK - [FECHA Y HORA ACTUAL]
----------------------------------------------------------------------
Exceptions (24h):  [N] total, [M] tipos distintos     [SEMAFORO]
Requests:          [N] total, [M] fallidas ([P]%)      [SEMAFORO]
Dead Letters:      [N] mensajes encontrados             [SEMAFORO]
Function Errors:   [N] funciones con fallos             [SEMAFORO]
Infra CD (apply):  [ultimo estado / fecha, o "sin runs"] [SEMAFORO]
----------------------------------------------------------------------
Estado general: [OK | ATENCION | CRITICO]
```

Donde los semaforos son literalmente:
- `[verde]` para metricas saludables
- `[amarillo]` para metricas que requieren atencion
- `[rojo]` para metricas criticas

### 7. Sugerencias (solo si hay problemas)

Si algun indicador esta en amarillo o rojo, agrega una seccion de problemas detectados:

```
Problemas detectados:
- [Indicador]: [descripcion del problema]
  Sugiero: /bug "[sintoma especifico basado en los datos]"
```

Por ejemplo:
- Si hay excepciones: `Sugiero: /bug "N excepciones detectadas en las ultimas 24h, tipo principal: [tipo]"`
- Si hay dead letters: `Sugiero: /bug "dead letters detectados en las ultimas 24h"`
- Si hay function errors: `Sugiero: /bug "N funciones con requests fallidas en las ultimas 24h"`
- Si el porcentaje de exito es bajo: `Sugiero: /bug "disponibilidad en [P]%, por debajo del umbral"`
- Si el ultimo Infra CD fallo: `Sugiero: /bug "el ultimo apply de infra-cd.yml fallo en main"`

### 8. Tip de monitoreo continuo

Al final del dashboard, siempre agrega:

```
Tip: vuelve a ejecutar /health-check periodicamente durante tu sesion de trabajo para detectar cambios en el entorno.
```

## Reglas

- **No modifiques el script** `appinsights-query.sh` -- solo ejecuta sus comandos.
- **No investigues problemas.** Solo presenta el dashboard y sugiere `/bug` si hay algo anormal.
- **Usa `--hours 24`** en todas las queries para mantener consistencia.
- **Si una query falla**, muestra el error en la linea correspondiente del dashboard en lugar del valor, y continua con las demas queries.
- **Infra CD sin runs no es un fallo.** Un proyecto greenfield que aun no mergeo su primer PR de infra no tiene runs de `infra-cd.yml`: reporta `NO VERIFICADO`, no `CRITICO`.
