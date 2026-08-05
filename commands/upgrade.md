---
model: haiku
---

Actualiza el plugin Mefisto instalado en este consumidor a la ultima version publicada, reemplazando el flujo manual de 4 pasos (UI de `/plugin`, reescribir `.claude/pipeline/.plugin-root` a mano, podar el cache de versiones viejas, `/reload-plugins`) por 1 comando + el reload final -- el unico paso que no es automatizable desde dentro de la sesion, porque lo declara el propio CLI (`claude plugin update` documenta "restart required to apply"). Comunicate en **espanol**.

## Pre-condicion: cwd != Mefisto

Este skill es del plugin publicado y solo aplica al repo consumidor. Mefisto se actualiza a si mismo por su propio flujo de release (`/mefisto-release`), no por este skill.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /mefisto:upgrade no aplica al repo de Mefisto."
    exit 1
fi
```

Si el bloque imprime `ERROR`, detente y muestra el mensaje al usuario.

## Proceso

### 1. Actualizar (marketplace + plugin) y diagnosticar el cache

Resuelve la raiz del plugin e invoca `scripts/update-plugin.sh` de forma plugin-relative (mismo patron que el resto de los skills publicados): ese script detecta el marketplace, actualiza el catalogo y el plugin sin interaccion, reescribe `.claude/pipeline/.plugin-root` a la version mas reciente del cache, imprime el delta de `CHANGELOG.md` entre la version que esta sesion tenia cargada y la nueva, y reporta -- sin borrar nada todavia -- que versiones del cache quedaron podables.

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"

UPDATE_SCRIPT="${PLUGIN_SCRIPTS}/update-plugin.sh"
if [ ! -f "$UPDATE_SCRIPT" ]; then
  echo "ERROR: no se hallo update-plugin.sh en el plugin ($UPDATE_SCRIPT)."
  echo "       Reinstala mefisto o reabre la sesion (hook SessionStart) y reintenta."
  exit 1
fi

bash "$UPDATE_SCRIPT"
```

Si el script termina con `ERROR` (CLI `claude` ausente, marketplace/plugin no encontrado en el cache, o el update del CLI fallo), muestra el mensaje tal cual y detente: no hay nada mas que hacer sin resolver esa causa raiz primero.

### 2. Presentar el resultado

Muestra al usuario la salida del bloque tal como la imprimio (version detectada, delta de CHANGELOG, lista de versiones podables). No la reinterpretes ni la reformules -- el script ya hizo el diagnostico completo.

### 3. Poda opt-in del cache (CA-4)

Este es el **unico** paso que puede borrar algo, y solo bajo confirmacion explicita del usuario. El paso 1 nunca borra nada (solo reporta).

Aplica este paso **solo si** la salida del paso 1 imprimio una lista de "Versiones podables en el cache". Si en cambio imprimio "Cache limpio: solo quedan la version cargada y la nueva", no hay nada que podar -- omite este paso.

1. **Pide confirmacion explicita**, mostrando la lista exacta de versiones que se borrarian (la que ya imprimio el paso 1), p. ej.: "Quedaron estas versiones viejas en el cache: `<lista>`. ¿Las borro? Nunca se toca la version cargada en esta sesion ni la nueva. [si/no]".
2. **No ejecutes nada sin un "si" explicito.** Si el usuario no confirma, no corras el script con `--prune`: informa que puede volver a correr `/mefisto:upgrade` mas adelante para podarlas, y termina el paso.
3. **Solo si el usuario confirma**, resuelve `$PLUGIN_SCRIPTS` de nuevo (cada bloque bash es un proceso nuevo, sin el estado del paso 1) e invoca el mismo script con `--prune`:

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"

bash "${PLUGIN_SCRIPTS}/update-plugin.sh" --prune
```

4. **Reporta el resultado** (que versiones se borraron) tal como lo imprimio el bloque.

### 4. Cerrar con el reload (CA-5)

Independientemente de si hubo poda o no, termina **siempre** con la instruccion explicita de recargar, citando la version destino que ya imprimio el paso 1 (linea "Version destino: `<version>`"): "Corre `/reload-plugins` (o reinicia la sesion) para activar la version `<version>`". Esta instruccion no es opcional ni cosmetica: sin el reload, esta sesion sigue ejecutando el codigo de la version vieja aunque el cache y `.plugin-root` ya apunten a la nueva.

## Reglas

- **El paso 1 nunca borra nada.** Solo actualiza el marketplace/plugin (operaciones aditivas: agregan una version nueva al cache, nunca quitan las viejas) y reescribe `.claude/pipeline/.plugin-root`. La unica operacion destructiva es la poda del paso 3, y exige un "si" explicito.
- **La poda nunca toca la version cargada en esta sesion ni la nueva.** Si el skill que esta corriendo ahora mismo se borrara a si mismo, la sesion activa romperia a mitad de ejecucion -- `scripts/update-plugin.sh` lo garantiza internamente (nunca confies en volver a implementar ese calculo aqui).
- **Nunca hardcodees el nombre del marketplace** (`augusto-romero-arango-harness` es el de referencia, pero un fork puede publicarse bajo otro nombre vía `repoSlug`): el script lo detecta por glob sobre el cache.
- Si `$ARGUMENTS` trae algo, ignoralo: `/mefisto:upgrade` no toma argumentos.
