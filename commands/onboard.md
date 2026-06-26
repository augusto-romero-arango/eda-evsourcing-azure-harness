Diagnostica el onboarding del consumidor: valida `.claude/harness.config.json`, los labels y el CI, y reporta un checklist de que esta listo y que falta. Es un **doctor de solo lectura**: no crea ni modifica nada (ni labels, ni archivos, ni recursos de Azure). Comunicate en **espanol**.

## Pre-condicion: cwd != Mefisto

Este skill es del plugin publicado y solo aplica al repo consumidor. Mefisto es el harness: no tiene `harness.config.json`, ni labels de dominio, ni CI hacia Azure que diagnosticar.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /onboard no aplica al repo de Mefisto."
    exit 1
fi
```

Si el bloque imprime `ERROR`, detente y muestra el mensaje al usuario.

## Que verifica

`/onboard` es el primer corte del onboarding automatizado (el "doctor" diagnostico). Reporta, sin tocar nada:

1. **Configuracion** (`.claude/harness.config.json`): existencia, parseo con `jq`, campos requeridos (`projectName`, `namespacePrefix`, `solutionFile`) y formato de `terraformStateStorage`. La validacion la hace `load_harness_config` del plugin, que es la **unica fuente de verdad** de la regla del tfstate (`^[a-z0-9]{3,24}$`).
2. **Labels de GitHub** (ADR-0007): que existan `tipo:*`, `estado:borrador`, `estado:listo`, `dom:<x>` por cada `domainLabels`, mas `bug` y `bloqueado`.
3. **CI hacia Azure** (ADR-0022): que exista la aplicacion de Entra / Service Principal y los secrets OIDC del repo. Tolerante: si no hay `az` o sesion, reporta `NO VERIFICADO` en vez de fallar.

La provision real (crear labels, crear el Service Principal) la cubren los seguimientos del onboarding (79b para labels, 79c para CI); `/onboard` solo diagnostica.

## Proceso

### 1. Ejecutar el diagnostico

Corre este bloque tal cual. Resuelve la raiz del plugin (para reusar `load_harness_config`) y ejecuta el diagnostico bajo `bash` para garantizar su semantica (arrays, word-splitting de `domainLabels`) sin depender del shell interactivo:

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_COMMON="${PLUGIN_ROOT%/}/scripts/_pipeline-common.sh"
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"

PLUGIN_COMMON="$PLUGIN_COMMON" PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" bash <<'ONBOARD'
set +e

CONFIG=".claude/harness.config.json"
N_OK=0; N_FALTA=0; N_NV=0
ACTIONS=""

row() {
  estado="$1"; shift; item="$*"
  case "$estado" in
    OK)    N_OK=$((N_OK+1)) ;;
    FALTA) N_FALTA=$((N_FALTA+1)) ;;
    *)     N_NV=$((N_NV+1)); estado="NO VERIFICADO" ;;
  esac
  printf '  [%-13s] %s\n' "$estado" "$item"
}

# Guard defensivo (cwd != Mefisto), por si el bloque se ejecuta aislado.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
  echo "ERROR: /onboard no aplica al repo de Mefisto."; exit 1
fi

echo "===================================================================="
echo "  /onboard - diagnostico del harness (solo lectura)"
echo "===================================================================="
echo ""

# --- 1. Configuracion: reusa load_harness_config (#78 = fuente de verdad) ---
echo "Configuracion (.claude/harness.config.json):"
if [ -n "${PLUGIN_COMMON:-}" ] && [ -f "${PLUGIN_COMMON:-}" ]; then
  source "$PLUGIN_COMMON" >/dev/null 2>&1
  LHC_TMP=$(mktemp 2>/dev/null || echo "/tmp/onboard-lhc.$$")
  load_harness_config >/dev/null 2>"$LHC_TMP"
  LHC_RC=$?
  LHC_ERR=$(cat "$LHC_TMP" 2>/dev/null); rm -f "$LHC_TMP"
  if [ "$LHC_RC" -eq 0 ]; then
    row OK "el archivo existe y parsea con jq"
    row OK "campos requeridos presentes (projectName, namespacePrefix, solutionFile)"
    if [ -n "${HARNESS_TFSTATE_STORAGE:-}" ]; then
      row OK "terraformStateStorage valido: ${HARNESS_TFSTATE_STORAGE}"
    else
      row OK "terraformStateStorage vacio (consumidor sin IaC; valido)"
    fi
  else
    row FALTA "configuracion invalida o incompleta"
    printf '%s\n' "$LHC_ERR" | while IFS= read -r l; do [ -n "$l" ] && echo "                  $l"; done
    ACTIONS="${ACTIONS}  - Corrige .claude/harness.config.json segun el detalle de arriba (README, seccion \"Configurar el consumidor\").
"
  fi
else
  row NV "no se hallo load_harness_config del plugin (config sin validar)"
  if [ -f "$CONFIG" ]; then echo "                  (el archivo $CONFIG si existe)"; else echo "                  (el archivo $CONFIG no existe)"; fi
  ACTIONS="${ACTIONS}  - No se pudo resolver el plugin para reusar load_harness_config; reinstala mefisto o reabre la sesion (hook SessionStart).
"
fi

# --- 2. Labels de GitHub (ADR-0007) ---
echo ""
echo "Labels de GitHub (esquema del harness - ADR-0007):"
EXISTING=$(gh label list --json name -q '.[].name' 2>/dev/null)
GH_RC=$?
if [ "$GH_RC" -ne 0 ]; then
  row NV "no se pudieron listar los labels (gh no autenticado / sin repo / version antigua)"
  ACTIONS="${ACTIONS}  - Autentica gh (\"gh auth login\") y reintenta para diagnosticar los labels.
"
else
  MISSING=""
  for lbl in tipo:feature tipo:infra tipo:refactor tipo:tooling estado:borrador estado:listo bug bloqueado; do
    printf '%s\n' "$EXISTING" | grep -Fqx "$lbl" || MISSING="$MISSING $lbl"
  done
  if [ -n "${HARNESS_DOMAIN_LABELS:-}" ]; then
    for dom in $HARNESS_DOMAIN_LABELS; do
      printf '%s\n' "$EXISTING" | grep -Fqx "dom:$dom" || MISSING="$MISSING dom:$dom"
    done
  fi
  if [ -z "$MISSING" ]; then
    row OK "esquema completo (tipo:*, estado:*, dom:*, bug, bloqueado)"
  else
    row FALTA "faltan labels:$MISSING"
    ACTIONS="${ACTIONS}  - Crea los labels faltantes con \"$PLUGIN_SCRIPTS/setup-github-labels.sh\" (la provision automatizada llega en el seguimiento 79b). /onboard NO los crea.
"
  fi
  if [ -z "${HARNESS_DOMAIN_LABELS:-}" ]; then
    echo "                  (dom:* no verificado - domainLabels vacio o config no cargada)"
  fi
fi

# --- 3. CI hacia Azure (ADR-0022) ---
echo ""
echo "CI hacia Azure (OIDC / Service Principal - ADR-0022):"
if ! command -v az >/dev/null 2>&1; then
  row NV "Service Principal de CI (Azure CLI no instalado)"
  ACTIONS="${ACTIONS}  - Instala Azure CLI y ejecuta \"az login\" para verificar el Service Principal del CI.
"
elif ! az account show >/dev/null 2>&1; then
  row NV "Service Principal de CI (sin sesion de Azure)"
  ACTIONS="${ACTIONS}  - Ejecuta \"az login\" para que /onboard pueda verificar el Service Principal del CI.
"
elif [ -z "${HARNESS_SP_NAME:-}" ]; then
  row NV "Service Principal de CI (githubServicePrincipalName ausente en el config)"
else
  APP_ID=$(az ad app list --display-name "$HARNESS_SP_NAME" --query "[0].appId" -o tsv 2>/dev/null)
  if [ -n "$APP_ID" ] && [ "$APP_ID" != "None" ]; then
    row OK "aplicacion de Entra \"$HARNESS_SP_NAME\" existe (appId $APP_ID)"
  else
    row FALTA "aplicacion de Entra \"$HARNESS_SP_NAME\" no encontrada"
    ACTIONS="${ACTIONS}  - Configura el CI con \"$PLUGIN_SCRIPTS/setup-github-ci.sh <subscription-id>\" (la provision automatizada llega en el seguimiento 79c). /onboard NO lo crea.
"
  fi
fi

# Secrets OIDC del repo (lectura tolerante; requiere admin del repo)
SECRETS=$(gh secret list 2>/dev/null)
GS_RC=$?
if [ "$GS_RC" -ne 0 ]; then
  row NV "secrets OIDC en GitHub (no se pudieron listar; requiere permisos de admin del repo)"
else
  MISS_S=""
  for s in AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID; do
    printf '%s\n' "$SECRETS" | awk '{print $1}' | grep -Fqx "$s" || MISS_S="$MISS_S $s"
  done
  if [ -z "$MISS_S" ]; then
    row OK "secrets OIDC presentes (AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID)"
  else
    row FALTA "faltan secrets OIDC:$MISS_S"
    ACTIONS="${ACTIONS}  - Copia los tres secrets que imprime \"$PLUGIN_SCRIPTS/setup-github-ci.sh\" a Settings > Secrets and variables > Actions (seguimiento 79c).
"
  fi
fi

# --- 4. Acciones y resumen ---
echo ""
if [ -n "$ACTIONS" ]; then
  echo "Acciones sugeridas (ninguna la ejecuta /onboard; es solo diagnostico):"
  printf '%s' "$ACTIONS"
  echo ""
fi
echo "===================================================================="
echo "  Resumen: $N_OK OK | $N_FALTA FALTA | $N_NV NO VERIFICADO"
if [ "$N_FALTA" -eq 0 ] && [ "$N_NV" -eq 0 ]; then
  echo "  Estado: LISTO - el harness esta configurado."
elif [ "$N_FALTA" -eq 0 ]; then
  echo "  Estado: LISTO con salvedades - revisa los NO VERIFICADO."
else
  echo "  Estado: INCOMPLETO - resuelve los FALTA antes de usar los pipelines."
fi
echo "===================================================================="
ONBOARD
```

