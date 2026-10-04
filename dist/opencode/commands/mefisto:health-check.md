---
description: "Dashboard de salud del entorno desplegado con semaforos: ultimo apply de infra-cd.yml y consultas de App Insights a 24 horas."
agent: "command-entry-health-check"
subtask: false
---
<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/health-check.md. No editar a mano. -->
```bash
# Cada llamada bash que use ${MEFISTO_PACKAGE_ROOT} debe incluir este bloque antes de sus comandos: no se asume estado de shell persistente entre llamadas.
if [ -n "${XDG_DATA_HOME:-}" ]; then mefisto_opencode_launcher="$XDG_DATA_HOME/mefisto/active/bin/mefisto-opencode"
elif [ "${OSTYPE%%[0-9.]*}" = darwin ]; then mefisto_opencode_launcher="$HOME/Library/Application Support/mefisto/active/bin/mefisto-opencode"
else mefisto_opencode_launcher="$HOME/.local/share/mefisto/active/bin/mefisto-opencode"; fi
if [ ! -f "$mefisto_opencode_launcher" ] || [ -L "$mefisto_opencode_launcher" ] || [ ! -x "$mefisto_opencode_launcher" ]; then
    printf '%s\n' 'ERROR OpenCode: no hay una release activa valida; instale o active la release OpenCode.' >&2; exit 1
fi
MEFISTO_PACKAGE_ROOT="$("$mefisto_opencode_launcher" package-root)" || {
    printf '%s\n' 'ERROR OpenCode: no se pudo resolver la release activa; instale o active la release OpenCode.' >&2; exit 1;
}
case "$MEFISTO_PACKAGE_ROOT" in
    /*) ;;
    *) printf '%s\n' 'ERROR OpenCode: la release activa no devolvio una raiz absoluta; reinstale o active la release OpenCode.' >&2; exit 1 ;;
esac
MEFISTO_PACKAGE_ROOT="$(cd -P "$MEFISTO_PACKAGE_ROOT" 2>/dev/null && printf '%s\n' "$PWD")" || {
    printf '%s\n' 'ERROR OpenCode: la release activa no existe; reinstale o active la release OpenCode.' >&2; exit 1;
}
export MEFISTO_PACKAGE_ROOT
```

Dashboard de salud del entorno desplegado. Ejecuta queries contra App Insights, verifica el ultimo apply de infraestructura en CI (workflow `infra-cd.yml`, MEF-ADR-0021/MEF-ADR-0022) y presenta un resumen con semaforos. Comunicate en **espanol**.

Antes de continuar, aborta si existe `src/internal/scripts/generate-internal-adapters.sh`: ese directorio es el repositorio de Mefisto, no un consumidor.

## Proceso

### 1. Validar la sesion de Azure

Verifica que hay sesion activa de Azure CLI:

```bash
MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/azure-account-info.sh" 2>&1
```

Si sale con codigo distinto de `0`, muestra tal cual el mensaje que emitio el script (indica iniciar sesion en Azure) y termina: no ejecutes ningun paso siguiente.

### 2. Verificar el ultimo apply de infraestructura (workflow Infra CD)

El `apply` de infraestructura no corre en local: corre en CI, en el job `apply` de `.github/workflows/infra-cd.yml` al mergear a `main` (MEF-ADR-0021, MEF-ADR-0022). Consulta el ultimo run de ese workflow sobre `main`:

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

Ejecuta las 3 queries en secuencia. Captura la salida completa de cada una:

```bash
MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/appinsights-query.sh" health-summary --hours 24
```

```bash
MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/appinsights-query.sh" dead-letters --hours 24
```

```bash
MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/appinsights-query.sh" function-errors --hours 24
```

Si falta `.mefisto/appinsights.env`, el script lo reporta con su propio mensaje: muestralo tal cual en la linea correspondiente del dashboard. Si alguna query falla, reporta el error pero continua con las demas.

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
  Sugiero: /mefisto:bug "[sintoma especifico basado en los datos]"
```

Por ejemplo:
- Si hay excepciones: `Sugiero: /mefisto:bug "N excepciones detectadas en las ultimas 24h, tipo principal: [tipo]"`
- Si hay dead letters: `Sugiero: /mefisto:bug "dead letters detectados en las ultimas 24h"`
- Si hay function errors: `Sugiero: /mefisto:bug "N funciones con requests fallidas en las ultimas 24h"`
- Si el porcentaje de exito es bajo: `Sugiero: /mefisto:bug "disponibilidad en [P]%, por debajo del umbral"`
- Si el ultimo Infra CD fallo: `Sugiero: /mefisto:bug "el ultimo apply de infra-cd.yml fallo en main"`

### 8. Tip de monitoreo continuo

Al final del dashboard, siempre agrega:

```
Tip: vuelve a ejecutar /mefisto:health-check periodicamente durante tu sesion de trabajo para detectar cambios en el entorno.
```

## Reglas

- **No modifiques el script** `appinsights-query.sh` -- solo ejecuta sus comandos.
- **No investigues problemas.** Solo presenta el dashboard y sugiere `/mefisto:bug` si hay algo anormal.
- **Usa `--hours 24`** en todas las queries para mantener consistencia.
- **Si una query falla**, muestra el error en la linea correspondiente del dashboard en lugar del valor, y continua con las demas queries.
- **Infra CD sin runs no es un fallo.** Un proyecto greenfield que aun no mergeo su primer PR de infra no tiene runs de `infra-cd.yml`: reporta `NO VERIFICADO`, no `CRITICO`.
