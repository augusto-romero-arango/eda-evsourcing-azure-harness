Lanza el pipeline IaC para un issue de GitHub dentro de una sesion tmux. Comunicate en **espanol**.

## Pre-condicion: cwd != Mefisto

Este skill es del plugin publicado y solo aplica al repo consumidor. Mefisto no tiene infraestructura Terraform/Azure. Verifica antes de continuar:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /infra no aplica al repo de Mefisto."
    exit 1
fi
```

## Entrada

El numero de issue esta en: $ARGUMENTS

Si `$ARGUMENTS` esta vacio, responde: `Uso: /infra <numero-de-issue>`

## Proceso

### 1. Validar el issue

```bash
gh issue view $ARGUMENTS --json number,title,state,labels -q '"#\(.number): \(.title) [\(.state)] labels: \([.labels[].name] | join(", "))"'
```

Si el issue no existe o esta cerrado (`CLOSED`), informa y detente.

### 2. Validar que es una tarea de infra

Extrae labels del issue:

```bash
gh issue view $ARGUMENTS --json labels -q '[.labels[].name] | join(",")'
```

Verifica que tenga el label `tipo:infra`. Si no lo tiene, advierte al usuario:

```
Este issue no tiene el label tipo:infra.
Si es logica de dominio, usa /implement en su lugar.
Si es tooling, usa /tooling en su lugar.
Continuar de todos modos? (s/n)
```

### 3. Mostrar info y lanzar

Muestra una linea con el issue:

```
#42: Configurar Application Insights con daily cap
Tipo: infra | Estado: listo
```

Luego lanza el pipeline en tmux:

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"
"$PLUGIN_SCRIPTS/tmux-pipeline.sh" --infra $ARGUMENTS
```

### 4. Instrucciones de conexion

Responde con:

```
Pipeline infra lanzado en tmux. Para monitorear:
  tmux -CC attach -t infra-<numero>

Usa /work-status para ver el progreso sin salir de aqui.
```

## Reglas

- **No esperes a que termine.** El script corre en background dentro de tmux. Devuelve el control inmediatamente.
- **No implementes nada tu mismo.** Solo lanza el script.
- Si tmux no esta instalado, el script lo detecta y muestra el error.
