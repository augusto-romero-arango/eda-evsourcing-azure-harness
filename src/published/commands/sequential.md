---
{
  "kind": "command",
  "id": "sequential",
  "description": "Lanza el pipeline secuencial para multiples issues dentro de una sesion tmux.",
  "profile": "fast",
  "arguments": "<issue1> <issue2> ... [--pipeline tdd|tooling]"
}
---

{{mefisto:assert-consumer-repo}}

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
{{mefisto:run tmux-pipeline.sh --batch $ARGUMENTS}}
```

### 3. Instrucciones de conexion

Dentro de Herdr (`HERDR_ENV=1` en el entorno), el wrapper delega en la interfaz Herdr y no hay nada que adjuntar: el batch queda corriendo en un pane de este mismo workspace con el visor en vivo, que salta solo de issue en issue. En ese caso responde con:

```
Secuencial corriendo en un pane de este workspace (visor en vivo del agente).
Los issues se procesaran en orden: pipeline -> PR -> merge -> siguiente.
Usa {{mefisto:command work-status}} para ver el progreso sin salir de aqui.
```

Fuera de Herdr responde con:

```
Secuencial lanzado en tmux. Para monitorear:
  tmux -CC attach -t batch-<timestamp>

Los issues se procesaran en orden: pipeline -> PR -> merge -> siguiente.
Usa {{mefisto:command work-status}} para ver el progreso sin salir de aqui.
```

## Reglas

- **No esperes a que termine.** Devuelve el control inmediatamente.
- **No implementes nada tu mismo.** Solo lanza el wrapper.
- Si el usuario pasa `--stop-on-error`, informale que ese flag requiere lanzar `{{mefisto:package-root}}/scripts/batch-pipeline.sh` directamente, porque `tmux-pipeline.sh` no lo soporta. Para detener un batch ya en marcha usa {{mefisto:command batch-stop}} en su lugar.
- Si el usuario pasa `--pipeline tdd|tooling`, pasalo tal cual al wrapper.
