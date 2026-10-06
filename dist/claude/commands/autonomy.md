---
description: "Muestra, activa, reduce, autoriza o revoca la autonomia del consumidor (perfil versionado + consentimiento local)."
argument-hint: "[activar | reducir | autorizar | revocar]"
model: "haiku"
---
<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/autonomy.md. No editar a mano. -->
```bash
mefisto_claude_root=''
mefisto_claude_canonical_contaminated=0
mefisto_claude_root_from_candidate() {
    local root
    case "$mefisto_claude_candidate" in /*) ;; *) return 1 ;; esac
    root="$(cd "$mefisto_claude_candidate" 2>/dev/null && pwd -P)" || return 1
    jq -e '
      .name == "mefisto" and
      (.version | type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$"))
    ' "$root/.claude-plugin/plugin.json" >/dev/null 2>&1 || return 1
    jq -e --arg version "$(jq -er '.version | strings' "$root/.claude-plugin/plugin.json" 2>/dev/null)" '
      (keys | sort) == ["commit", "runtime", "schemaVersion", "version"] and
      .schemaVersion == 1 and .runtime == "claude" and .version == $version and
      (.commit | type == "string" and test("^[0-9a-f]{40}$"))
    ' "$root/mefisto-manifest.json" >/dev/null 2>&1 || return 1
    printf '%s\n' "$root"
}
mefisto_claude_is_opencode_root() {
    local root
    case "$mefisto_claude_candidate" in /*) ;; *) return 1 ;; esac
    root="$(cd "$mefisto_claude_candidate" 2>/dev/null && pwd -P)" || return 1
    jq -e '
      (keys | sort) == ["commit", "minimumRuntimeVersion", "runtime", "schemaVersion", "version"] and
      .schemaVersion == 1 and .runtime == "opencode" and
      (.version | type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$")) and
      (.commit | type == "string" and test("^[0-9a-f]{40}$")) and
      (.minimumRuntimeVersion | type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))
    ' "$root/mefisto-manifest.json" >/dev/null 2>&1
}
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    mefisto_claude_candidate="$CLAUDE_PLUGIN_ROOT"
    mefisto_claude_root="$(mefisto_claude_root_from_candidate)" || {
        printf '%s\n' 'ERROR Claude: la raiz indicada por CLAUDE_PLUGIN_ROOT es invalida; reabra o reinstale el plugin.' >&2; exit 1;
    }
else
    mefisto_claude_cursor="$PWD"
    while :; do
        if [ -f "$mefisto_claude_cursor/.mefisto/pipeline/.plugin-root" ]; then
            mefisto_claude_candidate="$(< "$mefisto_claude_cursor/.mefisto/pipeline/.plugin-root")"
            if mefisto_claude_root="$(mefisto_claude_root_from_candidate)"; then break; fi
            if mefisto_claude_is_opencode_root; then
                mefisto_claude_canonical_contaminated=1
                break
            else
                printf '%s\n' 'ERROR Claude: metadata del marker canonico invalida; reabra o reinstale el plugin.' >&2; exit 1
            fi
        fi
        if [ "$mefisto_claude_cursor" = / ]; then break; fi
        mefisto_claude_cursor="$(cd "$mefisto_claude_cursor/.." && pwd -P)"
    done
    if [ -z "$mefisto_claude_root" ]; then
        mefisto_claude_cursor="$PWD"
        while :; do
            if [ -f "$mefisto_claude_cursor/.claude/pipeline/.plugin-root" ]; then
                mefisto_claude_candidate="$(< "$mefisto_claude_cursor/.claude/pipeline/.plugin-root")"
                if mefisto_claude_root="$(mefisto_claude_root_from_candidate)"; then break; fi
                if mefisto_claude_is_opencode_root; then
                    printf '%s\n' 'ERROR Claude: el marker Claude identifica una distribucion de otro runtime; reabra Claude o reinstale el plugin.' >&2; exit 1
                fi
                printf '%s\n' 'ERROR Claude: metadata del marker Claude invalida; reabra o reinstale el plugin.' >&2; exit 1
            fi
            if [ "$mefisto_claude_cursor" = / ]; then break; fi
            mefisto_claude_cursor="$(cd "$mefisto_claude_cursor/.." && pwd -P)"
        done
    fi
fi
if [ -z "$mefisto_claude_root" ]; then
    if [ "$mefisto_claude_canonical_contaminated" -eq 1 ]; then
        printf '%s\n' 'ERROR Claude: el marker canonico identifica una distribucion OpenCode y no existe un mirror Claude valido; reabra Claude o reinstale el plugin.' >&2
    else
        printf '%s\n' 'ERROR Claude: no se encontro una raiz Claude valida; reabra o reinstale el plugin.' >&2
    fi
    exit 1
fi
MEFISTO_PACKAGE_ROOT="$mefisto_claude_root"
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
MEFISTO_RUNTIME=claude "${MEFISTO_PACKAGE_ROOT}/scripts/autonomy-profile.sh" inspect --project-root "$(git rev-parse --show-toplevel)"
```

Presenta el resultado en espanol: estado (`disabled` = deshabilitado, `needs-approval` = necesita aprobacion, `ready` = listo), los comandos autorizados y las grants administrativas (`administration`). Si no es `ready`, sugiere `/mefisto:autonomy activar`.

### `activar` (camino por defecto cuando el estado no es `ready`)

1. Propon el perfil maximo (escribe el perfil en el config, no aprueba nada):

```bash
MEFISTO_RUNTIME=claude "${MEFISTO_PACKAGE_ROOT}/scripts/autonomy-profile.sh" propose-max --project-root "$(git rev-parse --show-toplevel)"
```

2. Guarda el `profileDigest` que imprime. Muestra el perfil resultante con `preview` y verifica que su `expectedDigest` coincide:

```bash
MEFISTO_RUNTIME=claude "${MEFISTO_PACKAGE_ROOT}/scripts/autonomy-profile.sh" preview --project-root "$(git rev-parse --show-toplevel)"
```

3. Pregunta **una vez**: "Apruebas este perfil de autonomia en este clon? (si/no)". Sin un "si" explicito, no apruebes y termina indicando que el config ya cambio (propose-max) pero sigue sin consentimiento.
4. Con "si":

```bash
MEFISTO_RUNTIME=claude "${MEFISTO_PACKAGE_ROOT}/scripts/autonomy-profile.sh" approve --project-root "$(git rev-parse --show-toplevel)" --expected-digest <profileDigest-de-propose-max>
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
MEFISTO_RUNTIME=claude "${MEFISTO_PACKAGE_ROOT}/scripts/autonomy-profile.sh" revoke --project-root "$(git rev-parse --show-toplevel)"
```

## Cierre tras cualquier escritura del config

Recuerda siempre:

- `${MEFISTO_CONFIG_PATH}` es **versionado**: el cambio debe entregarse por Pull Request.
- El consentimiento es **local** (`.mefisto/pipeline/autonomy/consent.json`, no versionado): cada clon o maquina aprueba una vez con `/mefisto:autonomy activar`.
