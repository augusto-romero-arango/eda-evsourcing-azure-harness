---
model: haiku
---

Actualiza Mefisto instalado en este consumidor a la ultima version publicada. Desde Claude Code, tambien alinea la distribucion OpenCode ya adherida a Mefisto o, con una unica confirmacion explicita, ofrece habilitarla por primera vez. La intencion es actualizar Mefisto, no cambiar la sesion viva: comunica siempre en **espanol** y termina indicando el reload o reinicio requerido.

## Pre-condicion: cwd != Mefisto

Este skill publicado solo aplica al repo consumidor (MEF-ADR-0019). Mefisto se actualiza a si mismo mediante `/mefisto-release`.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /mefisto:upgrade no aplica al repo de Mefisto."
    exit 1
fi
```

Si el bloque imprime `ERROR`, detente y muestra el mensaje al usuario.

## Proceso

### 1. Consultar la adhesion OpenCode antes de actualizar

Resuelve la raiz del plugin cargado para ubicar sus scripts. No leas `opencode.json`, configuracion ajena, providers, modelos, permisos ni auth stores. La unica autoridad de consentimiento es la salida JSON versionada de `projection-status`: la presencia de `active` o del launcher no basta.

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"

if [ -n "${MEFISTO_OPENCODE_LAUNCHER:-}" ]; then
  OPENCODE_LAUNCHER="$MEFISTO_OPENCODE_LAUNCHER"
elif [ -n "${XDG_DATA_HOME:-}" ]; then
  OPENCODE_LAUNCHER="$XDG_DATA_HOME/mefisto/active/bin/mefisto-opencode"
elif [ "$(uname -s)" = Darwin ]; then
  OPENCODE_LAUNCHER="$HOME/Library/Application Support/mefisto/active/bin/mefisto-opencode"
else
  OPENCODE_LAUNCHER="$HOME/.local/share/mefisto/active/bin/mefisto-opencode"
fi

OPENCODE_PROJECTION=disabled
OPENCODE_PROJECTION_JSON=''
if [ -x "$OPENCODE_LAUNCHER" ]; then
  if OPENCODE_PROJECTION_JSON=$("$OPENCODE_LAUNCHER" projection-status 2>&1); then
    OPENCODE_PROJECTION_RC=0
  else
    OPENCODE_PROJECTION_RC=$?
  fi
  OPENCODE_PROJECTION=unavailable
  if command -v jq >/dev/null 2>&1 && printf '%s' "$OPENCODE_PROJECTION_JSON" | jq -e '
    .schemaVersion == 1 and
    (.status == "disabled" or .status == "enabled" or .status == "stale" or
     .status == "conflict" or .status == "operation-in-progress") and
    (.configRoot | type == "string") and
    (.activeVersion == null or (.activeVersion | type == "string")) and
    (.ledgerRelease == null or (.ledgerRelease | type == "string"))
  ' >/dev/null 2>&1; then
    OPENCODE_PROJECTION=$(printf '%s' "$OPENCODE_PROJECTION_JSON" | jq -r '.status')
    case "$OPENCODE_PROJECTION:$OPENCODE_PROJECTION_RC" in
      disabled:0|enabled:0|stale:0|conflict:1|operation-in-progress:1) ;;
      *) OPENCODE_PROJECTION=unavailable ;;
    esac
  fi
fi
printf 'Estado de proyeccion OpenCode: %s\n' "$OPENCODE_PROJECTION"
[ -z "$OPENCODE_PROJECTION_JSON" ] || printf '%s\n' "$OPENCODE_PROJECTION_JSON"
```

Interpreta solo estos estados del contrato:

- `enabled` o `stale`: el ledger y enlaces validos expresan adhesion. `stale` conserva esa adhesion; no es una desactivacion.
- `disabled`: no hay adhesion proyectada; incluye primera instalacion, una release instalada sin proyectar y un `deactivate` deliberado.
- `conflict`: no es desactivacion. No repares ledger, enlaces ni configuracion global; informa el JSON y continua visiblemente solo con Claude.

