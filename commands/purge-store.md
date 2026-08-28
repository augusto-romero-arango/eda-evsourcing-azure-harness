---
model: sonnet
---

Diagnostica con evidencia si un dominio tiene datos de era vieja tras un movimiento/renombrado de eventos persistidos (MEF-ADR-0036), confirma con el humano mostrando exactamente que se pierde, y valida el resultado tras purgar. Los pasos destructivos los ejecuta siempre `scripts/purge-store.sh` (issue #725) -- este skill nunca corre `psql`/`DROP`/firewall por su cuenta. Comunicate en **español**.

## Pre-condicion: cwd != Mefisto

Este skill es del plugin publicado y solo aplica al repo consumidor. Mefisto no tiene `harness.config.json` ni un store desplegado que purgar:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /purge-store no aplica al repo de Mefisto."
    exit 1
fi
```

Si el bloque imprime `ERROR`, detente y muestra el mensaje al usuario.

## Entrada

`$ARGUMENTS`:

```
<dominio> [--env dev]
```

- **`<dominio>`**: dominio a diagnosticar y, si corresponde, purgar. Acepta kebab o PascalCase (`calculo-horas` o `CalculoHoras`) -- la forma canonica la resuelve `scripts/purge-store.sh` contra `domainLabels`.
- **`--env <env>`** (opcional): ambiente objetivo, default `dev`. `scripts/purge-store.sh` aborta con una guarda anti-prod codificada si `--env` no es `dev`; este skill **nunca** intenta rodear esa guarda ni ofrece purgar otro ambiente.

Si falta `<dominio>`, responde con el uso exacto de arriba y detente sin ejecutar nada.

## Proceso

### 1. Parsear `$ARGUMENTS`

Extrae `DOMINIO` y `ENV` (default `dev`). Deriva tambien una forma kebab aproximada solo para las busquedas de evidencia de los pasos 3/4 (la resolucion autoritativa contra `domainLabels` la hace `scripts/purge-store.sh` en el paso 6, no este calculo):

```bash
DOMINIO_KEBAB_GUESS=$(printf '%s' "$DOMINIO" | sed -E 's/([a-z0-9])([A-Z])/\1-\2/g' | tr '[:upper:]' '[:lower:]')
```

### 2. Resolver rutas del plugin

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"
test -x "$PLUGIN_SCRIPTS/purge-store.sh" && test -x "$PLUGIN_SCRIPTS/appinsights-query.sh" && echo "OK" || echo "FAIL"
```

Si falla, responde que el plugin no esta instalado correctamente (mismo mensaje que `/health-check`) y detente.

### 3. Diagnostico -- evidencia en App Insights (CA-1)

Verifica prerequisitos (mismo criterio que `/health-check`): `az account show` con sesion activa, y `scripts/.env` presente (el propio `appinsights-query.sh` reporta el error si falta). Si algun prerequisito falla, reportalo y detente -- no hay diagnostico sin acceso a la evidencia.

Busca el sintoma de identidad rota descrito en MEF-ADR-0036 (columna `mt_dotnet_type` desactualizada, error `42804` de Postgres al leer `mt_version`, o una excepcion de tipo no resuelto) en la ultima semana:

```bash
"$PLUGIN_SCRIPTS/appinsights-query.sh" custom "exceptions | where timestamp > ago(168h) | where outerMessage has '42804' or outerMessage has 'mt_version' or outerMessage has 'UnknownEventTypeException' | project timestamp, type, outerMessage, operation_Name | order by timestamp desc | take 20"
```

Guarda el resultado (filas encontradas o "resultado vacio").

### 4. Diagnostico -- evidencia en los smoke tests del ultimo deploy (CA-1)

Localiza el ultimo run del workflow de deploy de este dominio y su conclusion:

```bash
gh run list --workflow="deploy-${DOMINIO_KEBAB_GUESS}.yml" --branch main --limit 1 --json databaseId,conclusion,createdAt,url -q '.[0] // empty'
```

Si el run existe y no concluyo en `success`, trae el log de lo que fallo (incluye el job `smoke-tests`, reutilizable dentro del mismo run -- MEF-ADR-0031):

```bash
gh run view <databaseId> --log-failed
```

Lee el log con criterio: busca assertions de smoke test que fallen por campos `null` inesperados (forma vieja de un evento que el read model ya no reconoce), excepciones de deserializacion, o los mismos indicadores del paso 3 (`42804`, `mt_version`, `UnknownEventTypeException`). Distingue eso de un fallo no relacionado (timeout de red, flake de infraestructura, aserción de negocio ajena a la identidad de eventos).

Si el workflow no existe con ese nombre kebab (`gh run list` no devuelve nada), no lo trates como fallo duro: reporta que no se encontraron runs con ese nombre y continua solo con la evidencia del paso 3.

### 5. Evaluar evidencia: sin sintoma, sin purga (CA-1)

Si **ni** el paso 3 **ni** el paso 4 muestran alguno de los sintomas (`42804`/`mt_version`/`UnknownEventTypeException`/nulls de forma vieja), detente aqui. Responde:

```
No se encontro evidencia de datos de era vieja para "<dominio>":
  - App Insights (168h): sin coincidencias de 42804/mt_version/UnknownEventTypeException.
  - Ultimo deploy (<workflow o "sin runs">): <resumen: verde, o rojo por un motivo no relacionado>.

No se ofrece la purga: MEF-ADR-0036 exige diagnostico positivo antes de destruir el store.
Si el sintoma es otro, usa /bug "<descripcion>" para investigarlo.
```

Y **detente sin continuar al paso 6**.

Si hay evidencia (de cualquiera de los dos pasos), continua.

### 6. Resolver dominio/schema y cuantificar la perdida (CA-2 parcial)

Ejecuta el `--dry-run` de la mitad determinista -- resuelve el dominio contra `domainLabels`, calcula el schema y reporta streams/tablas de read model/checkpoints sin tocar nada:

```bash
"$PLUGIN_SCRIPTS/purge-store.sh" --domain "$DOMINIO" --env "$ENV" --dry-run
```

Si el script termina con error (dominio no declarado, recurso de Azure ausente, ambiguedad de Function App), muestra el mensaje tal cual y **detente sin continuar**.

Si el script reporta "no hay nada que purgar" (el schema no existe), detente y reportalo -- no hay purga posible ni tiene sentido pedir confirmacion.

### 7. Rastrear el issue/PR de origen, si es posible (CA-2)

Best-effort, nunca bloqueante. Busca un PR reciente que haya movido o renombrado eventos de este dominio:

```bash
gh pr list --state merged --search "$DOMINIO in:title" --limit 10 --json number,title,mergedAt,url
git log --oneline -20 -- "src/*${DOMINIO}*DomainEvents*" 2>/dev/null
```

Si algun resultado menciona mover/renombrar namespace, assembly o eventos, citalo en el reporte del paso 8 (`#<numero>: <titulo>`). Si no encuentras nada plausible, dilo explicitamente ("no se pudo rastrear el issue/PR de origen") -- no es un bloqueo, CA-2 solo lo exige "si es rastreable".

### 8. Presentar el diagnostico y confirmar (CA-3)

Muestra el reporte completo y pide confirmacion explicita antes de tocar nada:

```
=== Diagnostico: posible datos de era vieja en "<dominio>" (schema "<schema>") ===

Evidencia:
  - App Insights (168h): <resumen del paso 3>
  - Ultimo deploy (<workflow>, <fecha>): <resumen del paso 4>
  - Origen probable: <#issue/PR: titulo, o "no rastreado">

Esto es exactamente lo que se pierde (salida real de --dry-run):

<pegar aqui, verbatim, el output completo del paso 6>

Esta accion es IRREVERSIBLE: borra el schema completo y reinicia los procesos del dominio.

¿Continuar con la purga? (s/n)
```

Si la respuesta no es un "s"/"si" inequivoco, detente sin escribir ni ejecutar nada mas.

### 9. Ejecutar la purga (CA-4)

El unico paso destructivo, y **solo** via el script:

```bash
"$PLUGIN_SCRIPTS/purge-store.sh" --domain "$DOMINIO" --env "$ENV"
```

Muestra la salida completa. Si el script falla a mitad de camino, reporta el error tal cual -- **nunca** intentes completar manualmente lo que quedo a medias (ni `psql`, ni reinicios sueltos): la idempotencia de un reintento la garantiza el propio script.

### 10. Validar: relanzar smoke fallidos y veredicto (CA-5)

Si el paso 4 identifico un `databaseId` de un deploy con conclusion distinta de `success`, relanza solo lo que fallo:

```bash
gh run rerun <databaseId> --failed
```

Sondea hasta que termine (maximo ~20 intentos cada 15s, ~5 minutos):

```bash
for i in $(seq 1 20); do
    STATUS=$(gh run view <databaseId> --json status,conclusion -q '.status + " " + (.conclusion // "pendiente")')
    echo "[$i] $STATUS"
    [[ "$STATUS" == completed* ]] && break
    sleep 15
done
```

Si tras el maximo de intentos sigue sin completar, dilo explicitamente ("aun en curso, revisa con `gh run view <databaseId>`") -- no es un fallo del skill.

Cierra siempre con un veredicto explicito, nunca ambiguo:

- **Si `conclusion == success`**: "Veredicto: los smoke tests que estaban rojos por datos de era vieja en '<dominio>' quedaron verdes tras la purga."
- **Si sigue en rojo**: trae `gh run view <databaseId> --log-failed` y reporta "Veredicto: la purga NO resolvio los smoke tests de '<dominio>'. Siguen fallando: <resumen del log>. El sintoma probablemente no era (solo) datos de era vieja -- investiga con /bug." de una vez.
- **Si el paso 4 no identifico ningun deploy fallido que relanzar** (el ultimo deploy ya estaba verde, o no se encontro el workflow): reporta que no hay smoke que relanzar y sugiere `/health-check` para confirmar el estado actual del dominio.

## Reglas

- **Sin evidencia positiva, no hay purga.** Si App Insights y el ultimo smoke run del dominio no muestran ninguno de los sintomas de identidad rota, detente en el paso 5 y dilo explicitamente -- nunca ofrezcas la purga "por si acaso" (CA-1).
- **Todo paso destructivo pasa por `scripts/purge-store.sh`, sin excepcion.** Nunca ejecutes `psql`, `DROP`, reglas de firewall, ni reinicios de Function App/Container App directamente -- ese script es la unica superficie que este skill invoca para destruir algo (CA-4).
- **Nunca releajes la guarda anti-prod.** Si `--env` es distinto de `dev`, deja que `scripts/purge-store.sh` aborte con su mensaje; no intentes rodear esa guarda ni ofrecer purgar otro ambiente.
- **Confirmacion explicita obligatoria antes del paso 9.** Si el humano no responde "s"/"si" de forma inequivoca en el paso 8, detente sin ejecutar la purga real.
- **La purga es irreversible** -- comunicalo sin eufemismos antes de pedir confirmacion, mostrando siempre el `--dry-run` real, nunca un resumen aproximado.
- **El veredicto final del paso 10 es siempre explicito.** Nunca termines la corrida sin decir si los smoke tests quedaron verdes o por que no.
- **El rastreo del issue/PR de origen (paso 7) es best-effort.** No bloquea el diagnostico ni la purga si no se encuentra nada.
