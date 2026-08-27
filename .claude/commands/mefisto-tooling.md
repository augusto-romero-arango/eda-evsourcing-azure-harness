---
model: haiku
---

Lanza el pipeline INTERNO de tooling para un issue del repo de Mefisto, dentro de una sesion tmux. Comunicate en **espanol**.

**Alcance**: este skill solo opera dentro del repo del propio plugin Mefisto. Modifica archivos del harness (skills, agentes, scripts, hooks, ADRs, metadata del plugin). NO toca codigo de aplicacion ni archivos del consumidor.

## Entrada

El numero de issue esta en: $ARGUMENTS

Si `$ARGUMENTS` esta vacio, responde: `Uso: /mefisto-tooling <numero-de-issue> [--models 'agente=modelo[,agente=modelo...]']`

`$ARGUMENTS` puede incluir opcionalmente el flag `--models 'agente=modelo[,agente=modelo...]'` (issue #709, experimentos A/B de desempeno del harness): asigna el modelo de un stage puntual del pipeline mefisto-tooling. La clave es el nombre de agente que recibe `run_agent()` en `mefisto-tooling-pipeline.sh`: hoy `reviewer` (Stage 2) y `writer` -- que cubre **dos** stages, el Stage 1 y la etapa de merge, porque ambos invocan `run_agent` con ese mismo nombre. Un stage sin entrada en el mapa usa su default de siempre. Escribe el mapa **sin espacios** alrededor de las comas ni de los `=`: `$ARGUMENTS` se reenvia sin comillas en el paso 3, y un espacio lo partiria en dos argumentos. Ejemplo: `/mefisto-tooling 42 --models reviewer=opus,writer=sonnet`.

Extrae `ISSUE_NUM` como el primer token numerico de `$ARGUMENTS` y usalo en los pasos 1, 2 y 2.5 de abajo (esos `gh issue view`/`gh issue edit` no entienden `--models`; sin `--models`, `ISSUE_NUM` es simplemente `$ARGUMENTS` completo). `$ARGUMENTS` completo, con `--models` incluido si vino, se reenvia intacto a `mefisto-tmux-pipeline.sh --tooling` en el paso 3.

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
gh issue view $ISSUE_NUM --json number,title,state,labels -q '"#\(.number): \(.title) [\(.state)] labels: \([.labels[].name] | join(", "))"'
```

Si el issue no existe o esta cerrado (`CLOSED`), informa y detente.

### 2. Validar que es una tarea de tooling

Extrae labels del issue:

```bash
gh issue view $ISSUE_NUM --json labels -q '[.labels[].name] | join(",")'
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
gh issue edit $ISSUE_NUM --remove-label "bloqueado"
```

- Si **alguna** dependencia sigue abierta: muestra cuales y **detente**:

```
El issue #$ISSUE_NUM esta bloqueado. Dependencias abiertas:
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

Dentro de herdr (`HERDR_ENV=1` en el entorno), el script delega en la interfaz herdr (`mefisto-herdr-pipeline.sh`) y no hay nada que adjuntar: el pipeline queda corriendo en un pane de este mismo workspace con el visor en vivo del agente. En ese caso responde con:

```
Pipeline mefisto-tooling corriendo en un pane de este workspace (visor en vivo del agente).
Usa /mefisto-work-status para ver el progreso sin salir de aqui.
```

Fuera de herdr responde con:

```
Pipeline mefisto-tooling lanzado en tmux. Para monitorear:
  tmux -CC attach -t mefisto-tooling-<numero>

Usa /mefisto-work-status para ver el progreso sin salir de aqui.
```

## Reglas

- **No esperes a que termine.** El script corre en background (en un pane herdr o una sesion tmux). Devuelve el control inmediatamente.
- **No implementes nada tu mismo.** Solo lanza el script.
- Si tmux no esta instalado (y no estas dentro de herdr), el script lo detecta y muestra el error.
- **Si el cwd no es Mefisto, aborta**. Los skills publicados (`/tooling`) son para el consumidor.
