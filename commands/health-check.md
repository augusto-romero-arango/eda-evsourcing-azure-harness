Dashboard de salud del entorno desplegado. Ejecuta queries contra App Insights y presenta un resumen con semaforos. Comunicate en **espanol**.

## Proceso

### 1. Validar prerequisitos

Verifica que el script existe y es ejecutable:

```bash
test -x scripts/appinsights-query.sh && echo "OK" || echo "FAIL"
```

Si falla, responde:

```
El script scripts/appinsights-query.sh no existe o no es ejecutable.
Asegurate de que el issue #33 esta mergeado.
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

### 2. Ejecutar queries

Ejecuta las 3 queries en secuencia. Captura la salida completa de cada una:

```bash
./scripts/appinsights-query.sh health-summary --hours 24
```

```bash
./scripts/appinsights-query.sh dead-letters --hours 24
```

```bash
./scripts/appinsights-query.sh function-errors --hours 24
```

Si alguna query falla, reporta el error pero continua con las demas.

### 3. Parsear resultados y construir dashboard

Analiza la salida tabular de cada query para extraer las metricas:

**De `health-summary`**:
- `totalExceptions` y `distinctTypes` de la seccion "Excepciones"
- `totalRequests`, `failedRequests` y `availabilityPct` de la seccion "Requests fallidas"

**De `dead-letters`**:
- Cuenta el numero de filas de datos en la tabla (excluyendo headers y separadores)

**De `function-errors`**:
- Cuenta el numero de funciones distintas con fallos en la tabla (excluyendo headers y separadores)

### 4. Aplicar semaforos

Criterios:

- **Exceptions**: verde = 0, amarillo = 1-5, rojo = >5
- **Requests**: verde = >99% exito, amarillo = 95-99%, rojo = <95%
- **Dead Letters**: verde = 0 filas de datos, amarillo = 1-5 filas, rojo = >5 filas
- **Function Errors**: verde = 0 funciones con fallos, rojo = cualquier fallo

Determina el estado general:
- Si todo es verde: "OK"
- Si hay amarillos pero no rojos: "ATENCION"
- Si hay algun rojo: "CRITICO"

### 5. Presentar dashboard

Muestra el dashboard en este formato exacto:

```
HEALTH CHECK - [FECHA Y HORA ACTUAL]
----------------------------------------------------------------------
Exceptions (24h):  [N] total, [M] tipos distintos     [SEMAFORO]
Requests:          [N] total, [M] fallidas ([P]%)      [SEMAFORO]
Dead Letters:      [N] mensajes encontrados             [SEMAFORO]
Function Errors:   [N] funciones con fallos             [SEMAFORO]
----------------------------------------------------------------------
Estado general: [OK | ATENCION | CRITICO]
```

Donde los semaforos son literalmente:
- `[verde]` para metricas saludables
- `[amarillo]` para metricas que requieren atencion
- `[rojo]` para metricas criticas

### 6. Sugerencias (solo si hay problemas)

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

### 7. Tip de monitoreo continuo

Al final del dashboard, siempre agrega:

```
Tip: usa /loop 30m /health-check para monitoreo continuo durante tu sesion de trabajo.
```

## Reglas

- **No modifiques el script** `appinsights-query.sh` -- solo ejecuta sus comandos.
- **No investigues problemas.** Solo presenta el dashboard y sugiere `/bug` si hay algo anormal.
- **Usa `--hours 24`** en todas las queries para mantener consistencia.
- **Si una query falla**, muestra el error en la linea correspondiente del dashboard en lugar del valor, y continua con las demas queries.
