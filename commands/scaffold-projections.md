---
model: haiku
---

Genera el worker de proyecciones `<RootNamespace>.Projections` (daemon asincronico `HotCold` de Marten, seam de observabilidad `ConfiguracionObservabilidadProjections` con el sampler que descarta el polling del daemon, MEF-ADR-0038), la biblioteca `<RootNamespace>.ReadModels`, el config-test base `<RootNamespace>.Projections.Tests`, el workflow de deploy `deploy-projections.yml` y el `.dockerignore` del build context invocando al agente `projections-scaffolder`, al estilo de `infra-base-scaffolder`. **Alcance acotado (fase 1, issue #367 + fase 2, issue #375 + fase 3, issue #453 + fase 4, issue #457 + fase 5, issue #458 + fase 6, issue #513 + fase 7, issue #552)**: el registro del store de cada dominio lo hace `domain-scaffolder` (issue #370); ninguna proyeccion ni read model concreto se genera aqui (issues `tipo:projection`). Comunicate en **espanol**.

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
issue #367 + fase 2, issue #375 + fase 3, issue #453 + fase 4, issue #457 +
fase 5, issue #458 + fase 6, issue #513):

  src/<RootNamespace>.Projections/
    <RootNamespace>.Projections.csproj  (SDK Microsoft.NET.Sdk.Worker)
    Program.cs                          (arma el host, invoca los seams, nada mas)
    Infraestructura/ConfiguracionMartenProjections.cs  (seam base, sin dominios todavia)
    Infraestructura/ConfiguracionObservabilidadProjections.cs  (seam de observabilidad:
                                          service.name obligatorio, AddSource
                                          Marten/Npgsql/propia, UseAzureMonitorExporter
                                          con EnableTraceBasedLogsSampler = false
                                          y el SetSampler posterior a ese exporter)
    Infraestructura/SamplerQueDescartaPollingDelDaemon.cs  (filtro del span de polling
                                          del daemon HotCold, MEF-ADR-0038: envuelve
                                          ParentBasedSampler(TraceIdRatioBasedSampler(
                                          TELEMETRY_SAMPLING_RATIO, default 1.0)))
    Dockerfile                          (imagen sobre runtime, sin ingress)
    {Dominio}/                          (carpeta vacia por dominio ya registrado en el
                                          worker, si aplica -- ahi vive la clase de
                                          proyeccion companion de cada dominio)

  src/<RootNamespace>.ReadModels/       (biblioteca vacia, sin PackageReference a Marten;
                                          una carpeta por dominio ya registrado en el
                                          worker, si aplica -- solo read models planos)

  tests/<RootNamespace>.Projections.Tests/
    Infraestructura/AssertsProyecciones.cs   (helper AssertOpcionesDeEvento)
    ConfiguracionMartenProjectionsTests.cs   (config-test base, sin dominios todavia)
    ConfiguracionObservabilidadProjectionsTests.cs  (guardrails del sampler efectivo:
                                          tipo y Description del sampler que llega al
                                          TracerProvider, cascada daemon -> hijo Npgsql
                                          y nombre del span contra el OtelPrefix de Marten)

  .github/workflows/deploy-projections.yml
                                        (build + test, imagen al ACR del BC y
                                          az containerapp update; solo si el
                                          archivo no existe todavia. Requiere que
                                          infra/environments/dev/variables.tf ya
                                          exista, de donde salen los nombres del
                                          resource group y del Container App: si
                                          falta, el agente lo reporta pendiente y
                                          hay que correr /infra-base primero)

  .dockerignore                         (en la RAIZ del repo, que es el build context del
                                          Dockerfile: filtra bin/obj de todos los proyectos,
                                          settings locales, tfstate/tfvars, .terraform y
                                          node_modules -- Docker no lee .gitignore. Gate
                                          propio, independiente del Dockerfile: un repo que
                                          ya tenia Dockerfile tambien lo recibe. Solo si no
                                          existe todavia)

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
     adopte proyecciones dentro del seam ConfiguracionMartenProjections (no
     crea carpetas: las de los dominios ya existentes las dejo este scaffold,
     en ReadModels y en la raiz del worker).
  2. projection-test-writer/projection-implementer (issue #365) agregan sobre
     Projections.Tests las guardas por dominio (partial + ciclo de vida Async),
     reutilizando el helper AssertOpcionesDeEvento para la guarda barata de metadata (subconjunto de la
     compatibilidad; la completa la verifica el reviewer bajo gate, MEF-ADR-0034 seccion 6).
  3. Los modulos Terraform del Container App (container-registry,
     container-app-environment, container-app) son opt-in y los genera
     infra-base-scaffolder cuando corra de nuevo con el token ya habilitado
     (issue #368, MEF-ADR-0034 seccion 8).
  4. deploy-projections.yml solo publica la imagen despues de que infra-cd.yml
     haya sembrado los secretos del Key Vault al menos una vez (MEF-ADR-0034
     seccion 8, documentado en la cabecera del propio workflow). Si el agente lo
     reporto pendiente por falta de infra/environments/dev/variables.tf, corre
     /infra-base y vuelve a lanzar este skill: es idempotente.
```

## Reglas

- **No generes nada tu mismo.** Solo valida las dos pre-condiciones, informa y lanza el agente.
- El agente nunca registra un store de dominio, un read model concreto ni toca Azure Service Bus (MEF-ADR-0034 seccion 4): esa es responsabilidad de `domain-scaffolder`/`projection-implementer` de cada dominio, no de este skill.
- El agente es idempotente: no sobrescribe `Program.cs`, el seam de composicion, el config-test base ni el `.dockerignore` de la raiz si ya existen (pueden llevar registros o guardas de dominio agregados por `domain-scaffolder`/`projection-test-writer`, o exclusiones que el consumidor sumo a mano).
