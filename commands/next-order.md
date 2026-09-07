---
model: haiku
---

Calcula el orden topologico de lanzamiento de los issues `estado:listo` abiertos del repo consumidor, a partir de sus dependencias declaradas, y deja lista la linea de lanzamiento de `/mefisto:sequential`. Comunicate en **espanol**.

## Pre-condicion: cwd != Mefisto

Este skill es del plugin publicado y solo aplica al repo consumidor. Para el repo de Mefisto, usa `/mefisto-next-order`:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /next-order no aplica al repo de Mefisto. Usa /mefisto-next-order para el repo de Mefisto."
    exit 1
fi
```

Si el bloque imprime `ERROR`, detente y muestra el mensaje al usuario.

## Entrada

Este comando no acepta argumentos: siempre analiza TODO el universo `estado:listo` abierto del consumidor. Si `$ARGUMENTS` trae texto, ignoralo por completo -- no se lo pases al script -- y dilo en una nota al reportar la salida, para que el usuario sepa que su filtro no se aplico.

## Proceso

### 1. Resolver la raiz del plugin

Los ADRs y scripts del marco viven **dentro del plugin instalado**, no en el repo consumidor donde corre este skill:

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_ROOT="${PLUGIN_ROOT%/}"   # normaliza: sin barra final
```

### 2. Ejecutar el calculo

```bash
"$PLUGIN_ROOT/scripts/next-order.sh" --launch-command "/mefisto:sequential"
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
- **No propongas oleadas paralelas.** Este script calcula un unico orden lineal; agrupar issues sin dependencia mutua en oleadas para `/parallel` es el modo `oleadas` del agente `planner` (`claude --agent planner`), no este comando.
- **No lances el batch por tu cuenta.** La linea `/mefisto:sequential ...` queda lista para copiar; decidir si se lanza -- y con que subconjunto -- es del usuario.
