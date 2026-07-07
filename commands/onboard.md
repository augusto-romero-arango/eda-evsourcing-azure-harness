---
model: haiku
---

Diagnostica el onboarding del consumidor: valida `.claude/harness.config.json`, los labels y el CI, y reporta un checklist de que esta listo y que falta. Es un **doctor**: por defecto solo diagnostica (no crea ni modifica nada). Como excepciones **opt-in**, si lo confirmas explicitamente puede provisionar los labels faltantes (el script subyacente es destructivo: borra los labels default de GitHub) y configurar el CI hacia Azure (crea recursos reales en Azure -- app de Entra, role assignments y federated credential, por OIDC; ver ADR-0022). Comunicate en **espanol**.

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

1. **Configuracion** (`.claude/harness.config.json`): existencia, parseo con `jq`, campos requeridos (`projectName`, `namespacePrefix`, `solutionFile`, `boundedContext`) y formato de `terraformStateStorage`. La validacion la hace `load_harness_config` del plugin, que es la **unica fuente de verdad** de las reglas del tfstate (`^[a-z0-9]{3,24}$`) y del BC (`name` 1-63 chars; `domains` subconjunto de `domainLabels`).
2. **Tokens del harness en `CLAUDE.md`** (contrato del harness, "Contrato con el proyecto consumidor" punto 2): que el `CLAUDE.md` raiz del consumidor tenga la seccion "Tokens del harness" con los 5 tokens obligatorios (`RootNamespace`, `SolutionFile`, `ProjectDisplayName`, `BoundedContext`, `BoundedContextDomains`). Es un artefacto separado de `harness.config.json`: los agentes/skills resuelven estos placeholders leyendo `CLAUDE.md` porque no pueden hacer sustitucion de variables. Reporta `NO VERIFICADO` si no hay un `CLAUDE.md` legible en la raiz.
3. **Estructura de carpetas esperada** (contrato del harness, punto 3): reporta de forma **informativa** (no bloqueante) la presencia de `src/`, `tests/` e `infra/environments/`. No la marca como `FALTA` cuando falta: un greenfield legitimo aun no tiene estas carpetas antes del primer `/scaffold` o `/infra-base`, y tratarla como bloqueante daria un falso negativo.
4. **Labels de GitHub** (ADR-0007): que existan `tipo:*`, `estado:borrador`, `estado:listo`, `dom:<x>` por cada `domainLabels`, mas `bug` y `bloqueado`.
5. **CI hacia Azure** (ADR-0022): que exista la aplicacion de Entra / Service Principal y los secrets OIDC del repo. Tolerante: si no hay `az` o sesion, reporta `NO VERIFICADO` en vez de fallar.

La provision de **labels** (paso 3) y la del **CI** hacia Azure (paso 4) las ofrece `/onboard` como pasos **opt-in**, bajo confirmacion explicita: el script de labels es destructivo (borra los labels default de GitHub) y el de CI crea recursos reales en Azure (app de Entra, role assignments, federated credential -- OIDC, ADR-0022). El diagnostico en si sigue siendo de solo lectura: sin tu confirmacion no se crea, borra ni provisiona nada.

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
    if [ -n "${HARNESS_BC_NAME:-}" ]; then
      row OK "boundedContext declarado: name='${HARNESS_BC_NAME}' domains='${HARNESS_BC_DOMAINS}'"
    else
      row FALTA "boundedContext ausente o invalido (campo obligatorio, ADR-0023)"
      ACTIONS="${ACTIONS}  - Falta 'boundedContext' en .claude/harness.config.json. Añade:
    \"boundedContext\": { \"name\": \"<NombreDetuBC>\", \"domains\": [<tus domainLabels>] }
  Los dominios deben ser un subconjunto de domainLabels. Ver README seccion 'Migracion para consumidores existentes'.
"
    fi
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

