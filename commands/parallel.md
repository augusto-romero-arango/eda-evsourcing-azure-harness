---
model: haiku
---

Lanza pipelines en paralelo para multiples issues. Dentro de herdr cada issue corre en su propio pane apilado en el workspace actual; fuera de herdr, en una sesion tmux con un tab por issue. Los PRs se crean pero NO se mergean automaticamente. Comunicate en **espanol**.

## Pre-condicion: cwd != Mefisto, grupos homogeneos

Este skill es del plugin publicado y solo aplica al repo consumidor:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /parallel no aplica al repo de Mefisto. Trabaja issues internos secuencialmente con /mefisto-tooling."
    exit 1
fi
```

**Grupos homogeneos**: todos los issues del grupo deben pertenecer al repo activo (consumidor). El script subyacente (`parallel-pipeline.sh`) consulta cada issue con `gh issue view N` sin `-R`, asi que issues de otros repos se descartan automaticamente como UNKNOWN. No uses flags `-R` con este skill.

## Entrada

Los numeros de issues estan en: $ARGUMENTS

Si `$ARGUMENTS` esta vacio, responde: `Uso: /parallel <issue1> <issue2> <issue3> ...`

## Proceso

### 1. Validar los issues

Para cada numero en los argumentos:

```bash
gh issue view <num> --json number,title,state -q '"#\(.number): \(.title) [\(.state)]"'
```

Si algun issue no existe o esta cerrado, informalo y excluyelo de la lista. Si no queda ningun issue valido, detente.

### 2. Mostrar resumen y lanzar

Muestra la lista de issues que se procesaran:

```
Paralelo — 3 issues (cada uno en su propio pane/tab):
  #42: Implementar calculo de horas extras nocturnas
  #43: Agregar validacion de jornada maxima
  #44: Calcular recargos dominicales
```

Luego lanza:

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"
"$PLUGIN_SCRIPTS/tmux-pipeline.sh" --parallel <issue1> <issue2> <issue3>
```

### 3. Instrucciones de conexion

Dentro de herdr (`HERDR_ENV=1` en el entorno), el script delega en la interfaz herdr y no hay nada que adjuntar: cada issue queda corriendo en su propio pane apilado de este workspace, con el visor en vivo de su agente y arranques escalonados de 30s. En ese caso responde con:

```
Pipeline paralelo corriendo: un pane apilado por issue en este workspace.
Los PRs NO se mergean automaticamente.
Usa /work-status para ver el progreso sin salir de aqui.
```

Fuera de herdr responde con:

```
Pipeline paralelo lanzado en tmux. Para monitorear:
  tmux -CC attach -t parallel-<timestamp>

Cada issue tiene su propio tab. Los PRs NO se mergean automaticamente.
Usa /work-status para ver el progreso sin salir de aqui.
```

## Reglas

- **No esperes a que termine.** Devuelve el control inmediatamente.
- **No implementes nada tu mismo.** Solo lanza el script.
- Los PRs creados no se mergean. Recuerdale al usuario que puede usar `/merge <PR_NUM>` despues.
- **Issues `tipo:projection`: nunca deben correr dos a la vez.** Todas las proyecciones del BC comparten los archivos del worker de proyecciones (MEF-ADR-0034). En cualquiera de los dos modos pane (herdr y tmux) un lote con dos o mas aborta con mensaje, antes de crear panes: el camino es `/sequential`, o `parallel-pipeline.sh` directo (su scheduler si los serializa dentro del lote sin frenar al resto). Si el grupo trae mas de uno, avisale al usuario desde el resumen del paso 2 que `/sequential` es el camino natural para un lote de puras proyecciones.
