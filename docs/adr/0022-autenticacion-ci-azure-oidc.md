# ADR-0022: Autenticacion de CI hacia Azure por OIDC (Workload Identity Federation)

- **Fecha**: 2026-06-26
- **Estado**: aceptado
- **Aplica a**: pipeline de CI/CD del proyecto consumidor (GitHub Actions), `scripts/setup-github-ci.sh`, el workflow de deploy que emite `domain-scaffolder` (Paso 5) y el bootstrap de infraestructura documentado en el README.

## Contexto

El marco despliega cada Function App (cada dominio) a Azure desde un workflow de GitHub Actions (`.github/workflows/deploy-<dominio>.yml`) que el `domain-scaffolder` genera (Paso 5). Ese workflow se autentica contra Azure con la action `azure/login` antes de publicar con `Azure/functions-action`.

Hasta ahora **las dos mitades del contrato de secrets no coincidian** (origen: issue #97, primer greenfield real del harness):

- El workflow de deploy esperaba **un** secret JSON `AZURE_CREDENTIALS` (`azure/login` con `creds:`).
- `scripts/setup-github-ci.sh` emitia **cuatro** secrets separados (`AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`), generados con `az ad sp create-for-rbac`.

Ningun secret coincidia con el otro, asi que `azure/login` no recibia credenciales validas y el deploy fallaba en el paso de autenticacion. No habia ningun ADR que fijara el modo de autenticacion de CI, asi que cada mitad habia evolucionado por su cuenta.

Habia que elegir **una** via para alinear ambos lados. El espacio de soluciones tiene dos caminos validos:

1. **Secret de cliente**: emitir el JSON unico `AZURE_CREDENTIALS` (formato `clientId`/`clientSecret`/`tenantId`/`subscriptionId`) y consumirlo con `creds:`.
2. **OIDC (OpenID Connect / Workload Identity Federation)**: un Service Principal **sin secret** con un *federated credential* que confia en los tokens efimeros que GitHub emite por workflow; `azure/login` recibe `client-id`/`tenant-id`/`subscription-id` y obtiene un token de acceso de corta vida por intercambio.

## Decision

**El CI del marco se autentica hacia Azure por OIDC (Workload Identity Federation). El Service Principal de CI no tiene secret.**

Concretamente:

- `scripts/setup-github-ci.sh` crea la aplicacion de Microsoft Entra + su Service Principal **sin** credencial de password, le asigna `Contributor` a nivel de suscripcion (alcance del deploy de Functions, no solo lectura del tfstate) y `Storage Blob Data Reader` sobre la Storage del tfstate, y le anade un **federated credential** que confia en `repo:<owner/repo>:ref:refs/heads/main`.
- El workflow de deploy declara `permissions: id-token: write` (y `contents: read` para `actions/checkout`) en el job `deploy`, y usa `azure/login` con los inputs separados `client-id` / `tenant-id` / `subscription-id`, NO `creds:`.
- Los unicos secrets de GitHub son **tres**: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`. **Ninguno es un secret de password.**

### El subject del federated credential

El *subject* del federated credential debe coincidir **exacto** con el claim que GitHub pone en el OIDC token; el matching de patrones no esta soportado para ramas/tags [3]. El workflow de deploy del scaffolder dispara en `push: branches: [main]` (mas `workflow_dispatch`, que desde `main` produce el mismo ref), con jobs **no atados a un GitHub Environment**, de modo que el subject canonico es:

```
repo:<owner/repo>:ref:refs/heads/main
```

Las demas formas (`...:environment:<Name>` para jobs atados a un Environment, `...:pull_request` para eventos de pull request) [2][4] quedan fuera del workflow que emite el marco. Si un consumidor cambia el trigger para desplegar desde otra rama, tag o un Environment, debe anadir el federated credential correspondiente; el script lo documenta en su salida y el scaffolder en la nota del Paso 5.

### Por que OIDC y no el secret de cliente

- **No hay secret que expire.** Un client secret de `az ad sp create-for-rbac` caduca (el harness lo fijaba en 1 ano). En un harness usado en multiples greenfield, eso es una bomba de tiempo: el deploy funciona y, al ano, falla en silencio con un error de autenticacion que nadie anticipa. OIDC usa tokens efimeros emitidos por GitHub en cada corrida; no hay nada que rotar.
- **Es la guia vigente de Azure y GitHub.** Azure documenta OIDC como el camino recomendado para `azure/login` desde GitHub Actions [1][5], y marca explicitamente el flujo de Service Principal + secret como **deprecado** [6]. `az ad sp create-for-rbac --sdk-auth` (el comando que producia el JSON `AZURE_CREDENTIALS`) tambien esta deprecado.
- **Superficie de credenciales mas pequena.** No se almacena ningun secreto de larga vida en GitHub; un secret filtrado de los repositorios deja de ser un vector.
- **El harness ya estaba a un paso.** El issue #90 subio el workflow a `azure/login@v3`, la version nativa de OIDC. Adoptar OIDC cierra el contrato en su forma moderna en vez de revivir el JSON deprecado.

### Frontera de alcance: autenticacion runtime cross-BC

Este ADR cubre la autenticacion de **CI/deploy** hacia Azure (OIDC / Workload Identity Federation). La autenticacion **runtime entre bounded contexts** — como un consumidor externo se autentica y autoriza contra el namespace de integracion del productor — **queda fuera de alcance** y es trabajo diferido. La seguridad inter-BC se logra primariamente por **topologia** (namespaces separados, ADR-0023); el RBAC least-privilege por entidad es una **recomendacion diferida** que se decidira al materializar la integracion cross-BC, no doctrina firme de este ADR.

## Alternativas consideradas

### Alt 1: alinear con el secret de cliente (`AZURE_CREDENTIALS`)

Hacer que `setup-github-ci.sh` emita el JSON unico y dejar el workflow con `creds:`. Era el cambio mas corto (el workflow ya usaba `AZURE_CREDENTIALS`; el resumen del scaffolder ya lo nombraba) y es universalmente valido para cualquier trigger sin acoplarse al subject del federated credential.

**Descartado** por el secret que expira (footgun operativo silencioso para un harness greenfield) y porque el camino de password esta deprecado por Azure [6]. La robustez de OIDC frente al failure mode "el CI muere al ano" pesa mas que la simplicidad de no depender del subject.

### Alt 2: managed identity con federated credential

Usar una user-assigned managed identity en vez de una app de Entra [1][5].

**Descartado**: una managed identity vive como recurso de Azure (necesita un resource group, ciclo de vida en Terraform) y aporta poco frente a la app de Entra para el caso "GitHub Actions deplega a una suscripcion". La app + SP es el patron documentado por defecto para GitHub→Azure y es lo que el script ya gestionaba.

## Consecuencias

### Positivas

- **Ambas mitades del contrato coinciden**: el script emite exactamente los tres secrets que el workflow consume (cierra #97).
- **Sin secret que rote ni expire**: elimina el modo de falla "el deploy muere al ano".
- **Alineado con la guia vigente de Azure/GitHub** [1][5] y sin depender de comandos/flujos deprecados [6].
- **Menos secrets** (3 en vez de 4) y ninguno sensible de larga vida.

### Negativas

- **Acoplamiento al subject**: el federated credential confia en `ref:refs/heads/main`. Si el consumidor despliega desde otro ref o detras de un Environment sin anadir el credential correspondiente, `azure/login` falla con un error de "no matching federated identity record". Mitigado: el marco controla el trigger generado (`branches: [main]`), el script imprime el subject configurado y advierte el caso, y la nota del Paso 5 del scaffolder lo documenta.
- **Permisos de Graph para el setup**: crear la app, el SP y el federated credential requiere permisos de gestion de aplicaciones en Microsoft Entra (comparables a los que ya exigia `az ad sp create-for-rbac`). No cambia el perfil del operador que corria el script.
- **Resolucion del slug del repo**: el script necesita el `owner/repo` para el subject. Se resuelve via `gh repo view` o el remote `origin`, con override por argumento; si no hay remote de GitHub ni `gh` autenticado, aborta pidiendo el slug.

## Referencias

- **[1]** "Use the Azure Login action with OpenID Connect" — prerrequisitos de OIDC (app de Entra o managed identity, role assignment, federated credential). https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect
- **[2]** "Deploy to Azure App Service by using GitHub Actions — Manually set up a GitHub Actions workflow (OpenID Connect)" — `az ad app create` / `az ad sp create` / role assignment / `az ad app federated-credential create` con `subject: repo:organization/repository:ref:refs/heads/main`. https://learn.microsoft.com/azure/app-service/deploy-github-actions#manually-set-up-a-github-actions-workflow
- **[3]** "Configure an app to trust an external identity provider" — formato del subject (`ref`, `environment`, `pull_request`); el matching de patrones no esta soportado para ramas/tags. https://learn.microsoft.com/entra/workload-id/workload-identity-federation-create-trust#configure-a-federated-identity-credential-on-an-app
- **[4]** "az ad app federated-credential" — `issuer`, `subject`, `audiences` (`api://AzureADTokenExchange`). https://learn.microsoft.com/cli/azure/ad/app/federated-credential
- **[5]** "Deploy Bicep files by using GitHub Actions — Generate deployment credentials (OpenID Connect)". https://learn.microsoft.com/azure/azure-resource-manager/bicep/deploy-github-actions#generate-deployment-credentials
- **[6]** Azure Verified Modules, "Bicep Contribution Flow — Configure a deployment identity": OIDC como opcion recomendada y "Option 2 [Deprecated]: Configure Service Principal + Secret". https://azure.github.io/Azure-Verified-Modules/contributing/bicep/bicep-contribution-flow/#2-configure-a-deployment-identity-in-azure
- **[7]** GitHub, "Azure Login action — Login with OpenID Connect (OIDC) (recommended)". https://github.com/Azure/login#login-with-openid-connect-oidc-recommended
- ADR-0023: Bounded Context, topologia de dos namespaces ASB y Open Host Service — recoge el eje runtime-cross-BC (diferido) que este ADR explicitamente no cubre.