# --- 2. Tokens del harness en CLAUDE.md (contrato punto 2) ---
echo ""
echo "Tokens del harness (seccion \"Tokens del harness\" en CLAUDE.md raiz):"
CLAUDE_MD="CLAUDE.md"
if [ -r "$CLAUDE_MD" ]; then
  MISSING_TOKENS=""
  for tok in RootNamespace SolutionFile ProjectDisplayName BoundedContext BoundedContextDomains; do
    grep -Eq "\*\*${tok}\*\*" "$CLAUDE_MD" || MISSING_TOKENS="$MISSING_TOKENS $tok"
  done
  if [ -z "$MISSING_TOKENS" ]; then
    row OK "los 5 tokens estan presentes (RootNamespace, SolutionFile, ProjectDisplayName, BoundedContext, BoundedContextDomains)"
  else
    row FALTA "faltan tokens en CLAUDE.md:$MISSING_TOKENS"
    ACTIONS="${ACTIONS}  - Completa la seccion \"Tokens del harness\" de tu CLAUDE.md raiz con los tokens faltantes ($MISSING_TOKENS). Ver CLAUDE.md del harness, seccion \"Contrato con el proyecto consumidor\" punto 2, para el formato exacto.
"
  fi
else
  row NV "no se hallo un CLAUDE.md legible en la raiz del proyecto"
  ACTIONS="${ACTIONS}  - Crea CLAUDE.md en la raiz del proyecto con la seccion \"Tokens del harness\" (ver CLAUDE.md del harness, seccion \"Contrato con el proyecto consumidor\" punto 2).
"
fi

# --- 3. Estructura de carpetas esperada (contrato punto 3, informativo) ---
echo ""
echo "Estructura de carpetas esperada (informativo, no bloqueante):"
for dir in src tests infra/environments; do
  if [ -d "$dir" ]; then
    row OK "$dir/ existe"
  else
    row NV "$dir/ no existe todavia (normal en greenfield antes del primer /scaffold o /infra-base; no bloqueante)"
  fi
done

# --- 4. Labels de GitHub (ADR-0007) ---
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
    ACTIONS="${ACTIONS}  - Faltan labels del esquema. /onboard puede crearlos en el paso de provision opt-in (te lo ofrece tras el diagnostico, bajo confirmacion: el script borra los labels default de GitHub y recrea el esquema). O ejecutalo tu mismo: \"$PLUGIN_SCRIPTS/setup-github-labels.sh\".
"
  fi
  if [ -z "${HARNESS_DOMAIN_LABELS:-}" ]; then
    echo "                  (dom:* no verificado - domainLabels vacio o config no cargada)"
  fi
fi

# --- 5. CI hacia Azure (ADR-0022) ---
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
    ACTIONS="${ACTIONS}  - Falta la app de Entra del CI. /onboard puede configurarlo en el paso de provision opt-in (te lo ofrece tras el diagnostico, bajo confirmacion: crea recursos reales en Azure -- app de Entra, role assignments y federated credential OIDC, ADR-0022 -- y debe correr DESPUES de bootstrap-backend.sh). O ejecutalo tu mismo: \"$PLUGIN_SCRIPTS/setup-github-ci.sh <subscription-id>\".
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
    ACTIONS="${ACTIONS}  - Copia los tres secrets OIDC (AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID) que imprime \"$PLUGIN_SCRIPTS/setup-github-ci.sh <subscription-id>\" a Settings > Secrets and variables > Actions. El script (y el paso de provision opt-in de /onboard) NO los sube: pegalos a mano. No hay client secret que expire (OIDC, ADR-0022).
"
  fi
fi

# --- 6. Acciones y resumen ---
echo ""
if [ -n "$ACTIONS" ]; then
  echo "Acciones sugeridas (el diagnostico no ejecuta ninguna; los labels faltantes y el CI los pueden provisionar los pasos opt-in, bajo tu confirmacion):"
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

### 3. Provision opt-in de los labels faltantes

Este es el **unico** paso que puede escribir algo, y solo bajo confirmacion explicita del usuario. El diagnostico (pasos 1-2) nunca crea ni borra labels.

