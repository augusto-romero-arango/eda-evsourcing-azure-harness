---
description: "Consulta y administra la proyeccion de los adaptadores instalados de Mefisto."
argument-hint: "[status | enable opencode | disable opencode]"
---
<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/runtimes.md. No editar a mano. -->

Antes de continuar, aborta si existe `src/internal/scripts/generate-internal-adapters.sh`: ese directorio es el repositorio de Mefisto, no un consumidor.

Administra el lifecycle de las **proyecciones** de adaptadores ya instalados. Comunicate en **espanol**. No instala, actualiza ni selecciona releases; para esos cambios usa `/mefisto:upgrade`.

## Entrada

Los argumentos de la invocacion estan en: `$ARGUMENTS`.

Acepta exactamente una de estas formas:

```text
/mefisto:runtimes status
/mefisto:runtimes enable opencode
/mefisto:runtimes disable opencode
```

Antes de ejecutar cualquier bloque, compara la entrada completa, sin evaluarla como shell, con esas tres formas. Sin argumentos, muestra un selector con esas tres acciones, explica el efecto de cada una y pide una confirmacion antes de ejecutar la opcion elegida. La confirmacion del selector cuenta como la confirmacion de la accion. Para cualquier otra entrada, muestra solamente este uso y no consulta ni muta estado: `Uso: /mefisto:runtimes [status | enable opencode | disable opencode]`.

Despues de validar la entrada, resuelve el launcher y la raiz efectiva:

```bash
mefisto_lifecycle_data_root() {
    if [ -n "${XDG_DATA_HOME:-}" ]; then printf '%s/mefisto\n' "$XDG_DATA_HOME"
    elif [ "$(uname -s)" = Darwin ]; then printf '%s/Library/Application Support/mefisto\n' "$HOME"
    else printf '%s/.local/share/mefisto\n' "$HOME"; fi
}
mefisto_lifecycle_config_root() {
    if [ "${OPENCODE_CONFIG_DIR+x}" = x ]; then
        [ -n "$OPENCODE_CONFIG_DIR" ] || return 1
        printf '%s\n' "$OPENCODE_CONFIG_DIR"
    else
        printf '%s/opencode\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
    fi
}
MEFISTO_LIFECYCLE_LAUNCHER="$(mefisto_lifecycle_data_root)/active/bin/mefisto-opencode"
MEFISTO_LIFECYCLE_CONFIG_ROOT="$(mefisto_lifecycle_config_root)" || {
    printf '%s\n' 'Estado OpenCode: unavailable (OPENCODE_CONFIG_DIR esta definido pero vacio).' >&2
    MEFISTO_LIFECYCLE_CONFIG_ROOT='unavailable'
}
if [ ! -f "$MEFISTO_LIFECYCLE_LAUNCHER" ] || [ -L "$MEFISTO_LIFECYCLE_LAUNCHER" ] || [ ! -x "$MEFISTO_LIFECYCLE_LAUNCHER" ]; then
    printf 'Estado OpenCode: unavailable (no hay launcher estable disponible). Raiz efectiva: %s\n' "$MEFISTO_LIFECYCLE_CONFIG_ROOT" >&2
fi
export MEFISTO_LIFECYCLE_LAUNCHER MEFISTO_LIFECYCLE_CONFIG_ROOT
```

## Estado

Para `status`, `enable opencode` o `disable opencode`, si el launcher esta disponible, consulta **una sola vez por invocacion** su estado estructurado mediante:

```bash
"$MEFISTO_LIFECYCLE_LAUNCHER" projection-status
```

Captura por separado stdout y el codigo de salida. Acepta solo JSON con `schemaVersion: 1`, `configRoot` string, `activeVersion` y `ledgerRelease` string o null, y uno de estos pares estado/codigo: `disabled:0`, `enabled:0`, `stale:0`, `conflict:1` u `operation-in-progress:1`. Si el launcher no esta disponible o la respuesta no cumple exactamente ese contrato, informa `unavailable`, muestra `MEFISTO_LIFECYCLE_CONFIG_ROOT` como raiz global efectiva, muestra `activeVersion: null` y `ledgerRelease: null`, y no reproduzcas una respuesta invalida. En todo estado valido muestra `configRoot`, `activeVersion` y `ledgerRelease`, sin inspeccionar archivos de configuracion, proveedores, modelos, credenciales, tokens ni stores de autenticacion. Normaliza el estado estructurado `disabled` como `installed-disabled`; presenta tambien visiblemente `enabled`, `stale` o `conflict`; conserva `operation-in-progress` como una operacion en curso que se debe reintentar, sin repararla.

Muestra ademas `Claude Code (plugin): lifecycle administrado externamente`. Solo se informa esa limitacion: este comando no intenta habilitarlo ni deshabilitarlo.

## Habilitar

Para `enable opencode`, usa la unica consulta descrita arriba. Si hay `conflict`, `operation-in-progress` o `unavailable`, no muta nada. Si ya esta `enabled`, informa que no hubo cambios. Si esta `stale`, vuelve a proyectar exclusivamente la release activa. Para `installed-disabled`, exige que `activeVersion` no sea null y ejecuta solo:

```bash
"$MEFISTO_LIFECYCLE_LAUNCHER" project
```

La proyeccion adquiere el lock compartido. No consulta red, no descarga, no mueve `active` ni cambia la version. Si no hay una release activa valida, no intentes bootstrap ni reparaciones manuales: remite a `/mefisto:upgrade` desde una instalacion Mefisto activa.

## Deshabilitar

Para `disable opencode`, usa la unica consulta descrita arriba. Si hay `conflict` u `operation-in-progress`, no muta nada. Si ya esta `installed-disabled` o `unavailable`, informa que no hubo cambios. Antes de confirmar una invocacion directa -o antes de confirmar la opcion del selector-, advierte que, si la invocacion actual usa ese adaptador, el comando dejara de estar disponible al terminar y que reactivarlo requerira Claude Code con Mefisto activo o el launcher estable. No pidas una segunda confirmacion si la opcion ya se confirmo en el selector.

Despues de la confirmacion ejecuta solo:

```bash
"$MEFISTO_LIFECYCLE_LAUNCHER" deactivate
```

La deshabilitacion adquiere el lock compartido y retira exclusivamente el ledger, los enlaces y los directorios vacios propiedad de Mefisto bajo la raiz efectiva. Conserva releases, `active`, rollback y cualquier configuracion ajena.

## Reglas

- Consulta, habilitacion y deshabilitacion son idempotentes.
- No recorras el home para buscar otras proyecciones; usa solo la raiz efectiva que devuelve el estado.
- No uses `activate <semver>`: es el mecanismo avanzado de seleccion y rollback de una release instalada, fuera de este comando.
