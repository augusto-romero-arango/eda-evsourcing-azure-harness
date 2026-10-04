---
description: "Calcula el orden topologico de lanzamiento de los issues estado:listo del consumidor y deja lista la linea de sequential."
agent: "command-entry-next-order"
subtask: false
---
<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/next-order.md. No editar a mano. -->
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

Calcula el orden topologico de lanzamiento de los issues `estado:listo` abiertos del repo consumidor, a partir de sus dependencias declaradas, y deja lista la linea de lanzamiento de `/mefisto:sequential`. Comunicate en **espanol**.

Antes de continuar, aborta si existe `src/internal/scripts/generate-internal-adapters.sh`: ese directorio es el repositorio de Mefisto, no un consumidor.

## Entrada

Este comando no acepta argumentos: siempre analiza TODO el universo `estado:listo` abierto del consumidor. Si `$ARGUMENTS` trae texto, ignoralo por completo -- no se lo pases al script -- y dilo en una nota al reportar la salida, para que el usuario sepa que su filtro no se aplico.

## Proceso

### Ejecutar el calculo

```bash
MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/next-order.sh" --launch-command "/mefisto:sequential"
```

Doctrina completa del algoritmo (extraccion de dependencias, clasificacion bloqueo externo/ciclo/bloqueo indirecto/lanzable, Kahn con seleccion golosa): cabecera de `scripts/next-order.sh`. No la dupliques aqui.

Reproduce la salida **tal cual**, sin reordenarla, resumirla ni completarla con informacion propia: el reporte de ciclos/bloqueos (si los hay) al tope, la lista numerada de issues lanzables, y siempre terminando con la linea `/mefisto:sequential ...` lista para copiar.

Como leer el exit code -- el script nunca deja la salida vacia, asi que un exit distinto de `0` no significa "no hay nada que mostrar":

- **`0`**: hay al menos un issue lanzable. Reproduce la salida y termina.
- **`1`**: no quedo ningun issue lanzable (universo vacio, o todos en ciclos o bloqueados). **No es un fallo del comando**: reproduce igual la salida -- el motivo de cada exclusion esta ahi -- y no reintentes.
- **`2`**: fallo real (`gh issue list` no respondio, o se le pasaron argumentos invalidos). Reporta el mensaje de error tal cual.

Si el script emite una linea `ADVERTENCIA` de universo truncado, reproducela tambien: el orden pudo calcularse sobre un grafo incompleto.

## Reglas

- No dupliques a mano el calculo del orden ni la deteccion de ciclos: el script es la unica fuente de verdad.
- Este comando es de solo lectura: nunca muta labels ni bodies de issues.
- **No propongas oleadas paralelas.** Este script calcula un unico orden lineal; agrupar issues sin dependencia mutua en oleadas para `/parallel` es el modo `oleadas` del agente `planner`, no este comando.
- **No lances el batch por tu cuenta.** La linea `/mefisto:sequential ...` queda lista para copiar; decidir si se lanza -- y con que subconjunto -- es del usuario.