Aplica este paso **solo si** la seccion "Labels de GitHub" del diagnostico reporto `[FALTA] faltan labels: ...`. Si los labels salieron `OK`, no hay nada que provisionar -- omite el paso. Si salieron `NO VERIFICADO` (gh sin autenticar o sin repo), no se puede saber que falta: pide al usuario `gh auth login` y que vuelva a correr `/onboard`; no intentes provisionar a ciegas.

1. **Advierte que es destructivo y pide confirmacion.** `scripts/setup-github-labels.sh` **borra los 8 labels default de GitHub** (documentation, duplicate, enhancement, good first issue, help wanted, invalid, question, wontfix) y re-crea `bug` con el esquema del harness, antes de crear el resto del esquema. Dilo explicitamente y pregunta, p. ej.: "Faltan estos labels: <lista>. ¿Quieres que los provisione ahora? Esto **borra los labels default de GitHub** y recrea el esquema del harness. [si/no]".
2. **No ejecutes nada sin un "si" explicito.** Si el usuario no confirma (o prefiere hacerlo a mano), no corras el script: recuerdale el comando de las "Acciones sugeridas" y termina. El comportamiento por defecto de `/onboard` es solo diagnostico.
3. **Solo si el usuario confirma**, corre el bloque de provision. Reusa la misma resolucion de `PLUGIN_SCRIPTS` del paso 1 e invoca el script plugin-relative:

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"

PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" bash <<'PROVISION'
set +e

# Guard defensivo (cwd != Mefisto), por si el bloque se ejecuta aislado.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
  echo "ERROR: /onboard no aplica al repo de Mefisto."; exit 1
fi

LABELS_SCRIPT="${PLUGIN_SCRIPTS%/}/setup-github-labels.sh"
if [ ! -f "$LABELS_SCRIPT" ]; then
  echo "ERROR: no se hallo setup-github-labels.sh en el plugin ($LABELS_SCRIPT)."
  echo "       Reinstala mefisto o reabre la sesion (hook SessionStart) y reintenta."
  exit 1
fi

echo "Provisionando labels con: $LABELS_SCRIPT"
echo "(borra los labels default de GitHub y recrea el esquema dimensional del harness)"
echo ""
bash "$LABELS_SCRIPT"
PROV_RC=$?
echo ""
if [ "$PROV_RC" -eq 0 ]; then
  echo "OK: labels provisionados. Vuelve a correr /onboard para ver el diagnostico en verde."
else
  echo "FALLO (exit $PROV_RC): la provision de labels NO se completo."
  echo "Causas tipicas:"
  echo "  - gh no autenticado -> corre 'gh auth login' y reintenta."
  echo "  - un label tipo:*/estado:*/bloqueado YA existia: setup-github-labels.sh los crea sin --force"
  echo "    y aborta por 'set -e' (solo es idempotente en bug y dom:*). Borra el/los label(s) en conflicto,"
  echo "    o crea a mano los que falten con 'gh label create', y reintenta."
  echo "El onboarding no queda en estado ambiguo: vuelve a correr /onboard para ver que labels existen realmente."
