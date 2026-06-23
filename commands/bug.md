Investiga un error o sintoma reportado. Clasifica automaticamente si es un bug de tooling local o del entorno desplegado, y enruta al agente apropiado. Comunicate en **espanol**.

## Pre-condicion: cwd != Mefisto

Este skill es del plugin publicado y solo aplica al repo consumidor. Para bugs del propio plugin, usa `/mefisto-bug`:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /bug no aplica al repo de Mefisto. Usa /mefisto-bug para diagnosticar problemas del plugin."
    exit 1
fi
```

## Entrada

El sintoma esta en: $ARGUMENTS

Si `$ARGUMENTS` esta vacio, responde: `Uso: /bug [descripcion del sintoma]` y termina.

## Proceso

### 1. Parsear flags explicitos

Extrae flags de `$ARGUMENTS`:
- Si contiene `--tooling`: enrutar directamente a `tooling-investigator`. Elimina el flag del sintoma.
- Si contiene `--deployed`: enrutar directamente a `bug-investigator`. Elimina el flag del sintoma.
- Si hay flag explicito, salta al paso 4 (sin clasificacion heuristica).

### 2. Clasificar por heuristica (case-insensitive, busqueda de substrings)

**Indicadores de tooling**:
`pipeline`, `skill`, `agente`, `tmux`, `script`, `/implement`, `/tooling`, `status`, `.claude/`, `worktree`, `tooling-status`, `pipeline-status`

**Indicadores de entorno desplegado**:
`produccion`, `excepcion`, `Service Bus`, `dead letter`, `Function App`, `timeout`, `500`, `App Insights`, `NullReferenceException`

Busca coincidencias del sintoma contra ambas listas.

### 3. Resolver ambiguedad

- Si **solo** hay indicadores de tooling -> enrutar a `tooling-investigator`
- Si **solo** hay indicadores de entorno desplegado -> enrutar a `bug-investigator`
- Si hay indicadores de **ambas** categorias, o **ninguna** -> preguntar al usuario:

```
No puedo determinar automaticamente el tipo de bug.

El sintoma: "$ARGUMENTS"

Es un bug de:
1. **Tooling local** (pipelines, skills, agentes, scripts, worktrees)
2. **Entorno desplegado** (Azure Functions, Service Bus, App Insights)

Responde 1 o 2.
```

Espera la respuesta del usuario antes de continuar.

### 4. Enrutar al agente

#### Si tooling:

Lanza el agente sin validar prerequisitos de Azure:

```bash
claude --agent tooling-investigator "Sintoma reportado: [SINTOMA SIN FLAGS]"
```

Responde con:

```
Agente tooling-investigator lanzado.
Sintoma: [SINTOMA]

El agente investigara scripts, pipelines, skills y agentes locales,
y te presentara hipotesis antes de tomar accion.
```

#### Si entorno desplegado:

Valida prerequisitos de Azure:

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

```bash
az account show --query name -o tsv 2>/dev/null
```

Si falla, responde:

```
No hay sesion activa de Azure. Ejecuta:
  az login
```

Si ambas validaciones pasan, lanza el agente:

```bash
claude --agent bug-investigator "Sintoma reportado: [SINTOMA SIN FLAGS]"
```

Responde con:

```
Agente bug-investigator lanzado.
Sintoma: [SINTOMA]

El agente investigara en App Insights, correlacionara con el codigo
y te presentara hipotesis antes de tomar accion.
```

## Reglas

- **No investigues nada tu mismo.** Solo clasifica, valida y lanza el agente.
- **No modifiques codigo.** Ningun agente puede hacerlo.
