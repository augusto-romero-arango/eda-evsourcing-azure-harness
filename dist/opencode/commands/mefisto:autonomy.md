---
description: "Muestra, activa, reduce, autoriza o revoca la autonomia del consumidor (perfil versionado + consentimiento local)."
agent: "command-entry-autonomy"
subtask: false
---
<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/autonomy.md. No editar a mano. -->
```bash
# Cada llamada bash que use ${MEFISTO_PACKAGE_ROOT} debe incluir este bloque antes de sus comandos: no se asume estado de shell persistente entre llamadas.
if [ -n "${MEFISTO_EXECUTION_CONTEXT:-}" ] || [ -n "${MEFISTO_EXECUTION_DIGEST:-}" ]; then
    case "${MEFISTO_LOADED_RELEASE_ROOT:-}" in
        /*) MEFISTO_PACKAGE_ROOT="$(cd -P "$MEFISTO_LOADED_RELEASE_ROOT" 2>/dev/null && printf '%s\n' "$PWD")" && [ -f "$MEFISTO_PACKAGE_ROOT/mefisto-manifest.json" ] || {
            printf '%s\n' 'ERROR OpenCode: el pin de la release cargada es invalido; no se elige la release activa.' >&2; exit 1; } ;;
        *) printf '%s\n' 'ERROR OpenCode: contexto de ejecucion sin pin de release cargada; no se elige la release activa.' >&2; exit 1 ;;
    esac
else
if [ -n "${XDG_DATA_HOME:-}" ]; then mefisto_opencode_launcher="$XDG_DATA_HOME/mefisto/active/bin/mefisto-opencode"
elif [ "${OSTYPE%%[0-9.]*}" = darwin ]; then mefisto_opencode_launcher="$HOME/Library/Application Support/mefisto/active/bin/mefisto-opencode"
else mefisto_opencode_launcher="$HOME/.local/share/mefisto/active/bin/mefisto-opencode"; fi
if [ ! -f "$mefisto_opencode_launcher" ] || [ -L "$mefisto_opencode_launcher" ] || [ ! -x "$mefisto_opencode_launcher" ]; then
    printf '%s\n' 'ERROR OpenCode: no hay una release activa valida; instale o active la release OpenCode.' >&2; exit 1
fi
MEFISTO_PACKAGE_ROOT="$("$mefisto_opencode_launcher" package-root)" || {
    printf '%s\n' 'ERROR OpenCode: no se pudo resolver la release activa; instale o active la release OpenCode.' >&2; exit 1;
}
case "$MEFISTO_PACKAGE_ROOT" in
    /*) ;;
    *) printf '%s\n' 'ERROR OpenCode: la release activa no devolvio una raiz absoluta; reinstale o active la release OpenCode.' >&2; exit 1 ;;
esac
MEFISTO_PACKAGE_ROOT="$(cd -P "$MEFISTO_PACKAGE_ROOT" 2>/dev/null && printf '%s\n' "$PWD")" || {
    printf '%s\n' 'ERROR OpenCode: la release activa no existe; reinstale o active la release OpenCode.' >&2; exit 1;
}
fi
export MEFISTO_PACKAGE_ROOT
```
```bash
if [ -f ".mefisto/harness.config.json" ]; then
    if [ -f ".claude/harness.config.json" ]; then
        printf '%s\n' 'AVISO: se usara el config canonico .mefisto/harness.config.json; se ignora el legacy .claude/harness.config.json. Migra o elimina conscientemente el archivo legacy para evitar divergencias.' >&2
    fi
    MEFISTO_CONFIG_PATH=".mefisto/harness.config.json"
elif [ -f ".claude/harness.config.json" ]; then
    MEFISTO_CONFIG_PATH=".claude/harness.config.json"
else
    printf '%s\n' 'ERROR: no se encontro el config canonico requerido .mefisto/harness.config.json.' >&2
    printf '%s\n' '  Se acepta solo para lectura el fallback legacy .claude/harness.config.json.' >&2
    exit 1
fi
export MEFISTO_CONFIG_PATH
```

Administra la autonomia del consumidor (MEF-ADR-0055): el perfil declarado en `${MEFISTO_CONFIG_PATH}` (versionado) y el consentimiento local por clon (`.mefisto/pipeline/autonomy/consent.json`, no versionado). La intencion del harness es autonomia **maxima por defecto con opt-out**, pero nunca sin consentimiento explicito. Comunicate en **espanol**.