fi
PROVISION
```

4. **Reporta el resultado al usuario** tal como lo imprimio el bloque. Si fallo, no abortes ni reescribas el resto del flujo: el diagnostico (pasos 1-2) ya se mostro y sus otras secciones (config, CI) son independientes de los labels. En ambos casos sugiere volver a correr `/onboard` para confirmar el estado real tras la provision.

### 4. Provision opt-in del CI hacia Azure

Es la **segunda** (y ultima) escritura que puede hacer `/onboard`, y solo bajo confirmacion explicita del usuario, porque `scripts/setup-github-ci.sh` **crea recursos reales en Azure** (la aplicacion de Entra + Service Principal, tres role assignments y dos federated credentials OIDC). El diagnostico (pasos 1-2) nunca crea recursos en Azure.

Aplica este paso **solo si** la seccion "CI hacia Azure" del diagnostico reporto `FALTA` -- ya sea la app de Entra (`aplicacion de Entra "..." no encontrada`) o los secrets OIDC (`faltan secrets OIDC: ...`). Ambos los resuelve `setup-github-ci.sh`: es **idempotente** (si la app/SP/federated credential ya existen, los reutiliza) y siempre re-imprime los 3 secrets OIDC al final, asi que tambien sirve cuando solo faltan los secrets en GitHub. Si la seccion salio `OK`, no hay nada que provisionar -- omite el paso. Si salio `NO VERIFICADO` (sin `az`, sin sesion de Azure, o `githubServicePrincipalName` ausente en el config), **no provisiones a ciegas**: pide al usuario instalar Azure CLI / correr `az login` / completar el config segun corresponda, y que vuelva a correr `/onboard`.

1. **Valida prerequisitos y reune los datos (CA-3).** Antes de ofrecer nada, confirma que se puede: `az` instalado y con **sesion activa** (`az account show`). El `<subscription-id>` **no esta en el config**: pideselo al usuario. El `<owner/repo>` el script lo auto-resuelve (via `gh` o el remote `origin`); ofrece pasarlo solo si la resolucion falla. Si falta `az`, la sesion o el subscription-id, **reportalo claro y no invoques el script** (en vez de dejarlo fallar opaco).
2. **Advierte que crea recursos reales en Azure y pide confirmacion (CA-2).** Antes de ejecutar nada, dilo explicitamente y pregunta, p. ej.: "Esto configura el CI hacia Azure: crea la app de Entra + Service Principal (sin secret), le asigna `Contributor` y `Role Based Access Control Administrator` (con condicion anti-escalacion) a nivel suscripcion y `Storage Blob Data Contributor` sobre el tfstate, y anade dos federated credentials OIDC (rama `main` y `pull_request`). **Crea recursos reales en Azure.** Recuerda que debe correr **despues** de `bootstrap-backend.sh` (resuelve el nombre real del tfstate del backend ya creado). ¿Quieres que lo configure ahora? [si/no]".
3. **No ejecutes nada sin un "si" explicito (CA-4).** Si el usuario no confirma (o prefiere hacerlo a mano), no corras el script: recuerdale el comando de las "Acciones sugeridas" y termina. El comportamiento por defecto de `/onboard` es solo diagnostico: una corrida sin confirmar **no crea ningun recurso en Azure ni copia secrets**.
4. **Solo si el usuario confirma**, corre el bloque de provision. Reusa la misma resolucion de `PLUGIN_SCRIPTS` del paso 1 e invoca el script plugin-relative, sustituyendo `<subscription-id>` por el que dio el usuario (y `OWNER_REPO` solo si la auto-resolucion fallo):

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"

PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" SUBSCRIPTION_ID="<subscription-id>" OWNER_REPO="" bash <<'PROVISION_CI'
set +e

# Guard defensivo (cwd != Mefisto), por si el bloque se ejecuta aislado.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
  echo "ERROR: /onboard no aplica al repo de Mefisto."; exit 1
fi

# Prerequisitos (CA-3): reportar claro en vez de fallar opaco.
if ! command -v az >/dev/null 2>&1; then
  echo "ERROR: Azure CLI ('az') no esta instalado. Instalalo y corre 'az login' antes de configurar el CI."
  exit 1
fi
if ! az account show >/dev/null 2>&1; then
  echo "ERROR: no hay sesion activa de Azure. Corre 'az login' y reintenta."
  exit 1
fi
if [ -z "$SUBSCRIPTION_ID" ] || [ "$SUBSCRIPTION_ID" = "<subscription-id>" ]; then
  echo "ERROR: falta el <subscription-id> (el usuario debe proveerlo; no esta en el config)."
  echo "       Reintenta el bloque con SUBSCRIPTION_ID=<id> (y OWNER_REPO=<owner/repo> si la auto-resolucion falla)."
  exit 1
fi

CI_SCRIPT="${PLUGIN_SCRIPTS%/}/setup-github-ci.sh"
if [ ! -f "$CI_SCRIPT" ]; then
  echo "ERROR: no se hallo setup-github-ci.sh en el plugin ($CI_SCRIPT)."
  echo "       Reinstala mefisto o reabre la sesion (hook SessionStart) y reintenta."
  exit 1
fi

echo "Configurando el CI con: $CI_SCRIPT $SUBSCRIPTION_ID ${OWNER_REPO}"
echo "(crea app de Entra + Service Principal SIN secret, role assignments y federated credentials OIDC -- ADR-0022)"
echo "Debe correr DESPUES de bootstrap-backend.sh: resuelve el nombre real del tfstate del backend ya creado."
echo ""
if [ -n "$OWNER_REPO" ]; then
  bash "$CI_SCRIPT" "$SUBSCRIPTION_ID" "$OWNER_REPO"
else
  bash "$CI_SCRIPT" "$SUBSCRIPTION_ID"
fi
CI_RC=$?
echo ""
if [ "$CI_RC" -eq 0 ]; then
  echo "OK: CI configurado. El script imprimio arriba los 3 secrets OIDC (AZURE_CLIENT_ID,"
  echo "AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID): pegalos A MANO en GitHub (Settings > Secrets and"
  echo "variables > Actions). El script NO los sube y no hay client secret que expire (OIDC, ADR-0022)."
  echo "Luego vuelve a correr /onboard para ver el diagnostico del CI en verde."
else
  echo "FALLO (exit $CI_RC): la configuracion del CI NO se completo."
  echo "Causas tipicas:"
  echo "  - bootstrap-backend.sh aun no corrio -> no se resuelve la Storage del tfstate. Crea el backend primero."
  echo "  - sin permisos de gestion de aplicaciones en Microsoft Entra -> pide a un admin que lo provisione."
  echo "  - no se pudo resolver el slug owner/repo -> reintenta pasando OWNER_REPO=<owner/repo>."
  echo "El onboarding no queda en estado ambiguo: vuelve a correr /onboard para ver el estado real del CI."
fi
PROVISION_CI
```

