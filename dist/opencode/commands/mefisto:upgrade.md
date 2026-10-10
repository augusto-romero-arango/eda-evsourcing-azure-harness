---
description: "Actualiza Mefisto en el runtime activo y alinea el par de adaptadores ya adherido o, con una confirmacion, lo habilita."
---
<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/upgrade.md. No editar a mano. -->
```bash
# Cada llamada bash que use ${MEFISTO_PACKAGE_ROOT} debe incluir este bloque antes de sus comandos: no se asume estado de shell persistente entre llamadas.
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
export MEFISTO_PACKAGE_ROOT
```

Antes de continuar, aborta si existe `src/internal/scripts/generate-internal-adapters.sh`: ese directorio es el repositorio de Mefisto, no un consumidor.

Actualiza Mefisto instalado en este consumidor a la ultima version publicada desde el runtime activo. Tambien alinea el adaptador par ya adherido o, con una unica confirmacion explicita, ofrece habilitarlo. La intencion es actualizar Mefisto, no cambiar la sesion viva: comunica siempre en **espanol** y termina indicando el reload o reinicio requerido. Nunca aceptes argumentos: ignora `$ARGUMENTS`.

## Proceso

### 1. Consultar el estado del par antes de actualizar

No leas configuracion ajena, providers, modelos, permisos ni auth stores. La unica autoridad es la salida JSON versionada de `upgrade.sh --status`:

MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/upgrade.sh" --status

Presenta el JSON sin reinterpretarlo. `installedVersion` es la version **instalada en disco** (la que cargara la proxima sesion); no es la version cargada en la sesion viva. `--status` es una consulta local: **no informa si existe una version mas nueva publicada**, asi que nunca autoriza concluir que Mefisto esta al dia. Estados posibles de `peer.state`:

- `enabled` o `stale`: el par expresa adhesion valida. `stale` conserva esa adhesion; no es una desactivacion.
- `disabled`: no hay adhesion del par; incluye primera instalacion, una release instalada sin proyectar y una desactivacion deliberada.
- `legacy`: el launcher del par responde con un uso anterior al contrato de estado. Su presencia no prueba adhesion previa.
- `conflict`, `operation-in-progress` o `unavailable`: estados seguros no alineables. No los reinterpretes como `legacy` ni como consentimiento.

### 2. Decidir una sola vez la actualizacion

Cada invocacion ejecuta la actualizacion de este paso **exactamente una vez**, sea cual sea el JSON de `--status` y aunque en esta misma sesion ya se haya corrido otro upgrade. `--status` solo decide si se pasa `--align-peer`. Nunca respondas "ya esta al dia" ni "no hay nada que actualizar" sin la salida del script: esa afirmacion solo puede venir de esa salida.

Decide **antes** de invocar el script, para ejecutarlo una sola vez:

| Estado del par | Decision |
|---|---|
| `enabled` / `stale` | Alinea automaticamente con `--align-peer`. No pidas confirmacion: la adhesion ya existe. |
| `disabled` | Pide una unica confirmacion: "El par de Mefisto no esta habilitado. ¿Quieres habilitarlo o reactivarlo y alinearlo con esta actualizacion? [si/no]". Solo si responde exactamente `si`, usa `--align-peer`; si declina o no responde, actualiza solo el runtime activo. |
| `legacy` | Pide una unica confirmacion: "El par tiene un launcher de una version anterior que no declara su estado. No se puede inferir que estuviera adherido a Mefisto. ¿Quieres migrarlo y alinearlo con esta actualizacion? [si/no]". Solo si responde exactamente `si`, usa `--align-peer`; si declina o no responde, actualiza solo el runtime activo. |
| `conflict` / `operation-in-progress` / `unavailable` | Explica el motivo visible (el JSON), indica que el par requiere intervencion manual y actualiza solo el runtime activo. Nunca pases `--align-peer`. |

Invoca exactamente una de estas dos formas, segun la decision:

Con alineacion del par:

MEFISTO_LOADED_ROOT='' MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/upgrade.sh" --align-peer

Solo el runtime activo:

MEFISTO_LOADED_ROOT='' MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/upgrade.sh" 2>&1

Si el script termina con `ERROR`, muestra su salida tal cual. Una falla deja las releases existentes para reintento o rollback; no intentes una reparacion adicional ni una poda.

### 3. Presentar evidencia

Muestra sin reinterpretar la salida del script. Reten `Version cargada en esta sesion: <version>` y `Version destino: <version>`. Si el par se alineo, muestra tambien su estado, su version y el diagnostico JSON de identidad entre ambas instalaciones. Nunca afirmes que la sesion viva ya cambio: la version cargada pertenece a esta sesion; la destino esta en disco para la proxima recarga.

### 4. Refrescar agentes herdr

Solo si `HERDR_ENV=1`, refresca los agentes herdr con la version nueva. Es best-effort: un fallo o salida vacia no debe impedir la poda ni el cierre.

MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/herdr-pipeline.sh" --refresh-agents

Reporta la salida sin reinterpretar: por cada linea no vacia `<pane_id> <runtime> <accion>`, muestra una tabla con las columnas `Pane`, `Runtime` y `Accion`. Si no hubo lineas, muestra exactamente: `Sin panes Herdr que refrescar`. No afirmes que la sesion o pane propio cambio. Fuera de herdr (`HERDR_ENV` distinto de `1`), no ejecutes ni menciones este paso.

### 5. Poda opt-in del runtime activo

La poda aplica solo al runtime activo y solo si el script listo versiones podables. Muestra la lista exacta y pide confirmacion explicita. Si responde exactamente `si`, invoca la poda pasando con `--only` exactamente esa lista (versiones separadas por coma, sin agregar ni quitar ninguna); la poda borra solo la interseccion con las podables recalculadas y reporta aparte las no confirmadas y las que ahora estan protegidas. Si la version cargada es conocida, agrega `--loaded <version-cargada>`. Si no confirma, no borres nada. Nunca podes la version cargada ni el par.

MEFISTO_LOADED_ROOT='' MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/upgrade.sh" --prune --only <versiones-confirmadas>

### 6. Cerrar con el reload

Independientemente de la poda, termina siempre: "Recarga o reinicia la sesion de tu runtime para activar la version `<version-destino>`. La sesion actual sigue cargando `<version-cargada>` hasta entonces." Si el par se alineo, agrega que reinicie tambien ese runtime. Si el reporte herdr incluyo `omitido:working` u `omitido:blocked`, agrega que esos panes deben recargarse a mano cuando terminen.

## Reglas

- `upgrade.sh` es la autoridad para actualizar, alinear el par, diagnosticar identidad y conservar releases de rollback; no reimplementes esos controles en el comando.
- Un conflicto nunca autoriza una mutacion automatica.
- El update no borra nada. La unica operacion destructiva es la poda opt-in del runtime activo; nunca toca la version cargada ni el par.
- El refresco de panes herdr es automatico y best-effort; nunca interrumpe un pane ocupado ni el pane propio.
