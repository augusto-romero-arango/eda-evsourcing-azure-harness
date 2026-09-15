---
description: "Consulta y administra la proyeccion de los adaptadores instalados de Mefisto."
---
<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/runtimes.md. No editar a mano. -->

Antes de continuar, aborta si existe `src/internal/scripts/generate-internal-adapters.sh`: ese directorio es el repositorio de Mefisto, no un consumidor.

Administra el lifecycle de las **proyecciones** de adaptadores ya instalados. Comunicate en **espanol**. No instala, actualiza ni selecciona releases; para esos cambios usa `/mefisto:upgrade`.

```bash
mefisto_lifecycle_data_root() {
    if [ -n "${XDG_DATA_HOME:-}" ]; then printf '%s/mefisto\n' "$XDG_DATA_HOME"
    elif [ "$(uname -s)" = Darwin ]; then printf '%s/Library/Application Support/mefisto\n' "$HOME"
    else printf '%s/.local/share/mefisto\n' "$HOME"; fi
}
MEFISTO_LIFECYCLE_LAUNCHER="$(mefisto_lifecycle_data_root)/active/bin/mefisto-opencode"
if [ ! -f "$MEFISTO_LIFECYCLE_LAUNCHER" ] || [ -L "$MEFISTO_LIFECYCLE_LAUNCHER" ] || [ ! -x "$MEFISTO_LIFECYCLE_LAUNCHER" ]; then
    printf '%s\n' 'Estado OpenCode: unavailable (no hay launcher estable disponible).' >&2
fi
export MEFISTO_LIFECYCLE_LAUNCHER
```

## Entrada

Acepta exactamente una de estas formas:

```text
/mefisto:runtimes status
/mefisto:runtimes enable opencode
/mefisto:runtimes disable opencode
```

Sin argumentos, muestra un selector con esas tres acciones, explica el efecto de cada una y pide una confirmacion antes de ejecutar la opcion elegida. Para cualquier otra entrada, muestra solamente este uso y no muta estado: `Uso: /mefisto:runtimes [status | enable opencode | disable opencode]`.

## Estado

Para `status`, si el launcher esta disponible, consulta una sola vez su estado estructurado mediante:

```bash
"$MEFISTO_LIFECYCLE_LAUNCHER" projection-status
```

Si el launcher no esta disponible, informa `unavailable` y no lo invocas. Si responde, muestra siempre la raiz global efectiva `configRoot`, la release activa `activeVersion` y la release del ledger `ledgerRelease`, sin inspeccionar archivos de configuracion, proveedores, modelos, credenciales, tokens ni stores de autenticacion. Normaliza el estado estructurado `disabled` como `installed-disabled`; presenta tambien visiblemente `enabled`, `stale` o `conflict`; conserva `operation-in-progress` como una operacion en curso que se debe reintentar, sin repararla.

El lifecycle del adaptador de plugin es administrado externamente por su propio gestor. Solo se informa esa limitacion: este comando no intenta habilitarlo ni deshabilitarlo.

## Habilitar

Para `enable opencode`, primero consulta el estado estructurado. Si hay `conflict` u `operation-in-progress`, no muta nada. Si ya esta `enabled`, informa que no hubo cambios. Si esta `stale`, vuelve a proyectar exclusivamente la release activa. En cualquier otro estado con una release activa valida, ejecuta solo:

```bash
"$MEFISTO_LIFECYCLE_LAUNCHER" project
```

La proyeccion adquiere el lock compartido. No consulta red, no descarga, no mueve `active` ni cambia la version. Si no hay una release activa valida, no intentes bootstrap ni reparaciones manuales: remite a `/mefisto:upgrade` desde una instalacion Mefisto activa.

## Deshabilitar

Para `disable opencode`, primero consulta el estado estructurado. Si hay `conflict` u `operation-in-progress`, no muta nada. Si ya esta `installed-disabled` o `unavailable`, informa que no hubo cambios. Antes de confirmar, advierte que, si la invocacion actual usa ese adaptador, el comando dejara de estar disponible al terminar y que reactivarlo requerira otro Mefisto activo o el launcher estable.

Despues de la confirmacion ejecuta solo:

```bash
"$MEFISTO_LIFECYCLE_LAUNCHER" deactivate
```

La deshabilitacion adquiere el lock compartido y retira exclusivamente el ledger, los enlaces y los directorios vacios propiedad de Mefisto bajo la raiz efectiva. Conserva releases, `active`, rollback y cualquier configuracion ajena.

## Reglas

- Consulta, habilitacion y deshabilitacion son idempotentes.
- No recorras el home para buscar otras proyecciones; usa solo la raiz efectiva que devuelve el estado.
- No uses `activate <semver>`: es el mecanismo avanzado de seleccion y rollback de una release instalada, fuera de este comando.
