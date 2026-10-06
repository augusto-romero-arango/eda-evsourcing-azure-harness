---
description: "Lanza el pipeline secuencial para multiples issues dentro de una sesion tmux."
agent: "command-entry-sequential"
subtask: false
---
<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/sequential.md. No editar a mano. -->

Antes de continuar, aborta si existe `src/internal/scripts/generate-internal-adapters.sh`: ese directorio es el repositorio de Mefisto, no un consumidor.

Lanza el pipeline secuencial para multiples issues dentro de una sesion tmux. Cada issue se enruta automaticamente al pipeline correcto segun su label `tipo:*`. Comunicate en **espanol**.

**Grupos homogeneos**: todos los issues del grupo deben pertenecer al repo activo. No uses flags `-R`.

## Entrada

Los numeros de issues estan en: $ARGUMENTS

Si `$ARGUMENTS` esta vacio, responde: `Uso: /mefisto:sequential <issue1> <issue2> <issue3> ... [--pipeline tdd|tooling]`

## Proceso

### 1. Validar los issues

Para cada numero en los argumentos (excluyendo flags como `--pipeline`):

```bash
gh issue view <num> --json number,title,state,labels -q '"#\(.number): \(.title) [\(.state)] [\(.labels | map(.name) | join(", "))]"'
```

Si algun issue no existe o esta cerrado, informalo y excluyelo de la lista. Si no queda ningun issue valido, detente.

### 2. Mostrar resumen y lanzar

Muestra la lista de issues que se procesaran en orden, indicando el pipeline resuelto:

```
Secuencial --- 3 issues:
  1. #42: Implementar calculo de horas extras nocturnas [tdd-pipeline]
  2. #60: Configurar fixture de tests [tooling-pipeline]
  3. #44: Calcular recargos dominicales [tdd-pipeline]
```

Luego lanza, pasando `--pipeline` si el usuario lo proporciono:

```bash
MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/tmux-pipeline.sh" --batch $ARGUMENTS
```

### 3. Instrucciones de conexion

Dentro de Herdr (`HERDR_ENV=1` en el entorno), el wrapper delega en la interfaz Herdr y no hay nada que adjuntar: el batch queda corriendo en un pane de este mismo workspace con el visor en vivo, que salta solo de issue en issue. En ese caso responde con:

```
Secuencial corriendo en un pane de este workspace (visor en vivo del agente).
Los issues se procesaran en orden: pipeline -> PR -> merge -> siguiente.
Usa /mefisto:work-status para ver el progreso sin salir de aqui.
```

Fuera de Herdr responde con:

```
Secuencial lanzado en tmux. Para monitorear:
  tmux -CC attach -t batch-<timestamp>

Los issues se procesaran en orden: pipeline -> PR -> merge -> siguiente.
Usa /mefisto:work-status para ver el progreso sin salir de aqui.
```

## Reglas

- **No esperes a que termine.** Devuelve el control inmediatamente.
- **No implementes nada tu mismo.** Solo lanza el wrapper.
- Si el usuario pasa `--stop-on-error`, informale que ese flag requiere lanzar `${MEFISTO_PACKAGE_ROOT}/scripts/batch-pipeline.sh` directamente, porque `tmux-pipeline.sh` no lo soporta. Para detener un batch ya en marcha usa /mefisto:batch-stop en su lugar.
- Si el usuario pasa `--pipeline tdd|tooling`, pasalo tal cual al wrapper.