5. **Reporta el resultado al usuario (CA-5)** tal como lo imprimio el bloque. Si la provision fue exitosa, **recuerdale explicitamente que el script imprime 3 secrets OIDC** (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`) que debe **pegar a mano** en GitHub (Settings > Secrets and variables > Actions), porque ni el script ni `/onboard` los suben; no hay client secret que expire (OIDC, ADR-0022). Si fallo, no abortes ni reescribas el resto del flujo: el diagnostico (pasos 1-2) y las otras provisiones (labels) son independientes. En ambos casos sugiere volver a correr `/onboard` para confirmar el estado real tras la provision.

## Reglas

- **Diagnostico de solo lectura por defecto.** El diagnostico (pasos 1-2) no ejecuta `gh label create`, `az ... create`, ni escribe archivos o recursos. Las **unicas** acciones de escritura permitidas son las **provisiones opt-in** -- labels (paso 3, el script borra los labels default de GitHub) y CI hacia Azure (paso 4, el script crea app de Entra, role assignments y federated credential OIDC) -- y solo tras la confirmacion explicita del usuario **para cada una**: nunca las ejecutes sin un "si". Sin confirmacion, una corrida de `/onboard` no crea, borra ni provisiona nada (ni labels, ni recursos de Azure, ni copia secrets).
- **No abortes ante un fallo parcial.** Cada seccion del diagnostico es independiente: si `gh` o `az` no estan disponibles, reporta `NO VERIFICADO` y continua con el resto.
- **No dupliques la validacion del config.** El formato de `terraformStateStorage` y los campos requeridos los valida `load_harness_config` (issue #78); este skill solo reporta su resultado.
- **La estructura de carpetas es informativa, nunca `FALTA`.** Un greenfield legitimo aun no tiene `src/`, `tests/` ni `infra/environments/` antes del primer `/scaffold` o `/infra-base`; marcarla como bloqueante daria un falso negativo (issue #212).
- Si `$ARGUMENTS` trae algo, ignoralo: `/onboard` no toma argumentos.
