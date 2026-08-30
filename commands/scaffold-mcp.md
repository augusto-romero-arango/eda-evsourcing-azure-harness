---
model: haiku
---

Lanza el agente `mcp-scaffolder`, que genera el proyecto de un servidor MCP (Model Context Protocol) `<RootNamespace>.Mcp.{Proposito}` para el Bounded Context del consumidor -- fases 1, 2 y 3 (issues #768/#769/#770): proyecto del servidor, tool de ejemplo, endpoints de gate, unit tests base, el Terraform del servidor, el workflow de deploy y la suite SmokeTests e2e con su reusable de CI (MEF-ADR-0047/MEF-ADR-0048). Comunicate en **espanol**.

## Pre-condicion 1: cwd != Mefisto

Este skill es del plugin publicado y solo aplica al repo consumidor. Mefisto no expone servidores MCP sobre si mismo. Verifica antes de continuar:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /scaffold-mcp no aplica al repo de Mefisto."
    exit 1
fi
```

## Pre-condicion 2: argumento `<proposito>`

`$ARGUMENTS` debe traer el proposito del servidor (una palabra o frase corta, ej. `Consultas`, `Comandos`, `consultas-turnos`). Si esta vacio, responde y detente:

```
Uso: /scaffold-mcp <proposito>

Ejemplos:
  /scaffold-mcp Consultas
  /scaffold-mcp Comandos

El proposito distingue servidores MCP del mismo BC (particion Consultas/Comandos por
credencial, MEF-ADR-0047 seccion 2). Se normaliza a PascalCase: "consultas-turnos" ->
"ConsultasTurnos".
```

Si trae argumento, normaliza `<proposito>` a PascalCase (separa por espacios/guiones, mayuscula inicial de cada palabra, sin separadores) y guardalo como `PROPOSITO_PASCAL`.

## Pre-condicion 3: config y tokens del harness

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
CONFIG="$REPO_ROOT/.claude/harness.config.json"
if [ ! -f "$CONFIG" ]; then
    echo "ERROR: no existe .claude/harness.config.json. Corre /onboard antes de este skill."
    exit 1
fi

ROOT_NAMESPACE=$(jq -r '.namespacePrefix // ""' "$CONFIG")
SOLUTION_FILE=$(jq -r '.solutionFile // ""' "$CONFIG")

if [ -z "$ROOT_NAMESPACE" ] || [ -z "$SOLUTION_FILE" ]; then
    echo "ERROR: faltan 'namespacePrefix' y/o 'solutionFile' en .claude/harness.config.json."
    exit 1
fi
```

Si falta cualquiera de los dos, detente con el mensaje de arriba. Con `ROOT_NAMESPACE` y `PROPOSITO_PASCAL`, el proyecto a generar sera `${ROOT_NAMESPACE}.Mcp.${PROPOSITO_PASCAL}`.

## Proceso

### 1. Informar que se va a generar

```
Se va a generar el servidor MCP <RootNamespace>.Mcp.{Proposito} (fases 1, 2 y 3, issues #768/#769/#770):

  src/<RootNamespace>.Mcp.{Proposito}/
    <RootNamespace>.Mcp.{Proposito}.csproj  (cero ProjectReference, cliente HTTP puro)
    host.json                                (extensions.mcp: serverName/instructions)
    Program.cs                               (invoca los dos seams: HttpClients + observabilidad)
    Infraestructura/                         (RespuestaJson, seams, {Dominio}Api, FiltroDeNombre)
    VersionCheck.cs / ReadyCheck.cs          (endpoints de gate, MEF-ADR-0048 seccion 3)
    Ejemplo/                                 (tool de ejemplo con el patron completo)
    README.md                                (onboarding del servidor)

  tests/<RootNamespace>.Mcp.{Proposito}.Tests/
    ComposicionDelServidorTests.cs           (nivel 2 de la piramide, MEF-ADR-0048 seccion 1)
    Ejemplo/EjemploListarToolTests.cs         (nivel 1: remodelado con handler falso)

  tests/<RootNamespace>.Mcp.{Proposito}.SmokeTests/
    Fixtures/McpFixture.cs                   (sesion MCP real con ModelContextProtocol.Core)
    Handshake/ ComposicionDelHost/ Ejemplo/ Seguridad/
                                             (nivel 3: las cinco verificaciones canonicas de
                                              MEF-ADR-0048 seccion 2 -- handshake, tools/list
                                              vivo, tool call, error path del .resx, 401 sin key)

  infra/environments/dev/mcp-{proposito-kebab}.tf
    Storage + App Service Plan + Function App dedicados (modulos base del consumidor),
    con las app settings Api__{Dominio}__BaseUrl de los dominios ya scaffoldeados
  infra/modules/function-app/main.tf: se agrega el output default_hostname si falta

  .github/workflows/deploy-mcp-{proposito-kebab}.yml
    encadenado por workflow_run tras el apply de infra (MEF-ADR-0022), con el job
    smoke-tests encadenado tras el deploy
  .github/workflows/smoke-tests-mcp.yml
    reusable compartido por los servidores MCP del BC: warmup version+ready, OIDC y la
    key mcp_extension listada en runtime (MEF-ADR-0048 seccion 4)

  <SolutionFile>: se agregan los tres proyectos nuevos
  global.json: se verifica/crea la seccion "test" (xunit v3 mtp-v2)

La suite SmokeTests compila en el CI de PRs pero solo se ejecuta contra el entorno desplegado
(el sufijo .SmokeTests queda fuera del glob tests/*.Tests/). Es idempotente: re-ejecutar no
duplica ni pisa contenido existente.
```

### 2. Lanzar el agente

```bash
claude --agent mcp-scaffolder "Genera el servidor MCP de proposito '${PROPOSITO_PASCAL}'."
```

### 3. Tras terminar

Responde con:

```
Servidor MCP <RootNamespace>.Mcp.{Proposito} generado. Siguiente:
  1. Reemplaza la tool 'Ejemplo/' por las tools reales de tu BC (lenguaje ubicuo, MEF-ADR-0040)
     y actualiza con ellas los asserts pinneados de la suite SmokeTests.
  2. Revisa y aplica el Terraform generado con /infra (el deploy del codigo se encadena solo).
  3. La suite SmokeTests corre por primera vez en el job 'smoke-tests' de ese primer deploy:
     el scaffold solo la compila (todavia no hay servidor desplegado contra el cual correrla).
  4. Onboarding de un cliente MCP: ver el README.md generado en el proyecto del servidor.
```

## Reglas

- **No generes nada tu mismo.** Solo valida las pre-condiciones, informa y lanza el agente.
- El agente es idempotente: no sobrescribe ningun artefacto ya generado (Program.cs, los seams, la tool de ejemplo si ya fue reemplazada, el README) -- ver `mcp-scaffolder.md`.
- Nunca inventes el proposito: si el usuario no lo da, pregunta o muestra el uso de arriba.
