---
model: haiku
---

Diagnostica el onboarding del consumidor: valida `.claude/harness.config.json`, los labels y el CI, y reporta un checklist de que esta listo y que falta. Presenta ademas la **bifurcacion de dos caminos de auth** (MEF-ADR-0028 + enmienda #337): (A) crecer -- autenticacion orquestada desde el inicio, etapa `multi-tenant-header` -- vs (B) POC -- sin autenticacion, etapa `mono-tenant-transitorio`, el default. Es un **doctor**: por defecto solo diagnostica (no crea ni modifica nada). Como excepciones **opt-in**, si lo confirmas explicitamente puede provisionar los labels faltantes (el script subyacente es destructivo: borra los labels default de GitHub), configurar el CI hacia Azure (crea recursos reales en Azure -- app de Entra, role assignments y federated credential, por OIDC; ver MEF-ADR-0022), escribir/actualizar la estrategia de tenancy vigente (`tenancy.strategy`, MEF-ADR-0028) que materializa el camino elegido, y encadenar `/scaffold-projections` (MEF-ADR-0034, issue #369) cuando el BC declara `projections.enabled: true` pero el worker de proyecciones todavia no existe. Comunicate en **espanol**.

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
4. **Labels de GitHub** (MEF-ADR-0007): que existan `tipo:*`, `estado:borrador`, `estado:listo`, `dom:<x>` por cada `domainLabels`, mas `bug` y `bloqueado`.

   > **Presupuesto de nombres para el scaffold (issue #245, informativo, no verificado aqui):** cada `domainLabels` termina, al scaffoldear, en el nombre de una Function App `func-{prefix_func}-{kebab}`. El limite real es 60 caracteres (`Microsoft.Web/sites`, naming rules de Azure: https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules#microsoftweb), asi que el presupuesto para el `kebab` del dominio es `60 - 5 ("func-") - 1 ("-") - len(prefix_func)` caracteres. `/onboard` no lo valida (`prefix_func` vive en `infra/environments/dev/variables.tf`, fuera de `harness.config.json`); la Validacion 1 del Paso 0 de `domain-scaffolder` lo hace al momento de scaffoldear cada dominio.
5. **CI hacia Azure** (MEF-ADR-0022): que exista la aplicacion de Entra / Service Principal y los secrets OIDC del repo. Tolerante: si no hay `az` o sesion, reporta `NO VERIFICADO` en vez de fallar.
6. **Secretos que alimentan la siembra en CI** (MEF-ADR-0025, informativo): que existan en GitHub `TF_VAR_POSTGRESQL_ADMIN_PASSWORD` y un `SB_EXTERNAL_<ALIAS>_CONNECTION_STRING` por cada alias de `serviceBus.external[]`. Son los **inputs** que `infra-cd.yml` usa para sembrar el Key Vault del BC en un step posterior al `apply`; ya no hay siembra manual del admin ni verificacion del data plane del vault (MEF-ADR-0025 decision #6/#10). Reusa la misma lectura de `gh secret list` del punto 5; si falta, reporta `NO VERIFICADO` sin bloquear (un greenfield legitimo aun no tiene Postgres provisionado ni alias externos declarados).
7. **Registro `secrets[]`** (issue #256, informativo): cuantas entradas hay registradas (las siembra el step data-driven de `infra-cd.yml`, sin ninguna linea hardcodeada por secreto) y, para cada entrada con `source.type: "github-secret"`, si el GitHub secret que referencia existe en el repo. La **forma** del array (`name` unico, `source.type` en {`output`, `github-secret`, `composite`}, `source.value` no vacio) ya la valida `load_harness_config` como parte del punto 1 (`Configuracion`): un `secrets[]` mal formado hace que esa seccion reporte `FALTA`, con el mensaje exacto que emite la funcion. Ausente por completo, reporta `NO VERIFICADO` sin bloquear (normal antes del primer `/infra-base`).
8. **Bifurcacion de dos caminos de auth** (`tenancy.strategy`, MEF-ADR-0028 + enmienda #337, MEF-ADR-0032, issue #323 + #341, informativo): que camino declaro el proyecto, mapeado 1:1 a las dos etapas de tenancy de MEF-ADR-0028 -- **(A) crecer**: autenticacion orquestada desde el inicio (`multi-tenant-header`, etapa b, ya existe o se planea una autenticacion que produce un `TenantContext`) o **(B) POC**: sin autenticacion (`mono-tenant-transitorio`, etapa a, greenfield, el default). No se sondea en codigo (no hay señal fiable: el harness no referencia ningun tipo `Cosmos.MultiTenancy.*`/autenticacion); es un token **declarado** por el humano. Ausente equivale al camino (B) POC/etapa (a) por defecto, asi que nunca reporta `FALTA` -- solo `OK` (valor reconocido, cualquiera de los dos caminos) o `NO VERIFICADO` (ausente, o con un valor no reconocido).
9. **Worker de proyecciones** (`projections.enabled`, MEF-ADR-0034, issue #369, informativo): si el BC declaro que adopta proyecciones y, si lo declaro, si el worker `<RootNamespace>.Projections` ya existe. Usa `HARNESS_PROJECTIONS_ENABLED` (`load_harness_config`) y, si esa variable no llego exportada -- config invalido, que hace abortar la funcion, o `_pipeline-common.sh` del plugin no hallado --, re-deriva el token inline con `jq` desde el config, igual que la seccion 8 con `tenancy.strategy`: reportar "ausente" un token que si esta declarado seria un falso negativo, y apagaria en silencio el paso opt-in 6. Nunca sondea codigo mas alla de la existencia del csproj. Ausente, `null`, `false` o cualquier valor distinto de `true` nunca reporta `FALTA` -- es opt-in, igual que `tenancy.strategy`. Si esta en `true` y el worker ya existe, reporta `OK`; si esta en `true` pero el worker no existe todavia, reporta `NO VERIFICADO` y habilita el paso opt-in 6 (encadenar `/scaffold-projections`).

La provision de **labels** (paso 3), la del **CI** hacia Azure (paso 4), la escritura de la **estrategia de tenancy** (paso 5, la bifurcacion de caminos de auth) y encadenar **`/scaffold-projections`** (paso 6, cuando el worker de proyecciones falta) las ofrece `/onboard` como pasos **opt-in**, bajo confirmacion explicita: el script de labels es destructivo (borra los labels default de GitHub), el de CI crea recursos reales en Azure (app de Entra, role assignments, federated credential -- OIDC, MEF-ADR-0022), el de tenancy escribe `.claude/harness.config.json`, y el de proyecciones genera codigo nuevo (invoca al agente `projections-scaffolder`). El diagnostico en si sigue siendo de solo lectura: sin tu confirmacion no se crea, borra, escribe, genera ni provisiona nada. (Los writes opt-in de `/onboard` pasan asi de 2 -- labels, CI -- a 4, sumando el token `tenancy.strategy` que materializa el camino de auth elegido y la cadena hacia `/scaffold-projections`.)

Al cerrar el reporte, `/onboard` imprime un bloque **"Proximos pasos"**: deriva del mismo diagnostico ya hecho (sin re-verificar nada) el comando exacto a correr a continuacion -- labels (MEF-ADR-0007), CI (MEF-ADR-0022), infraestructura base (`/mefisto:infra-base dev`, MEF-ADR-0021), el recordatorio recurrente de mantener al dia los GitHub secrets que alimentan la siembra en CI (MEF-ADR-0025), el camino declarado (A) crecer (`tenancy.strategy = multi-tenant-header`) -- el puntero a `/install-auth` (tras infra base + `/scaffold`, issue #342, implementado) para instalar WorkOS+APIM (MEF-ADR-0032) --, o el worker de proyecciones faltante (`/scaffold-projections`, MEF-ADR-0034, issue #369), segun que seccion reporto `FALTA`/`NO VERIFICADO` o que camino/token quedo declarado -- y cierra con un puntero descubrible al quickstart narrativo del arranque greenfield (`docs/greenfield-quickstart.md` del harness). Es **puramente informativo**: no ejecuta `gh`/`az` ni provisiona nada; las escrituras que puede derivar siguen siendo los pasos opt-in 3 (labels) y 4 (CI) -- la escritura de tenancy (paso 5) y la cadena hacia `/scaffold-projections` (paso 6) se ofrecen siempre que corresponda, independientemente de este bloque, porque ninguna de las dos reporta `FALTA`.

## Proceso

### 1. Ejecutar el diagnostico

Corre este bloque tal cual. Resuelve la raiz del plugin e invoca `scripts/onboard-diagnose.sh` de forma plugin-relative (mismo patron que `commands/implement.md` invoca `tmux-pipeline.sh`): ese script trae el checklist completo de 9 secciones, sin ningun placeholder de shell en este archivo.

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"

DIAGNOSE_SCRIPT="${PLUGIN_SCRIPTS}/onboard-diagnose.sh"
if [ ! -f "$DIAGNOSE_SCRIPT" ]; then
  echo "ERROR: no se hallo onboard-diagnose.sh en el plugin ($DIAGNOSE_SCRIPT)."
  echo "       Reinstala mefisto o reabre la sesion (hook SessionStart) y reintenta."
  exit 1
fi

bash "$DIAGNOSE_SCRIPT"
```

### 2. Presentar el resultado

Muestra al usuario la salida del checklist tal como la imprimio el bloque (el formato ya esta consolidado), **incluyendo el cierre "Proximos pasos" y el puntero al quickstart greenfield** -- ese bloque ya decidio el siguiente comando exacto a partir del mismo diagnostico, no lo repitas ni lo reformules. Luego, en una o dos lineas, resume el estado (cuantos `FALTA`/`NO VERIFICADO` hay, o que quedo LISTO) sin duplicar el contenido de "Proximos pasos".

No reinterpretes ni recalcules el checklist ni el bloque "Proximos pasos": el bloque bash ya hizo el diagnostico y ya derivo el siguiente paso.

### 3. Provision opt-in de los labels faltantes

Este es el **unico** paso que puede escribir algo, y solo bajo confirmacion explicita del usuario. El diagnostico (pasos 1-2) nunca crea ni borra labels.

Aplica este paso **solo si** la seccion "Labels de GitHub" del diagnostico reporto `[FALTA] faltan labels: ...`. Si los labels salieron `OK`, no hay nada que provisionar -- omite el paso. Si salieron `NO VERIFICADO` (gh sin autenticar o sin repo), no se puede saber que falta: pide al usuario `gh auth login` y que vuelva a correr `/onboard`; no intentes provisionar a ciegas.

1. **Advierte que es destructivo y pide confirmacion.** `scripts/setup-github-labels.sh` **borra 8 de los 9 labels default de GitHub** (documentation, duplicate, enhancement, good first issue, help wanted, invalid, question, wontfix) y re-crea `bug` con el esquema del harness, antes de crear el resto del esquema. Dilo explicitamente y pregunta, p. ej.: "Faltan estos labels: <lista>. ¿Quieres que los provisione ahora? Esto **borra los labels default de GitHub** y recrea el esquema del harness. [si/no]".
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
echo "(crea app de Entra + Service Principal SIN secret, role assignments y federated credentials OIDC -- MEF-ADR-0022)"
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
  echo "variables > Actions). El script NO los sube y no hay client secret que expire (OIDC, MEF-ADR-0022)."
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

5. **Reporta el resultado al usuario (CA-5)** tal como lo imprimio el bloque. Si la provision fue exitosa, **recuerdale explicitamente que el script imprime 3 secrets OIDC** (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`) que debe **pegar a mano** en GitHub (Settings > Secrets and variables > Actions), porque ni el script ni `/onboard` los suben; no hay client secret que expire (OIDC, MEF-ADR-0022). Si fallo, no abortes ni reescribas el resto del flujo: el diagnostico (pasos 1-2) y las otras provisiones (labels) son independientes. En ambos casos sugiere volver a correr `/onboard` para confirmar el estado real tras la provision.

**Caveat: idempotencia parcial de la condicion ABAC.** `az role assignment create` no actualiza la condicion de una asignacion que ya exista con el mismo principal/rol/alcance. La asignacion de `Role Based Access Control Administrator` con la condicion anti-escalacion la introdujo el issue #195; en un onboarding limpio se crea de una vez **con** la condicion. Pero si el SP ya tuviera esa asignacion **sin** la condicion --creada fuera de este script (p. ej. a mano), o si una version futura del script cambia la expresion de la condicion-- re-correr el script aqui **no** se la aplica ni actualiza. El SP quedaria con ese rol sin la restriccion anti-escalacion, aunque `/onboard` reporte el CI en verde. Ver el diagnostico y la remediacion completa en el README, seccion "Bootstrap de infraestructura", paso 2. El arreglo del script (deteccion y recreacion automatica) queda diferido a un issue aparte.

### 5. Bifurcacion de auth: provision opt-in de la estrategia de tenancy (crecer vs POC)

Es la **tercera** escritura opt-in de `/onboard` (junto a labels y CI), y la unica que toca `.claude/harness.config.json` en vez de recursos externos -- no requiere `gh` ni `az`. El diagnostico (pasos 1-2) nunca escribe este token; solo lo reporta.

`/onboard` **no sondea codigo** para inferir el camino de auth vigente (MEF-ADR-0028): no hay señal fiable (un grep del harness confirmo cero referencias a `MultiTenancy`/`TenantResolver`/`TenantContext` en agentes/scripts/commands/ADRs). El camino lo declara el humano; este paso solo lo pregunta como una bifurcacion explicita de dos caminos (CA-1) y, si se confirma, escribe la etapa de tenancy que lo materializa.

Ofrece este paso siempre (a diferencia de labels/CI, no depende de que el diagnostico haya reportado `FALTA` -- la seccion de tenancy nunca lo reporta). Si el usuario no tiene interes en tocar la estrategia de tenancy ahora, omite el paso sin insistir.

1. **Presenta la bifurcacion de dos caminos y pregunta cual aplica (CA-1).** Independientemente de lo que reporto el diagnostico (punto 8), presenta al usuario los dos caminos -- mapeados 1:1 a las dos etapas de MEF-ADR-0028 -- y pregunta cual elige, p. ej.: "Tu proyecto puede seguir uno de dos caminos de auth: **(A) crecer** -- va a madurar mas alla de esto y necesita autenticacion orquestada desde el inicio (WorkOS AuthKit + Azure API Management, MEF-ADR-0032; etapa `multi-tenant-header`) -- o **(B) POC** -- no va a madurar mas alla de una prueba de concepto y no necesita autenticacion (etapa `mono-tenant-transitorio`, el default). ¿Cual de los dos elegis? [A/B]".
   - Si responde **(B) POC** (o no sabe / prefiere decidir despues): el camino vigente es (a), `mono-tenant-transitorio`. Si el token ya esta ausente o ya vale eso, no hay nada que escribir (CA-2) -- informa y termina el paso sin tocar el archivo.
   - Si responde **(A) crecer**: el camino vigente es (b), `multi-tenant-header`.
2. **No escribas nada sin confirmar el valor exacto (mismo patron que los pasos 3 y 4).** Muestra el valor que vas a escribir/actualizar y pide confirmacion explicita, p. ej.: "Voy a escribir `tenancy.strategy = \"multi-tenant-header\"` en `.claude/harness.config.json`. ¿Confirmas? [si/no]". Si el usuario no confirma, no toques el archivo: recuerdale que puede editarlo a mano y termina el paso. El comportamiento por defecto de `/onboard` sigue siendo solo diagnostico.
3. **Solo si el usuario confirma**, escribe/actualiza el campo con `jq`, preservando el resto del archivo:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
  echo "ERROR: /onboard no aplica al repo de Mefisto."; exit 1
fi

CONFIG=".claude/harness.config.json"
ESTRATEGIA="<mono-tenant-transitorio|multi-tenant-header>"  # la que confirmo el usuario en el paso 2

if [ ! -f "$CONFIG" ]; then
  echo "ERROR: no existe $CONFIG. Crealo primero (ver README, seccion \"Configurar el consumidor\")."
elif ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq no esta instalado. Requerido para escribir $CONFIG."
else
  TMP=$(mktemp)
  if jq --arg s "$ESTRATEGIA" '.tenancy = {strategy: $s}' "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"; then
    echo "OK: tenancy.strategy = \"$ESTRATEGIA\" escrito en $CONFIG."
  else
    rm -f "$TMP"
    echo "ERROR: no se pudo escribir $CONFIG (revisa que sea JSON valido)."
  fi
fi
```

4. **Reporta el resultado al usuario.** Si escribio el token, recuerdale que `domain-scaffolder` (Paso 0) solo lo lee en el **proximo** dominio que scaffoldee -- no re-scaffoldea dominios ya existentes. Si el proyecto tiene dominios en etapa (a) y acaba de declarar la etapa (b), reemplazar el `ITenantResolver` de esos dominios existentes sigue siendo manual (ver el `// TODO(tenancy etapa b)` que `domain-scaffolder` deja en `TenantResolverMonoTenantPorDefecto.cs`, MEF-ADR-0028). Si el camino elegido fue **(A) crecer**, suma el puntero al orquestador (CA-3): tras `/mefisto:infra-base` y `/mefisto:scaffold <dominio>`, el siguiente paso es correr `/install-auth` para instalar WorkOS+APIM (MEF-ADR-0032, issue #342) -- encadena `/install-workos` y `/install-apim` con el gate humano en medio, sin que tengas que conocer el orden ni invocar cada skill de capa por separado.

### 6. Worker de proyecciones: provision opt-in encadenando `/scaffold-projections`

Es la **cuarta** escritura opt-in de `/onboard` (junto a labels, CI y tenancy), y la unica que genera codigo nuevo -- invoca al agente `projections-scaffolder` -- en vez de tocar `.claude/harness.config.json` o recursos externos. El diagnostico (pasos 1-2) nunca genera el worker; solo reporta si falta (CA-3).

Aplica este paso **solo si** la seccion "Worker de proyecciones" del diagnostico reporto `projections.enabled=true, pero el worker ... no existe todavia` (issue #369). Si `projections.enabled` no esta en `true`, o el worker ya existe, no hay nada que ofrecer -- omite el paso sin insistir.

1. **Pide confirmacion explicita (CA-4).** El BC ya declaro que adopta proyecciones (el token esta en `true`); este paso solo pregunta si generar el worker ahora, p. ej.: "El BC declara `projections.enabled: true` pero el worker de proyecciones (`<RootNamespace>.Projections`) todavia no existe. ¿Quieres que corra `/scaffold-projections` ahora para generarlo (MEF-ADR-0034)? [si/no]".
2. **No ejecutes nada sin un "si" explicito.** Si el usuario no confirma (o prefiere hacerlo despues), no invoques nada: recuerdale que puede correr `/scaffold-projections` el mismo cuando quiera, y termina el paso. El comportamiento por defecto de `/onboard` sigue siendo solo diagnostico.
3. **Solo si el usuario confirma**, encadena `/scaffold-projections` leyendo integramente su `Proceso` -- mismo patron que `/install-auth` encadena `/install-workos`/`/install-apim`: nunca reimplementes la logica del skill ni la del agente `projections-scaffolder`. Resuelve `$PLUGIN_ROOT` (mismo patron que el paso 1) y lee el skill del plugin:

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
cat "${PLUGIN_ROOT%/}/commands/scaffold-projections.md"
```

Ejecuta sus dos pre-condiciones (cwd != Mefisto, token `projections.enabled`) y su `Proceso` completo tal cual -- incluida su propia idempotencia interna: si el worker ya existiera (condicion de carrera improbable entre el diagnostico y este paso), `projections-scaffolder` lo reporta el mismo sin duplicar nada.

4. **Reporta el resultado al usuario** tal como lo reporto `/scaffold-projections` (su seccion "3. Tras terminar", incluida la cadena de issues relacionados que recuerda: `domain-scaffolder` para registrar el store de cada dominio, y los modulos Terraform del Container App si `/infra-base` no corrio todavia con el token habilitado). Si `/scaffold-projections` aborto (p. ej. el token resulto deshabilitado entre el diagnostico y este paso), propala su mensaje sin reinterpretarlo.

## Reglas

- **Diagnostico de solo lectura por defecto.** El diagnostico (pasos 1-2) no ejecuta `gh label create`, `az ... create`, ni escribe archivos o recursos. Las **unicas** acciones de escritura permitidas son las **provisiones opt-in** -- labels (paso 3, el script borra los labels default de GitHub), CI hacia Azure (paso 4, el script crea app de Entra, role assignments y federated credential OIDC), la estrategia de tenancy (paso 5, escribe `tenancy.strategy` en `.claude/harness.config.json`) y encadenar `/scaffold-projections` (paso 6, genera el worker de proyecciones invocando al agente `projections-scaffolder`) -- y solo tras la confirmacion explicita del usuario **para cada una**: nunca las ejecutes sin un "si". Sin confirmacion, una corrida de `/onboard` no crea, borra, escribe, genera ni provisiona nada (ni labels, ni recursos de Azure, ni copia secrets, ni toca el config, ni codigo nuevo).
- **No abortes ante un fallo parcial.** Cada seccion del diagnostico es independiente: si `gh` o `az` no estan disponibles, reporta `NO VERIFICADO` y continua con el resto.
- **No dupliques la validacion del config.** El formato de `terraformStateStorage` y los campos requeridos los valida `load_harness_config` (issue #78); este skill solo reporta su resultado.
- **La estructura de carpetas es informativa, nunca `FALTA`.** Un greenfield legitimo aun no tiene `src/`, `tests/` ni `infra/environments/` antes del primer `/scaffold` o `/infra-base`; marcarla como bloqueante daria un falso negativo (issue #212).
- **Los secretos que alimentan la siembra en Key Vault (MEF-ADR-0025) son informativos, nunca `FALTA`.** La siembra en el Key Vault del BC la hace CI (`infra-cd.yml`) tras el `apply`; ningun humano custodia secretos en su data plane. El diagnostico solo reporta si los GitHub secrets que la alimentan (`TF_VAR_POSTGRESQL_ADMIN_PASSWORD`, `SB_EXTERNAL_<ALIAS>_CONNECTION_STRING` por alias) existen -- un greenfield legitimo aun no los tiene antes de provisionar Postgres o declarar `serviceBus.external[]` (issue #232).
- **El registro `secrets[]` (issue #256) tambien es informativo, nunca `FALTA` por si solo.** Su **forma** (`name`/`source.type`/`source.value`) ya la valida `load_harness_config` como parte de la seccion "Configuracion" (punto 1) -- un `secrets[]` mal formado hace que ESA seccion reporte `FALTA`, no esta. Esta seccion solo cuenta las entradas registradas y, para las de tipo `github-secret`, si el GitHub secret que referencian existe -- lo mismo que ya hacia para `serviceBus.external[]`, generalizado a cualquier entrada.
- **La bifurcacion de dos caminos de auth (`tenancy.strategy`, MEF-ADR-0028, issue #323, issue #341) es informativa, nunca `FALTA`.** Mapeada 1:1 a las dos etapas de tenancy -- (A) crecer = etapa b `multi-tenant-header`, (B) POC = etapa a `mono-tenant-transitorio`. Ausente equivale al camino (B) POC por defecto (retrocompatible); no hay señal de codigo fiable para inferir el camino, asi que `/onboard` nunca lo sondea -- solo reporta el valor declarado (o su ausencia) y ofrece el paso opt-in 5 para escribirlo bajo confirmacion. `/onboard` no absorbe la orquestacion de auth (eso vive en `/install-auth`): solo presenta la bifurcacion, la registra y apunta al orquestador en "Proximos pasos".
- **El worker de proyecciones (`projections.enabled`, MEF-ADR-0034, issue #369) es informativo, nunca `FALTA`.** Es un token opt-in (mismo criterio que `tenancy.strategy`): ausente, `null`, `false` o cualquier valor distinto de `true` es un estado valido, no bloqueante. Solo cuando esta en `true` y el worker todavia no existe se ofrece el paso opt-in 6 (encadenar `/scaffold-projections`) -- `/onboard` no genera codigo por si mismo, delega en el skill/agente.
- **El bloque de cierre "Proximos pasos" es puramente informativo (issue #222).** Solo lee las mismas variables que ya acumulo el diagnostico (`N_FALTA`, `N_NV`, y los flags `PA_*` por seccion, incluyendo `PA_AUTH_PATH` -- issue #341 -- y `PA_PROJECTIONS_MISSING` -- issue #369) para imprimir el comando exacto a correr a continuacion (incluido el puntero a `/install-auth` cuando el camino declarado es (A) crecer, y el puntero a `/scaffold-projections` cuando el worker de proyecciones falta) y el puntero al quickstart greenfield; nunca ejecuta `gh`/`az` ni escribe nada. No reemplaza ni condiciona las provisiones opt-in (pasos 3, 4, 5 y 6), que siguen requiriendo confirmacion explicita para cada una.
- Si `$ARGUMENTS` trae algo, ignoralo: `/onboard` no toma argumentos.
