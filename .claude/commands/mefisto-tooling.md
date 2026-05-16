Lanza el pipeline INTERNO de tooling para un issue del repo de Mefisto, dentro de una sesion tmux. Comunicate en **espanol**.

**Alcance**: este skill solo opera dentro del repo del propio plugin Mefisto. Modifica archivos del harness (skills, agentes, scripts, hooks, ADRs, metadata del plugin). NO toca codigo de aplicacion ni archivos del consumidor.

## Entrada

El numero de issue esta en: $ARGUMENTS

Si `$ARGUMENTS` esta vacio, responde: `Uso: /mefisto-tooling <numero-de-issue>`

## Proceso

### 0. Verificar que estas en el repo de Mefisto

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git"; exit 1;
}
[ -f "$REPO_ROOT/.claude-plugin/plugin.json" ] || {
    echo "ERROR: este skill solo se ejecuta en el repo de Mefisto."
    echo "Si trabajas en un proyecto consumidor, usa /tooling en su lugar."
    exit 1
}
```

### 1. Validar el issue

```bash
gh issue view $ARGUMENTS --json number,title,state,labels -q '"#\(.number): \(.title) [\(.state)] labels: \([.labels[].name] | join(", "))"'
```

Si el issue no existe o esta cerrado (`CLOSED`), informa y detente.

### 2. Validar que es una tarea de tooling

Extrae labels del issue:

```bash
gh issue view $ARGUMENTS --json labels -q '[.labels[].name] | join(",")'
```

Verifica que tenga el label `tipo:tooling`. Si no lo tiene, advierte al usuario:

```
Este issue no tiene el label tipo:tooling.
Mefisto solo procesa issues de tooling con este pipeline.
Continuar de todos modos? (s/n)
```

### 2.5. Verificar label bloqueado

Si el issue tiene el label `bloqueado`, lee la seccion `## Dependencias` del body y extrae todos los numeros de issue/PR referenciados (patron `#NNN`).

Para cada referencia, consulta su estado:

```bash
gh issue view <num> --json state -q '.state'
gh pr view <num> --json state -q '.state'
```

- Si **todas** las dependencias estan cerradas (`CLOSED`) o mergeadas (`MERGED`): quita el label y continua:

```bash
gh issue edit $ARGUMENTS --remove-label "bloqueado"
```

- Si **alguna** dependencia sigue abierta: muestra cuales y **detente**:

```
El issue #$ARGUMENTS esta bloqueado. Dependencias abiertas:
  - #42: [titulo] (OPEN)

Resuelve estas dependencias antes de lanzar el pipeline.
```

### 3. Mostrar info y lanzar

Muestra una linea con el issue:

```
#18: Refactorizar pipeline tooling para soportar X
Tipo: tooling | Estado: listo | Repo: mefisto
```

Luego lanza el pipeline interno en tmux:

```bash
./.claude/scripts/mefisto-tmux-pipeline.sh --tooling $ARGUMENTS
```

### 4. Instrucciones de conexion

Responde con:

```
Pipeline mefisto-tooling lanzado en tmux. Para monitorear:
  tmux -CC attach -t mefisto-tooling-<numero>

Usa /mefisto-work-status para ver el progreso sin salir de aqui.
```

## Reglas

- **No esperes a que termine.** El script corre en background dentro de tmux. Devuelve el control inmediatamente.
- **No implementes nada tu mismo.** Solo lanza el script.
- Si tmux no esta instalado, el script lo detecta y muestra el error.
- **Si el cwd no es Mefisto, aborta**. Los skills publicados (`/tooling`) son para el consumidor.