Si el launcher no existe, tratalo como `disabled`. `operation-in-progress` y el estado local `unavailable` (respuesta invalida, version desconocida del contrato, codigo de salida incoherente o `jq` ausente) son estados seguros no alineables: informa que hay una operacion o diagnostico pendiente, no toques OpenCode y continua solo con Claude. No los presentes como `conflict` ni inventes consentimiento a partir de `active`.

### 2. Decidir una sola vez la actualizacion

Decide **antes** de invocar el script, para ejecutarlo una sola vez:

1. Para `enabled` o `stale`, invoca automaticamente el update con `--align-opencode`. No pidas confirmacion: la adhesión valida ya existe. El script instala/activa la misma version declarada por el manifiesto Claude destino, reproyecta, consulta `status` y verifica identidad.
2. Para `disabled`, pide una unica confirmacion explicita: "OpenCode no esta habilitado para Mefisto. ¿Quieres habilitarlo o reactivarlo y alinearlo con esta actualizacion? [si/no]". Solo si responde exactamente `si`, usa `--align-opencode`; si declina o no responde, actualiza solo Claude. No crees, actives ni reproyectes OpenCode en ese caso.
3. Para `conflict` o un estado seguro no alineable, explica que OpenCode requiere intervencion manual y actualiza solo Claude. Nunca pases `--align-opencode`.

```bash
UPDATE_SCRIPT="${PLUGIN_SCRIPTS}/update-plugin.sh"
if [ ! -f "$UPDATE_SCRIPT" ]; then
  echo "ERROR: no se hallo update-plugin.sh en el plugin ($UPDATE_SCRIPT)."
  echo "       Reinstala mefisto o reabre la sesion (hook SessionStart) y reintenta."
  exit 1
fi

# Usa exactamente una de estas dos invocaciones, segun la decision anterior.
bash "$UPDATE_SCRIPT" --align-opencode
# o, si OpenCode quedo deliberadamente deshabilitado o en conflicto:
bash "$UPDATE_SCRIPT"
```

Si el script termina con `ERROR`, muestra su salida tal cual. Una falla despues de aceptar habilitar OpenCode deja las releases existentes para reintento o rollback; no intentes una reparacion adicional ni una poda OpenCode.

### 3. Presentar evidencia y poda Claude opt-in

Muestra sin reinterpretar la salida del script. Reten la linea `Version cargada en esta sesion: <version>` y `Version destino: <version>`. Si OpenCode se alineo, muestra tambien su `status`, la release activa y el diagnostico JSON de identidad entre la raiz Claude destino y la raiz OpenCode activa. Nunca afirmes que la sesion viva ya cambio: la version cargada pertenece a esta sesion; la destino esta en disco para la proxima recarga.

La poda aplica solo al cache Claude y solo si el script lista "Versiones podables en el cache". Muestra la lista exacta y pide confirmacion explicita. Si responde exactamente `si`, invoca de nuevo el script con `--prune --loaded <version-cargada>`; si la version cargada fue desconocida, omite `--loaded`. Si no confirma, no borres nada. Nunca podes releases OpenCode.

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
bash "${PLUGIN_ROOT%/}/scripts/update-plugin.sh" --prune --loaded <version-cargada>
```

### 4. Cerrar con el reload

Independientemente de la poda o de OpenCode, termina siempre: "Corre `/reload-plugins` (o reinicia la sesion) para activar la version `<version-destino>` de Claude. La sesion actual sigue cargando `<version-cargada>` hasta entonces." Si OpenCode quedo habilitado, indica tambien que reinicie OpenCode para que descubra la proyeccion actualizada.

## Reglas

- `update-plugin.sh` es la autoridad para actualizar, bootstrap, activar, proyectar, consultar `status`, diagnosticar identidad y conservar releases de rollback; no reimplementes esos controles en el comando.
- Todas las mutaciones OpenCode que el script realiza usan su exclusion compartida. Un conflicto nunca autoriza una mutacion automatica.
- El update no borra nada. La unica operacion destructiva es la poda opt-in del cache Claude; nunca toca la version cargada en esta sesion ni la nueva.
- Nunca hardcodees el marketplace: el script lo deriva del cache cargado. Nunca aceptes argumentos: ignora `$ARGUMENTS`.
- Este comando permanece transitoriamente disponible solo desde Claude Code; no lo proyectes en OpenCode antes del gate de certificacion de MEF-ADR-0053.
