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
echo "MEF-ADR-0011 en: $PLUGIN_ROOT/docs/adr/mef-adr-0011-definition-of-ready.md"
```

`.claude/pipeline/.plugin-root` lo escribe el hook `SessionStart` del plugin; el fallback localiza el plugin por glob sobre el cache del marketplace tomando la version mas reciente.

Aplica la validacion programatica definida en la seccion "Validacion en `/implement`" del ADR ubicado en `"$PLUGIN_ROOT/docs/adr/mef-adr-0011-definition-of-ready.md"` (la ruta absoluta que imprimio el bloque anterior). **Nunca abras la ruta relativa `docs/adr/...`**: con `cwd = repo consumidor` resolveria contra `<consumer>/docs/adr/...` (inexistente) y reportaria erroneamente "MEF-ADR-0011 ausente".

Extrae labels y body del issue:

```bash
gh issue view $ARGUMENTS --json labels,body
```

Determina el tipo del issue buscando el label `tipo:X`. Luego verifica **todos** los criterios que enumera esa seccion del MEF-ADR-0011 -- son los que esten escritos ahi al momento de correr, nunca una cantidad fija memorizada aqui -- y acumula todos los fallos antes de reportar.

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

### 2. Detectar dominio(s) y necesidad de scaffold

Extrae **todos** los labels `dom:X` del issue — nunca solo el primero: un issue `tipo:projection` puede declarar varios dominios reales cuyo read-side configura (MEF-ADR-0011, razonamiento de `dom:X`), y con mas de un label la respuesta no puede depender del orden en que la API de GitHub los devuelva.

```bash
gh issue view $ARGUMENTS --json labels -q '[.labels[].name | select(startswith("dom:")) | sub("^dom:";"")] | join("\n")'
```

- Si el resultado esta vacio (no hay ningun label `dom:*`): no hay dominios que verificar, salta al paso 4.
- Si hay uno o mas dominios: convierte cada uno a PascalCase (ej: `liquidacion-nomina` → `LiquidacionNomina`).

Para cada dominio, la necesidad de scaffold se deriva del **alcance declarado del issue**, nunca de la sola ausencia del directorio (un issue puede no tocar ese dominio en absoluto). Extrae la seccion de impacto en archivos del body — su titulo varia segun el template del planner (`## Impacto en archivos` en `infra`/`refactor`, `## Impacto esperado en archivos (sugerencia)` en `feature`/`projection`), asi que matchea por el prefijo `## Impacto`, nunca por el titulo exacto:

```bash
gh issue view $ARGUMENTS --json body -q '.body' \
  | awk '/^## /{en_impacto = ($0 ~ /^## Impacto/)} en_impacto'
```

Para cada dominio en PascalCase:
- Si esa seccion **no existe** en el body, o existe pero **no menciona** `src/<RootNamespace>.{PascalCase}/`: ese dominio no necesita scaffold — no preguntes por el, exista o no el directorio. La ausencia de declaracion se resuelve como "continuar sin scaffold" porque es la salida segura: si el pipeline realmente necesita el proyecto y no esta, falla de forma ruidosa en Stage 1, preferible a provisionar infraestructura de Azure por una prediccion incierta (`## Impacto en archivos` es solo **Recomendado** en `feature`/`projection` segun MEF-ADR-0011, asi que su ausencia es un caso normal, no un error del issue).
- Si **si la menciona**: verifica si el directorio ya existe (`test -d "src/<RootNamespace>.{PascalCase}/"`). Si existe, no necesita scaffold. Si NO existe, este dominio es **candidato a scaffold**.

- Si ningun dominio resulto candidato: salta al paso 4 sin preguntar nada.
- Si al menos uno resulto candidato: continua al paso 3 (una confirmacion por dominio candidato).

### 3. Confirmar scaffold del dominio (solo para los candidatos del paso 2)

Para cada dominio candidato, muestra al usuario exactamente lo que se va a crear y ofrece tres salidas — nunca solo "si/no":

