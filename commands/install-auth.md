---
model: sonnet
---

Orquesta el **camino completo de auth** (MEF-ADR-0032, MEF-ADR-0028 seccion 4): encadena `/install-workos` (issue #339) -> **gate humano** -> `/install-apim` (issue #340) en el orden correcto, para que el usuario no tenga que conocer ese orden ni como se combinan los dos skills de capa. Es un runner guiado por etapas, **stateless**: no reimplementa la logica de ninguno de los dos skills, los invoca leyendo integramente su `Proceso` y delegando en su propia idempotencia -- si una etapa ya estaba hecha, el propio sub-skill invocado lo reporta y este orquestador continua. Comunicate en **espanol**.

## Pre-condicion: cwd != Mefisto

Este skill es del plugin publicado y solo aplica al repo consumidor. Mefisto no tiene `harness.config.json`, dominios de negocio, ni infraestructura que instalar. Verifica antes de continuar:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /install-auth no aplica al repo de Mefisto."
    exit 1
fi
```

Si el bloque imprime `ERROR`, detente y muestra el mensaje al usuario.

## Entrada

`$ARGUMENTS`:

```
--identity-domain <Dominio> --domain <Dominio> [--domain <Dominio2> ...] [--env <env>] [--cors-origin <origin> ...]
```

- **`--identity-domain <Dominio>`** (obligatorio): el dominio **ya scaffoldeado** que va a orquestar el aprovisionamiento de organizaciones/usuarios/membresias contra WorkOS. Se pasa tal cual como `--domain` de la **etapa 1** (`/install-workos`).
- **`--domain <Dominio>`** (obligatorio, repetible): uno o mas dominios **ya scaffoldeados** a exponer detras del gateway APIM. Se pasan tal cual como `--domain` de la **etapa 2** (`/install-apim`). Puede repetir el mismo valor de `--identity-domain` si ese dominio tambien expone endpoints HTTP de negocio detras del gateway (caso comun) -- no hay conflicto en pasarlo dos veces, con flags distintos.
- **`--env <env>`** (opcional, default `dev`): ambiente Terraform, pasado a ambas etapas.
- **`--cors-origin <origin>`** (repetible): pasado tal cual a la etapa 2. **Obligatorio solo** si es la primera instalacion del gateway en este entorno (mismo criterio que `/install-apim`, ver etapa 2 abajo).

Si falta `--identity-domain` o al menos un `--domain`, responde con el uso exacto y detente sin ejecutar nada.

## Proceso

### 1. Parsear `$ARGUMENTS`

Extrae `IDENTITY_DOMINIO`, la lista de `DOMINIOS` (uno o mas `--domain`), `ENV` (default `dev`) y la lista de `CORS_ORIGINS`. Si falta `--identity-domain` o no hay ningun `--domain`, responde con el uso exacto y detente.

### 2. Verificar prerequisitos (CA-1)

APIM se monta delante de Function Apps existentes, asi que no tiene sentido arrancar sin infraestructura base ni dominios. Todo dominio scaffoldeado por `domain-scaffolder` **garantiza** al menos los endpoints HTTP `health`/`version` (`agents/domain-scaffolder.md`, Paso 1 puntos 12-13 -- "este archivo garantiza que la Function App siempre tenga al menos un trigger"), asi que verificar que exista al menos un dominio scaffoldeado ya cubre el requisito "dominio con HTTP":

```bash
test -f "infra/environments/${ENV}/main.tf" && test -d infra/modules/resource-group || {
  echo "FALTA la infraestructura base: corre /infra-base antes de /install-auth."
  exit 1
}

ls infra/environments/"${ENV}"/dominio-*.tf >/dev/null 2>&1 || {
  echo "FALTA: ningun dominio esta scaffoldeado todavia en el entorno ${ENV}. Corre /scaffold <dominio> primero."
  exit 1
}

test -f "infra/environments/${ENV}/dominio-<kebab-de-identity-domain>.tf" || {
  echo "FALTA: el dominio de identidad <identity-domain> no esta scaffoldeado todavia. Corre /scaffold <identity-domain> primero."
  exit 1
}
```

Si cualquiera de los tres falta, detente con el mensaje -- no continues con el resto del proceso. (Los `--domain` de la etapa 2 que no esten scaffoldeados **no** se validan aca: el agente `apim-gateway-scaffolder` que invoca esa etapa ya los omite y los reporta sin abortar el resto del batch.)

**Fail-fast de `--cors-origin` (primera instalacion del gateway).** La etapa 2 (`/install-apim`, su Paso 5) aborta si es la primera instalacion del gateway en este entorno (`apim.tf` ausente) y no recibio ningun `--cors-origin`. Pero para entonces la **etapa 1 completa** ya corrio (walkthrough manual del dashboard de WorkOS + custodia del secreto + commits), asi que el usuario habria hecho todo ese trabajo para chocar contra un flag faltante que pertenece conceptualmente al borde. Como el orquestador ya tiene aca toda la informacion para detectarlo, chequealo **antes** de invocar nada (mismo criterio que `/install-apim`, no una reimplementacion de su logica):

```bash
if [ ! -f "infra/environments/${ENV}/apim.tf" ] && [ "${#CORS_ORIGINS[@]}" -eq 0 ]; then
  echo "FALTA: es la primera instalacion del gateway APIM en el entorno ${ENV} y no pasaste ningun --cors-origin."
  echo "       --cors-origin es obligatorio la primera vez (mismo criterio que /install-apim). Reintenta con:"
  echo "       /install-auth --identity-domain <Dominio> --domain <Dominio> --cors-origin <origin-del-SPA>"
  exit 1
fi
```

Si el gateway ya existe (`apim.tf` presente), este chequeo es un no-op -- un `--cors-origin` nuevo sobre un gateway ya instalado se maneja fuera de este skill (ver etapa 2).

### 3. Confirmar con el usuario

Muestra exactamente lo que va a pasar (las dos etapas completas + el gate humano) y pide confirmacion explicita -- a partir de aca este skill escribe codigo C#, Terraform, GitHub variables/secrets, y **reescribe codigo C# existente** en todos los dominios del BC (la migracion de tenancy de la etapa 2):

```
Se va a instalar el camino completo de auth (WorkOS + APIM, MEF-ADR-0032) para el entorno "<env>":

  Etapa 1 (/install-workos, dominio de identidad "<identity-domain>"):
    1. Guia del dashboard de WorkOS (paso manual tuyo).
    2. Registro/verificacion de WORKOS_CLIENT_ID (GitHub variable) y WORKOS_API_KEY (GitHub secret,
       solo se verifica su existencia).
    3. Generacion del adapter WorkOS en "<identity-domain>" (agente workos-identity-scaffolder).
    4. Custodia de la API key en Key Vault (/seed-secret).

  GATE HUMANO: no arranca la etapa 2 hasta verificar que WORKOS_CLIENT_ID y WORKOS_API_KEY
  existen en el repo (evita el fallo tipico de aplicar APIM sin las credenciales de WorkOS
  registradas).

  Etapa 2 (/install-apim, dominios: <lista de --domain>):
    5. Modulos Terraform api-management/apim-function-api (agente apim-gateway-scaffolder), aditivo
       por dominio.
    6. Cableado de TF_VAR_workos_client_id (y TF_VAR_cors_allowed_origins la primera vez) en infra-cd.yml.
    7. TRANSICION DE TENANCY (a)->(b) (MEF-ADR-0028 seccion 4): flip de tenancy.strategy +
       migracion del ITenantResolver de TODOS los dominios ya scaffoldeados del BC a
       AgregarTenantResolverHibrido().

El apply real (el que provisiona recursos en Azure y siembra el Key Vault) corre en CI al mergear
el PR (MEF-ADR-0022); este skill nunca ejecuta terraform plan/apply. El checklist post-deploy queda
pendiente para despues de ese apply.

¿Continuar? (s/n)
```

Si dice no, detente sin escribir nada. Ninguno de los dos sub-skills vuelve a pedir esta confirmacion: se la das una sola vez aca.

### 4. Rama de trabajo unica

Ambas etapas commitean cada una por su cuenta si las invocas desde `main`, pero en ramas **distintas** si no coordinas una compartida (cada una crea su propia rama por defecto: `install-workos/<dominio-kebab>`, `install-apim/<env>`). Crea la rama **antes** de invocar nada, para que ambas la reusen (las dos respetan "si ya estoy en una rama no-main, commiteo ahi sin crear otra" en su propio paso de rama):

```bash
git rev-parse --abbrev-ref HEAD
# si es main/master:
git switch -c "install-auth/${ENV}"
```

### 5. Etapa 1 -- invocar `/install-workos` (CA-2)

Resuelve `$PLUGIN_ROOT` con el mismo patron que el resto de los skills y lee `commands/install-workos.md` del plugin:

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
cat "${PLUGIN_ROOT%/}/commands/install-workos.md"
```

Ejecuta integramente su `Proceso` con `--domain <identity-domain> --env <env>`, con estas dos excepciones:

- **Omite su Paso 3** (confirmacion): ya la diste en el Paso 3 de este orquestador.
- **Omite su Paso 10** (push + PR): este orquestador hace un unico push + PR al final (Paso 8), cubriendo ambas etapas.

Su Paso 4 (crear rama) corre tal cual, pero como ya estas en `install-auth/<env>` (no `main`), su propia condicion "si ya estoy en una rama no-main, no creo otra" lo vuelve un no-op -- no hace falta omitirlo activamente.

Corre el resto de sus pasos tal cual (guia del dashboard de WorkOS, registro/verificacion de `WORKOS_CLIENT_ID`, verificacion de `WORKOS_API_KEY`, invocacion del agente `workos-identity-scaffolder`, custodia via `/seed-secret`) -- incluida su propia idempotencia interna (CA-4): si `WORKOS_CLIENT_ID` ya estaba registrado, el adapter ya estaba instalado, o el secreto ya estaba custodiado, `/install-workos` lo reporta el mismo sin duplicar nada. No vuelvas a verificar vos esas condiciones antes de invocarlo -- ese es exactamente el trabajo que delegas.

Guarda su reporte final (Paso 11 de `/install-workos`) para consolidarlo en el reporte de este skill (Paso 10).

### 6. Gate humano -- verificar credenciales de WorkOS antes de la etapa 2 (CA-3)

**No invoques `/install-apim` sin este chequeo.** Es el gate que evita el fallo tipico de aplicar APIM sin el `client_id`/API key de WorkOS registrados:

```bash
WORKOS_CLIENT_ID=$(gh variable list --json name,value -q '.[] | select(.name=="WORKOS_CLIENT_ID") | .value' 2>/dev/null)
GH_VAR_RC=$?
WORKOS_API_KEY_PRESENTE=$(gh secret list --json name -q '.[] | select(.name=="WORKOS_API_KEY") | .name' 2>/dev/null)
GH_SECRET_RC=$?
```

- Si `gh` falla en cualquiera de las dos consultas (`GH_VAR_RC`/`GH_SECRET_RC` distinto de 0 -- sin sesion, sin permisos): **detente**. A diferencia de otras verificaciones tolerantes del harness (que degradan a `NO VERIFICADO` y continuan), este es el gate humano explicito del CA-3 -- no se puede continuar a ciegas sin saber si las credenciales existen. Pide al usuario `gh auth login` y reintentar `/install-auth`.
- Si `WORKOS_CLIENT_ID` esta vacio **o** `WORKOS_API_KEY_PRESENTE` esta vacio: **detente**. No invoques la etapa 2. Reporta exactamente que falta y como completarlo:
  - Si falta `WORKOS_CLIENT_ID`: la guia del dashboard de WorkOS (Paso 5 de `/install-workos`, ya corrida en la etapa 1) no llego a registrarlo -- revisa el reporte de la etapa 1 o corre `/install-auth` de nuevo tras completarla.
  - Si falta `WORKOS_API_KEY`: el usuario todavia no corrio `gh secret set WORKOS_API_KEY` (paso manual, MEF-ADR-0025 -- nunca lo automatiza este skill). Indicaselo y detente.
- Si ambos existen: reporta el gate como verificado y continua a la etapa 2.

### 7. Etapa 2 -- invocar `/install-apim` (CA-2)

Resuelve `$PLUGIN_ROOT` (mismo patron) y lee `commands/install-apim.md` del plugin:

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
cat "${PLUGIN_ROOT%/}/commands/install-apim.md"
```

Ejecuta integramente su `Proceso` desde su **Paso 5 en adelante** con `--domain <lista de --domain> --env <env> [--cors-origin <origin> ...]` -- sus Pasos 1 (parseo), 2 (prerequisitos) y 4 (rama) ya quedan cubiertos por los Pasos 1, 2 y 4 de este orquestador, y su Paso 3 (confirmacion) ya la diste en el Paso 3 de este orquestador. **Omite su Paso 11** (push + PR): este orquestador hace el unico push + PR al final (Paso 8).

Corre el resto tal cual (resolucion de primera instalacion, `WORKOS_CLIENT_ID`, `CORS_ALLOWED_ORIGINS`, agente `apim-gateway-scaffolder`, transicion de tenancy (a)->(b) con el gate de MEF-ADR-0029 por dominio, commit de la migracion) -- incluida su propia idempotencia interna (CA-4): si el gateway ya existia, algun dominio ya estaba migrado a `AgregarTenantResolverHibrido()`, o el token de tenancy ya estaba en etapa (b), `/install-apim` lo reporta el mismo sin duplicar nada.

Guarda su reporte final (Paso 13 de `/install-apim`, incluido el checklist post-deploy de su Paso 12) para consolidarlo en el reporte de este skill (Paso 9/10).

### 8. Push + PR unico (CA-5, solo si nada quedo roto)

- **Si la etapa 1 no degrado** (adapter instalado y commiteado, o ya estaba -- nunca "propuesto sin commitear") **y la etapa 2 no dejo ningun `--domain` omitido ni ningun dominio degradado** en la migracion de tenancy:

  ```bash
  git push -u origin "install-auth/${ENV}"
  gh pr create --title "feat(auth): instalar WorkOS + APIM (camino completo, MEF-ADR-0032)" --body "Instala el camino completo de auth: adapter WorkOS en <identity-domain> (/install-workos, #339) y gateway APIM + transicion de tenancy (a)->(b) para <dominios> (/install-apim, #340), MEF-ADR-0028 seccion 4. Si este skill lo disparo un issue concreto, agrega aca 'Closes #<numero>'."
  ```

  Si no hay ningun commit nuevo en la rama (ambas etapas ya estaban completamente hechas de una corrida anterior y no escribieron nada), **no crees un PR vacio**: repórtalo como "todo ya estaba instalado, nada para commitear" en el Paso 10.

- **Si alguna etapa quedo degradada** (adapter de la etapa 1 sin build verde, o algun `--domain`/dominio de tenancy de la etapa 2 sin reconciliar): **no hagas push todavia**. Detente y deja explicito en el reporte (Paso 10) que falta reconciliar antes de push + PR -- nunca un PR con algo sin construir.

### 9. Emitir el checklist post-deploy (CA-5, delegado de `/install-apim`)

Presentalo tal cual lo emitio la etapa 2 (su Paso 12), aclarando que corre **despues** de que CI aplique el PR (MEF-ADR-0022):

```
Checklist post-deploy (correr una vez que el apply de CI termine, contra el gateway_url real):

  1. OPTIONS sin header Authorization -> CORS responde (200/204, nunca 404).
  2. POST sin token -> 401.
  3. POST con token WorkOS valido -> 202 Accepted, y el request llega a la Function App backend
     (confirmar en App Insights que el request aparece, no solo que APIM respondio).
  4. En el backend, X-User-Id y X-Tenant-Id llegan no vacios.
```

### 10. Reportar

Resumen claro y en orden, consolidando lo que reporto cada etapa (no reinterpretes sus resultados, propalos):

- **Etapa 1 (`/install-workos`)**: dashboard de WorkOS (recordatorio de responsabilidad del usuario), `WORKOS_CLIENT_ID`, `WORKOS_API_KEY`, adapter (instalado / ya existia / degradado a "proponer"), custodia del secreto.
- **Gate humano (Paso 6)**: verificado, o detenido con el motivo exacto (que credencial falta y como completarla).
- **Etapa 2 (`/install-apim`)**: prerequisitos, `WORKOS_CLIENT_ID`/`CORS_ALLOWED_ORIGINS`, agente `apim-gateway-scaffolder` (modulos, dominios agregados/omitidos), migracion de tenancy (token flip, dominios migrados/ya migrados/degradados/resolver custom).
- **Siguiente paso**: push + PR (si todo quedo verde), la lista de reconciliacion pendiente (si alguna etapa degrado), o "nada para commitear" (si todo ya estaba instalado).
- **Checklist post-deploy** (Paso 9): recordatorio de correrlo tras el `apply` de CI.

## Reglas

- **Nunca reimplementes la logica de `/install-workos` ni de `/install-apim`.** Este skill delega leyendo integramente su `Proceso` -- nunca duplica sus chequeos de idempotencia, sus nombres fijos, ni su HCL/C# generado.
- **Nunca saltees el gate humano del Paso 6.** No invoques la etapa 2 sin verificar que `WORKOS_CLIENT_ID` y `WORKOS_API_KEY` existen en el repo -- ese chequeo es el que evita el fallo tipico de aplicar APIM sin las credenciales de WorkOS registradas.
- **Nunca asumas las credenciales del gate si `gh` falla.** A diferencia de otras verificaciones tolerantes del harness, este gate es bloqueante: sin poder confirmar `WORKOS_CLIENT_ID`/`WORKOS_API_KEY`, deten el flujo antes de la etapa 2 en vez de continuar a ciegas.
- **Nunca pidas ni imprimas el valor de `WORKOS_API_KEY`** ni de ningun otro secreto -- ni este skill ni las etapas que invoca lo hacen; solo se verifica su existencia.
- **Nunca hagas push si alguna etapa quedo degradada** (adapter sin build verde en la etapa 1, o algun `--domain`/dominio de tenancy sin reconciliar en la etapa 2) -- deja la reconciliacion pendiente explicita en el reporte, igual que hace cada sub-skill por su cuenta.
- **Nunca crees un PR vacio.** Si ninguna etapa genero un commit nuevo (todo ya estaba instalado de una corrida anterior), repórtalo como tal en vez de forzar push + PR.
- **Nunca trabajes contra `main` directo.** Crea la rama compartida del Paso 4 antes de invocar cualquiera de las dos etapas.
- **Nunca ejecutes `terraform plan` ni `terraform apply`.** El `apply` real corre en CI al mergear el PR (MEF-ADR-0022); ni este skill ni las etapas que invoca llegan mas alla de `fmt`/`validate`.
- **Nunca crees los dominios destino.** Si `--identity-domain` o algun `--domain` no esta scaffoldeado, indica `/scaffold <dominio>` en el reporte -- nunca lo crees vos (el Paso 2 ya detiene el flujo si falta el dominio de identidad o si no hay ningun dominio scaffoldeado en el entorno).
- Si `$ARGUMENTS` no trae `--identity-domain` o al menos un `--domain`, responde con el uso exacto y detente -- no adivines dominios.
