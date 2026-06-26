---
model: haiku
---

Lanza el pipeline secuencial para multiples issues dentro de una sesion tmux. Cada issue se enruta automaticamente al pipeline correcto segun su label tipo:*. Comunicate en **espanol**.

## Pre-condicion: cwd != Mefisto, grupos homogeneos

Este skill es del plugin publicado y solo aplica al repo consumidor:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /sequential no aplica al repo de Mefisto. Trabaja issues internos uno a uno con /mefisto-tooling."
    exit 1
fi
```

**Grupos homogeneos**: todos los issues del grupo deben pertenecer al repo activo. No uses flags `-R`.

## Entrada

Los numeros de issues estan en: $ARGUMENTS

Si `$ARGUMENTS` esta vacio, responde: `Uso: /sequential <issue1> <issue2> <issue3> ... [--pipeline tdd|tooling]`

## Proceso

### 1. Validar los issues

Para cada numero en los argumentos (excluyendo flags como --pipeline):

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

Luego lanza, pasando --pipeline si el usuario lo proporciono:

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"

# Sin override (enrutamiento automatico)
"$PLUGIN_SCRIPTS/tmux-pipeline.sh" --batch <issue1> <issue2> <issue3>

# Con override
"$PLUGIN_SCRIPTS/tmux-pipeline.sh" --batch --pipeline tooling <issue1> <issue2> <issue3>
```

### 3. Instrucciones de conexion

Responde con:

```
Secuencial lanzado en tmux. Para monitorear:
  tmux -CC attach -t batch-<timestamp>

Los issues se procesaran en orden: pipeline -> PR -> merge -> siguiente.
Usa /work-status para ver el progreso sin salir de aqui.
```

## Reglas

- **No esperes a que termine.** Devuelve el control inmediatamente.
- **No implementes nada tu mismo.** Solo lanza el script.
- Si el usuario pasa `--stop-on-error`, informale que ese flag requiere lanzar `batch-pipeline.sh` directamente (resuelto via `$PLUGIN_SCRIPTS`, igual que en el bloque de lanzamiento), porque `tmux-pipeline.sh` no lo soporta.
- Si el usuario pasa `--pipeline tdd|tooling`, pasalo al comando tmux-pipeline.sh.
