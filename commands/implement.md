---
model: haiku
---

Lanza el pipeline TDD para un issue de GitHub dentro de una sesion tmux. Comunicate en **espanol**.

## Pre-condicion: cwd != Mefisto

Este skill es del plugin publicado y solo aplica al repo consumidor (no a Mefisto). Verifica antes de continuar:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /implement es del plugin publicado y no aplica al repo de Mefisto."
    echo "Mefisto no es un proyecto .NET con TDD de dominio. Para mejorar el plugin, usa /mefisto-tooling."
    exit 1
fi
```

## Entrada

El numero de issue esta en: $ARGUMENTS

Si `$ARGUMENTS` esta vacio, responde: `Uso: /implement <numero-de-issue>`

## Proceso

### 1. Validar el issue

```bash
gh issue view $ARGUMENTS --json number,title,state,labels -q '"#\(.number): \(.title) [\(.state)] labels: \([.labels[].name] | join(", "))"'
```

Si el issue no existe o esta cerrado (`CLOSED`), informa y detente.

### 1.5. Validar Definition of Ready

Resuelve primero la raiz del plugin — los ADRs del marco viven **dentro del plugin instalado**, no en el repo consumidor donde corre el skill (`cwd = repo consumidor`):

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_ROOT="${PLUGIN_ROOT%/}"   # normaliza: sin barra final
echo "ADR-0011 en: $PLUGIN_ROOT/docs/adr/0011-definition-of-ready.md"
```

`.claude/pipeline/.plugin-root` lo escribe el hook `SessionStart` del plugin; el fallback localiza el plugin por glob sobre el cache del marketplace tomando la version mas reciente.

Aplica la validacion programatica definida en la seccion "Validacion en `/implement`" del ADR ubicado en `"$PLUGIN_ROOT/docs/adr/0011-definition-of-ready.md"` (la ruta absoluta que imprimio el bloque anterior). **Nunca abras la ruta relativa `docs/adr/...`**: con `cwd = repo consumidor` resolveria contra `<consumer>/docs/adr/...` (inexistente) y reportaria erroneamente "ADR-0011 ausente".

Extrae labels y body del issue:

```bash
gh issue view $ARGUMENTS --json labels,body
```

Determina el tipo del issue buscando el label `tipo:X`. Luego verifica los 5 criterios del ADR-0011 y acumula todos los fallos antes de reportar.

Si **uno o mas criterios fallan**: muestra la lista completa de lo que falta, sugiere `claude --agent planner` en modo `refinar` para completarlos, y **detente**.

Si **todos los criterios pasan**: continua al paso 1.6.

### 1.6. Verificar label bloqueado

Si el issue tiene el label `bloqueado`, lee la seccion `## Dependencias` del body y extrae todos los numeros de issue/PR referenciados (patron `#NNN`).

Para cada referencia, consulta su estado:

```bash
gh issue view <num> --json state -q '.state'
gh pr view <num> --json state -q '.state'
```

- Si **todas** las dependencias estan cerradas (`CLOSED`) o mergeadas (`MERGED`): quita el label y continua:

```bash
gh issue edit $ARGUMENTS --remove-label "bloqueado"
```

- Si **alguna** dependencia sigue abierta: muestra cuales y **detente**:

```
El issue #$ARGUMENTS esta bloqueado. Dependencias abiertas:
  - #42: [titulo] (OPEN)
  - #55: [titulo] (OPEN)

Resuelve estas dependencias antes de lanzar el pipeline.
```

### 2. Detectar dominio

Extrae el label `dom:X` del issue:

```bash
gh issue view $ARGUMENTS --json labels -q '[.labels[].name | select(startswith("dom:"))] | first // empty' | sed 's/^dom://'
```

- Si el resultado esta vacio (no hay label `dom:*`): establece `DOMINIO_KEBAB=""` y salta al paso 4.
- Si hay dominio: conviertelo a PascalCase (ej: `liquidacion-nomina` → `LiquidacionNomina`) y verifica si el proyecto existe:

```bash
test -d "src/<RootNamespace>.{PascalCase}/"
```

- Si el directorio existe: salta al paso 4.
- Si NO existe: continua al paso 3.

### 3. Confirmar scaffold del dominio (solo si no existe)

Muestra al usuario exactamente lo que se va a crear y pregunta de forma explicita:

```
El dominio "{kebab}" no tiene proyecto aun.
Se necesita crear el scaffold antes de lanzar el pipeline:
  - Function App:  src/<RootNamespace>.{PascalCase}/
  - Tests:         tests/<RootNamespace>.{PascalCase}.Tests/
  - Terraform:     infra/environments/dev/dominio-{kebab}.tf (storage + function app)
  - Workflow:      .github/workflows/deploy-{kebab}.yml

El scaffold se hara en el mismo worktree del issue — el PR incluira ambos.
¿Creo el dominio antes de lanzar el pipeline? (s/n)
```

**Si el usuario dice no**: responde que no es posible continuar sin el proyecto del dominio y detente.

**Si el usuario dice si**: establece `SCAFFOLD_FLAG="--scaffold-domain {kebab}"` y continua al paso 4.

### 4. Mostrar info y lanzar

Muestra una linea con el issue:

```
#42: Implementar calculo de horas extras nocturnas
Dominio: Liquidacion | Tipo: feature | Estado: listo
```

Si se hara scaffold, agrega:

```
Scaffold del dominio "{kebab}" incluido en el pipeline (Stage 0 antes de TDD).
```

Luego lanza el pipeline en tmux:

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"

# Sin scaffold nuevo:
"$PLUGIN_SCRIPTS/tmux-pipeline.sh" $ARGUMENTS

# Con scaffold:
"$PLUGIN_SCRIPTS/tmux-pipeline.sh" $ARGUMENTS --scaffold-domain {kebab}
```

### 5. Instrucciones de conexion

Responde con:

```
Pipeline lanzado en tmux. Para monitorear:
  tmux -CC attach -t tdd-<numero>

Usa /work-status para ver el progreso sin salir de aqui.
```

## Reglas

- **No esperes a que termine.** El script corre en background dentro de tmux. Devuelve el control inmediatamente.
- **No implementes nada tu mismo.** Solo lanza el script.
- **Nunca crees un dominio sin confirmacion explicita del usuario.** La creacion implica Terraform e infraestructura en Azure.
- El scaffold se ejecuta dentro del worktree del issue (Stage 0), no en main. Todo va en un solo PR.
- Si tmux no esta instalado, el script lo detecta y muestra el error. No intentes instalarlo.
