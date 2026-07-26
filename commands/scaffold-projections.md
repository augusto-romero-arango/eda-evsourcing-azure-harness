---
model: haiku
---

Genera el worker de proyecciones `<RootNamespace>.Projections` (daemon asincronico `HotCold` de Marten), la biblioteca `<RootNamespace>.ReadModels` y el config-test base `<RootNamespace>.Projections.Tests` invocando al agente `projections-scaffolder`, al estilo de `infra-base-scaffolder`. **Alcance acotado (fase 1, issue #367 + fase 2, issue #375)**: el registro del store de cada dominio lo hace `domain-scaffolder` (issue #370); ninguna proyeccion ni read model concreto se genera aqui (issues `tipo:projection`). Comunicate en **espanol**.

## Pre-condicion 1: cwd != Mefisto

Este skill es del plugin publicado y solo aplica al repo consumidor. Mefisto no adopta proyecciones sobre si mismo. Verifica antes de continuar:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /scaffold-projections no aplica al repo de Mefisto."
    exit 1
fi
```

## Pre-condicion 2: token `projections.enabled` (CA-1)

El worker solo se genera si el BC declaro explicitamente que adopta proyecciones. El token vive en `.claude/harness.config.json` bajo `projections.enabled` -- mecanismo de deteccion que fija MEF-ADR-0034 (seccion 8); su contrato formal completo en `harness.config.json` (validacion via `HARNESS_PROJECTIONS_ENABLED` en `load_harness_config`, reporte de `/onboard`) lo fija el issue #369. Este skill sigue consumiendo el token en la forma minima que necesita (no pasa por `load_harness_config`, que requiere `boundedContext` obligatorio y otros campos que este skill no necesita).

Cada bloque `bash` corre en un shell nuevo: `REPO_ROOT` se vuelve a derivar aqui, no se hereda del bloque anterior (mismo patron que `/onboard`, que lo re-deriva en cada bloque).

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
CONFIG="$REPO_ROOT/.claude/harness.config.json"
if [ ! -f "$CONFIG" ]; then
    echo "ERROR: no existe .claude/harness.config.json. Corre /onboard antes de este skill."
    exit 1
fi
# Sin '//' en el filtro jq: 'false // "null"' devuelve "null" (false es falsy en jq) y
# confundiria "deshabilitado" con "ausente".
RAW=$(jq -r '.projections.enabled' "$CONFIG" 2>/dev/null)
if [ "$RAW" != "true" ]; then
    if [ -z "$RAW" ] || [ "$RAW" = "null" ]; then
        MOTIVO="ausente"
    else
        MOTIVO="deshabilitado (projections.enabled = $RAW)"
    fi
    echo "ERROR: el token 'projections.enabled' esta $MOTIVO en .claude/harness.config.json."
    echo ""
    echo "Este BC no declaro que adopta el worker de proyecciones (MEF-ADR-0034)."
    echo "Para habilitarlo, agrega en .claude/harness.config.json:"
    echo ""
    echo '  "projections": { "enabled": true }'
    echo ""
    echo "(el contrato formal del token, incluida la validacion y el reporte de /onboard,"
    echo "lo fija el issue #369)."
    exit 1
fi
```

Si `RAW` es `"true"`, continua.

## Proceso

### 1. Informar que se va a generar

```
Se va a generar el worker de proyecciones y su andamiaje read-side (fase 1,
issue #367 + fase 2, issue #375):

  src/<RootNamespace>.Projections/
    <RootNamespace>.Projections.csproj  (SDK Microsoft.NET.Sdk.Worker)
    Program.cs                          (arma el host, invoca el seam, nada mas)
    Infraestructura/ConfiguracionMartenProjections.cs  (seam base, sin dominios todavia)
    Dockerfile                          (imagen sobre runtime, sin ingress)

  src/<RootNamespace>.ReadModels/       (biblioteca vacia; una carpeta por dominio
                                          ya registrado en el worker, si aplica)

  tests/<RootNamespace>.Projections.Tests/
    Infraestructura/AssertsProyecciones.cs   (helper AssertOpcionesDeEvento)
    ConfiguracionMartenProjectionsTests.cs   (config-test base, sin dominios todavia)

  <SolutionFile>: se agregan los tres proyectos nuevos
  global.json: se verifica/crea la seccion "test"

Este agente NO registra ningun store de dominio (eso lo hace domain-scaffolder,
issue #370) NI escribe ninguna proyeccion o read model concreto (issues
tipo:projection). Es idempotente: re-ejecutar no duplica ni pisa contenido
existente.
```

### 2. Lanzar el agente

```bash
claude --agent projections-scaffolder "Genera el worker de proyecciones."
```

### 3. Tras terminar

Recuerda al usuario el resto de la cadena de issues relacionados:

```
Worker de proyecciones, ReadModels y config-test base generados. Siguiente:
  1. domain-scaffolder (issue #370) registra el named store de cada dominio que
     adopte proyecciones dentro del seam ConfiguracionMartenProjections y crea
     su carpeta en ReadModels.
  2. projection-test-writer/projection-implementer (issue #365) agregan sobre
     Projections.Tests las guardas por dominio (partial + ciclo de vida Async),
     reutilizando el helper AssertOpcionesDeEvento para la guarda de metadata.
  3. Los modulos Terraform del Container App (container-registry,
     container-app-environment, container-app) son opt-in y los genera
     infra-base-scaffolder cuando corra de nuevo con el token ya habilitado
     (issue #368, MEF-ADR-0034 seccion 8).
```

## Reglas

- **No generes nada tu mismo.** Solo valida las dos pre-condiciones, informa y lanza el agente.
- El agente nunca registra un store de dominio, un read model concreto ni toca Azure Service Bus (MEF-ADR-0034 seccion 4): esa es responsabilidad de `domain-scaffolder`/`projection-implementer` de cada dominio, no de este skill.
- El agente es idempotente: no sobrescribe `Program.cs`, el seam de composicion ni el config-test base si ya existen (pueden llevar registros o guardas de dominio agregados por `domain-scaffolder`/`projection-test-writer`).
