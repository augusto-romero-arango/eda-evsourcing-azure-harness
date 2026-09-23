---
{
  "kind": "command",
  "id": "parallel",
  "description": "Lanza pipelines en paralelo para multiples issues, cada uno en su propio pane o tab.",
  "profile": "fast",
  "arguments": "<issue1> <issue2> ... [--pipeline tdd|tooling]"
}
---

{{mefisto:assert-consumer-repo}}

Lanza pipelines en paralelo para multiples issues. Dentro de Herdr cada issue corre en su propio pane apilado en el workspace actual; fuera de Herdr, en una sesion tmux con un tab por issue. Los PRs se crean pero NO se mergean automaticamente. Comunicate en **espanol**.

**Grupos homogeneos**: todos los issues del grupo deben pertenecer al repo activo. El script subyacente (`parallel-pipeline.sh`) consulta cada issue con `gh issue view N` sin `-R`, asi que issues de otros repos se descartan automaticamente como UNKNOWN. No uses flags `-R` con este comando.

## Entrada

Los numeros de issues estan en: $ARGUMENTS

Si `$ARGUMENTS` esta vacio, responde: `Uso: /mefisto:parallel <issue1> <issue2> <issue3> ... [--pipeline tdd|tooling]`

## Proceso

### 1. Validar los issues

Para cada numero en los argumentos (excluyendo flags como `--pipeline`):

```bash
gh issue view <num> --json number,title,state,labels -q '"#\(.number): \(.title) [\(.state)] [\(.labels | map(.name) | join(", "))]"'
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

Si el grupo trae mas de un issue `tipo:projection`, avisa desde este resumen que {{mefisto:command sequential}} es el camino natural para un lote de puras proyecciones.

Luego lanza, pasando `--pipeline` si el usuario lo proporciono:

```bash
{{mefisto:run tmux-pipeline.sh --parallel $ARGUMENTS}}
```

### 3. Instrucciones de conexion

Dentro de Herdr (`HERDR_ENV=1` en el entorno), el wrapper delega en la interfaz Herdr y no hay nada que adjuntar: cada issue queda corriendo en su propio pane apilado de este workspace, con el visor en vivo de su agente y arranques escalonados de 30s. En ese caso responde con:

```
Pipeline paralelo corriendo: un pane apilado por issue en este workspace.
Los PRs NO se mergean automaticamente.
Usa {{mefisto:command work-status}} para ver el progreso sin salir de aqui.
```

Fuera de Herdr responde con:

```
Pipeline paralelo lanzado en tmux. Para monitorear:
  tmux -CC attach -t parallel-<timestamp>

Cada issue tiene su propio tab. Los PRs NO se mergean automaticamente.
Usa {{mefisto:command work-status}} para ver el progreso sin salir de aqui.
```

## Reglas

- **No esperes a que termine.** Devuelve el control inmediatamente.
- **No implementes nada tu mismo.** Solo lanza el wrapper.
- Los PRs creados no se mergean. Recuerdale al usuario que puede usar {{mefisto:command merge}} despues.
- Si el usuario pasa `--pipeline tdd|tooling`, pasalo tal cual al wrapper.
- **Issues `tipo:projection`: nunca deben correr dos a la vez.** Todas las proyecciones del BC comparten los archivos del worker de proyecciones (MEF-ADR-0034). En cualquiera de los dos modos pane (Herdr y tmux) un lote con dos o mas aborta con mensaje, antes de crear panes: el camino es {{mefisto:command sequential}}, o `{{mefisto:package-root}}/scripts/parallel-pipeline.sh` directo (su scheduler si los serializa dentro del lote sin frenar al resto).
- Para limitar la concurrencia con `--max-parallel`, lanza `{{mefisto:package-root}}/scripts/parallel-pipeline.sh` directo. Para detener esa corrida con cola usa {{mefisto:command batch-stop}}; el modo pane de este comando lanza todos los issues de entrada y no tiene cola que retener.