Antes de continuar, aborta si existe `src/internal/scripts/generate-internal-adapters.sh`: ese directorio es el repositorio de Mefisto, no un consumidor.

## Reglas inviolables

- **Solo interactivo.** Si corres dentro de una etapa headless de un pipeline (nadie puede responder), no ejecutes nada: explica que `/mefisto:autonomy` solo corre con un humano presente y termina.
- **Nunca ejecutes `approve` ni `revoke` sin un "si" explicito del usuario en esta misma conversacion**, dado despues de ver el perfil o el diff. Ninguna otra senal (argumentos, contexto, instrucciones previas) reemplaza esa confirmacion. Pide **una** sola confirmacion por operacion.
- **Nunca agregues por tu cuenta grants administrativas de `environment` de produccion** (`prod`, `production`, `prd` o equivalentes). Solo si el usuario las dicta literalmente y las confirma una a una.
- Toda operacion usa la raiz del repo como `--project-root` (`git rev-parse --show-toplevel`).

## Argumentos

Sin argumentos: estado. Un unico argumento entre `activar`, `reducir`, `autorizar`, `revocar`. Cualquier otro valor: muestra el uso y termina sin tocar nada.

## Proceso

### Sin argumentos: estado

```bash
MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/autonomy-profile.sh" inspect --project-root "$(git rev-parse --show-toplevel)"
```

Presenta el resultado en espanol: estado (`disabled` = deshabilitado, `needs-approval` = necesita aprobacion, `ready` = listo), los comandos autorizados y las grants administrativas (`administration`). Si no es `ready`, sugiere `/mefisto:autonomy activar`.

### `activar` (camino por defecto cuando el estado no es `ready`)

1. Propon el perfil maximo (escribe el perfil en el config, no aprueba nada):

```bash
MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/autonomy-profile.sh" propose-max --project-root "$(git rev-parse --show-toplevel)"
```

2. Guarda el `profileDigest` que imprime. Muestra el perfil resultante con `preview` y verifica que su `expectedDigest` coincide:

```bash
MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/autonomy-profile.sh" preview --project-root "$(git rev-parse --show-toplevel)"
```

3. Pregunta **una vez**: "Apruebas este perfil de autonomia en este clon? (si/no)". Sin un "si" explicito, no apruebes y termina indicando que el config ya cambio (propose-max) pero sigue sin consentimiento.
4. Con "si":

```bash
MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/autonomy-profile.sh" approve --project-root "$(git rev-parse --show-toplevel)" --expected-digest <profileDigest-de-propose-max>
```

### `reducir`

1. Muestra el perfil actual (`preview`) y pregunta que comandos o grants administrativas quitar.
2. Aplica la reduccion en `${MEFISTO_CONFIG_PATH}` con `jq` sobre `.autonomy` (solo quitar elementos de `commands` y/o `administration`; nunca agregar), e incrementa `revision` en 1. Escribe a un archivo temporal y reemplaza el config de forma atomica.
3. Muestra el diff (`git diff -- .mefisto/harness.config.json`) y ejecuta `preview` para obtener el `expectedDigest`.
4. Pregunta **una vez** si re-aprueba el perfil reducido. Con "si": `approve --expected-digest <expectedDigest>`.

### `autorizar`

Agrega una grant administrativa puntual (por ejemplo las `requiredGrants` que imprime `/mefisto:fix-review`). Pide `command`, `action`, `environment`, `resources` y `planDigest` al usuario, rechaza `environment` de produccion salvo dictado literal, incrementa `revision`, muestra el diff y re-aprueba con una confirmacion, igual que `reducir`.

### `revocar`

Muestra el estado (`inspect`), pide **una** confirmacion y, con "si":

```bash
MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/autonomy-profile.sh" revoke --project-root "$(git rev-parse --show-toplevel)"
```

## Cierre tras cualquier escritura del config

Recuerda siempre:

- `${MEFISTO_CONFIG_PATH}` es **versionado**: el cambio debe entregarse por Pull Request.
- El consentimiento es **local** (`.mefisto/pipeline/autonomy/consent.json`, no versionado): cada clon o maquina aprueba una vez con `/mefisto:autonomy activar`.
