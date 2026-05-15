Lanza el pipeline TDD en paralelo para multiples issues dentro de una sesion tmux. Cada issue corre en su propio tab. Los PRs se crean pero NO se mergean automaticamente. Comunicate en **espanol**.

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
Paralelo — 3 issues (cada uno en su propio tab):
  #42: Implementar calculo de horas extras nocturnas
  #43: Agregar validacion de jornada maxima
  #44: Calcular recargos dominicales
```

Luego lanza:

```bash
./scripts/tmux-pipeline.sh --parallel <issue1> <issue2> <issue3>
```

### 3. Instrucciones de conexion

Responde con:

```
Pipeline paralelo lanzado en tmux. Para monitorear:
  tmux -CC attach -t parallel-<timestamp>

Cada issue tiene su propio tab. Los PRs NO se mergean automaticamente.
Usa /work-status para ver el progreso sin salir de aqui.
```

## Reglas

- **No esperes a que termine.** Devuelve el control inmediatamente.
- **No implementes nada tu mismo.** Solo lanza el script.
- Los PRs creados no se mergean. Recuerdale al usuario que puede usar `./scripts/pr-sync.sh <PR_NUM> --merge` despues.