### 2. Presentar el resultado

Muestra al usuario la salida del checklist tal como la imprimio el bloque (el formato ya esta consolidado). Luego, en una o dos lineas:

- Si el estado es **LISTO**: confirma que el harness esta configurado y sugiere el siguiente paso del flujo greenfield (`/mefisto:infra-base` o `/mefisto:scaffold <dominio>`, segun corresponda).
- Si el estado es **LISTO con salvedades** o **INCOMPLETO**: resume cuantos `FALTA`/`NO VERIFICADO` hay y recuerda que las acciones sugeridas son los comandos que los resuelven.

No reinterpretes ni recalcules el checklist: el bloque ya hizo el diagnostico.

## Reglas

- **Solo lectura.** Nunca ejecutes `gh label create`, `az ... create`, ni escribas archivos o recursos. Si el usuario quiere provisionar, apuntalo a los comandos de las "Acciones sugeridas" (los seguimientos 79b/79c automatizaran esa provision).
- **No abortes ante un fallo parcial.** Cada seccion del diagnostico es independiente: si `gh` o `az` no estan disponibles, reporta `NO VERIFICADO` y continua con el resto.
- **No dupliques la validacion del config.** El formato de `terraformStateStorage` y los campos requeridos los valida `load_harness_config` (issue #78); este skill solo reporta su resultado.
- Si `$ARGUMENTS` trae algo, ignoralo: `/onboard` no toma argumentos.
