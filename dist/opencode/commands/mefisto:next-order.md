---
description: "Calcula el orden topologico de lanzamiento de los issues estado:listo del consumidor y deja lista la linea de sequential."
agent: "command-entry-next-order"
subtask: false
---
<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/next-order.md. No editar a mano. -->

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