```
El dominio "{kebab}" no tiene proyecto aun, pero el issue declara impacto en:
  src/<RootNamespace>.{PascalCase}/

Elegi una opcion:
  1) Scaffoldear el dominio antes de lanzar el pipeline:
       - Function App:  src/<RootNamespace>.{PascalCase}/
       - Tests:         tests/<RootNamespace>.{PascalCase}.Tests/
       - Terraform:     infra/environments/dev/dominio-{kebab}.tf (storage + function app)
       - Workflow:      .github/workflows/deploy-{kebab}.yml
     El scaffold se hara en el mismo worktree del issue — el PR incluira ambos.
  2) Continuar sin scaffold: lanzar el pipeline igual, sin crear el proyecto del dominio.
     Si el pipeline realmente necesita el directorio, fallara de forma ruidosa en Stage 1 —
     preferible a provisionar infraestructura de Azure por una prediccion incierta.
  3) Abortar: no lanzar el pipeline.

¿Que opcion elegis? (1/2/3)
```

- **Opcion 1 (scaffoldear)**: correcta cuando el dominio es genuinamente nuevo y el issue lo confirma (ej: primer issue `feature`/`projection` de un dominio recien incorporado al Bounded Context). Establece `SCAFFOLD_FLAG="--scaffold-domain {kebab}"` y continua al paso 4.
- **Opcion 2 (continuar sin scaffold)**: correcta cuando no hay certeza de que el dominio necesite proyecto propio — "Impacto en archivos" es una sugerencia del planner (`agents/planner.md`), no una especificacion cerrada, y el pipeline puede desviarse. No agrega `SCAFFOLD_FLAG` y continua al paso 4 igual.
- **Opcion 3 (abortar)**: correcta cuando el dominio si hace falta pero el usuario no quiere autorizar la creacion de infraestructura Azure en este momento. Responde que no se lanza el pipeline y detente.

Si hay mas de un dominio candidato, repite esta confirmacion por cada uno antes de pasar al paso 4. **Nota de limitacion**: `tmux-pipeline.sh`/`tdd-pipeline.sh` solo aceptan un `--scaffold-domain` por invocacion. Si mas de un dominio candidato termina en la opcion 1, informa esta limitacion y sugiere scaffoldear los adicionales por separado con `/scaffold` antes de lanzar `/implement`.

### 4. Mostrar info y lanzar

Muestra una linea con el issue (si hay varios dominios, listalos separados por coma):

```
#42: Implementar calculo de horas extras nocturnas
Dominio: Liquidacion | Tipo: feature | Estado: listo
```

Con varios labels `dom:` (tipico en un issue `projection` que configura el read-side de mas de un dominio):

```
#87: Registrar el named store de programacion y control-horas en el worker
Dominio: Programacion, ControlHoras | Tipo: projection | Estado: listo
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

Dentro de herdr (`HERDR_ENV=1` en el entorno), el script delega en la interfaz herdr y no hay nada que adjuntar: el pipeline queda corriendo en un pane de este mismo workspace con el visor en vivo del agente. En ese caso responde con:

```
Pipeline corriendo en un pane de este workspace (visor en vivo del agente).
Usa /work-status para ver el progreso sin salir de aqui.
```

Fuera de herdr responde con:

```
Pipeline lanzado en tmux. Para monitorear:
  tmux -CC attach -t tdd-<numero>

Usa /work-status para ver el progreso sin salir de aqui.
```

## Reglas

- **No esperes a que termine.** El script corre en background (en un pane herdr o una sesion tmux). Devuelve el control inmediatamente.
- **No implementes nada tu mismo.** Solo lanza el script.
- **Nunca crees un dominio sin confirmacion explicita del usuario.** La creacion implica Terraform e infraestructura en Azure.
- El scaffold se ejecuta dentro del worktree del issue (Stage 0), no en main. Todo va en un solo PR.
- Si tmux no esta instalado (y no estas dentro de herdr), el script lo detecta y muestra el error. No intentes instalarlo.
