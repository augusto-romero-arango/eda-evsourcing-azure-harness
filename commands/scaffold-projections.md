---
model: haiku
---

Genera el worker de proyecciones `<RootNamespace>.Projections` (daemon asincronico `HotCold` de Marten) invocando al agente `projections-scaffolder`, al estilo de `infra-base-scaffolder`. **Alcance acotado (fase 1, issue #367)**: solo el worker y su cableado en la solucion -- el proyecto `ReadModels` y el `Projections.Tests` base son fase 2 (issue #375), y el registro del store de cada dominio lo hace `domain-scaffolder` (issue #370). Comunicate en **espanol**.

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

El worker solo se genera si el BC declaro explicitamente que adopta proyecciones. El token vive en `.claude/harness.config.json` bajo `projections.enabled` -- mecanismo de deteccion que fija MEF-ADR-0034 (seccion 8); su contrato formal completo en `harness.config.json` (validacion, `/onboard`, etc.) es alcance del issue #369, todavia no implementado. Mientras tanto, este skill consume el token en la forma minima que necesita:

```bash
RAW=$(jq -r '.projections.enabled' "$REPO_ROOT/.claude/harness.config.json" 2>/dev/null)
if [ "$RAW" != "true" ]; then
    if [ -z "$RAW" ] || [ "$RAW" == "null" ]; then
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
    echo "(token provisional consumido por este skill -- su contrato formal, incluida la"
    echo "validacion y el reporte de /onboard, los fija el issue #369)."
    exit 1
fi
```

Si `RAW` es `"true"`, continua.

## Proceso

### 1. Informar que se va a generar

```
Se va a generar el worker de proyecciones (fase 1, issue #367):

  src/<RootNamespace>.Projections/
    <RootNamespace>.Projections.csproj  (SDK Microsoft.NET.Sdk.Worker)
    Program.cs                          (arma el host, invoca el seam, nada mas)
    Infraestructura/ConfiguracionMartenProjections.cs  (seam base, sin dominios todavia)
    Dockerfile                          (imagen sobre runtime, sin ingress)

  <SolutionFile>: se agrega el proyecto nuevo
  global.json: se verifica/crea la seccion "test"

Este agente NO registra ningun store de dominio (eso lo hace domain-scaffolder,
issue #370) NI genera el proyecto ReadModels ni Projections.Tests (fase 2,
issue #375). Es idempotente: re-ejecutar no duplica ni pisa contenido existente.
```

### 2. Lanzar el agente

```bash
claude --agent projections-scaffolder "Genera el worker de proyecciones."
```

### 3. Tras terminar

Recuerda al usuario el resto de la cadena de issues relacionados:

```
Worker de proyecciones generado. Siguiente:
  1. domain-scaffolder (issue #370) registra el named store de cada dominio que
     adopte proyecciones dentro del seam ConfiguracionMartenProjections.
  2. El proyecto <RootNamespace>.ReadModels y el config-test
     <RootNamespace>.Projections.Tests son fase 2 (issue #375).
  3. Los modulos Terraform del Container App (container-registry,
     container-app-environment, container-app) son opt-in y los genera
     infra-base-scaffolder cuando corra de nuevo con el token ya habilitado
     (issue #368, MEF-ADR-0034 seccion 8).
```

## Reglas

- **No generes el worker tu mismo.** Solo valida las dos pre-condiciones, informa y lanza el agente.
- El agente nunca registra un store de dominio ni toca Azure Service Bus (MEF-ADR-0034 seccion 4): esa es responsabilidad de `domain-scaffolder`/`implementer` de cada dominio, no de este skill.
- El agente es idempotente: no sobrescribe `Program.cs` ni el seam de composicion si ya existen (pueden llevar registros de dominio agregados por `domain-scaffolder`).
