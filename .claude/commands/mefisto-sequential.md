Lanza el pipeline INTERNO secuencial para varios issues del repo de Mefisto, dentro de una sesion tmux. Comunicate en **espanol**.

**Alcance**: este skill solo opera dentro del repo del propio plugin Mefisto. Modifica archivos del harness (skills, agentes, scripts, hooks, ADRs, metadata del plugin). NO toca codigo de aplicacion ni archivos del consumidor.

En Mefisto solo existe el pipeline de tooling, asi que **no se expone** `--pipeline tdd|tooling`.

## Entrada

Los numeros de issues estan en: $ARGUMENTS

Si `$ARGUMENTS` esta vacio, responde: `Uso: /mefisto-sequential <issue1> <issue2> ...`

## Proceso

### 0. Verificar que estas en el repo de Mefisto

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git"; exit 1;
}
[ -f "$REPO_ROOT/.claude-plugin/plugin.json" ] || {
    echo "ERROR: este skill solo se ejecuta en el repo de Mefisto."
    echo "Si trabajas en un proyecto consumidor, usa /sequential en su lugar."
    exit 1
}
```

### 1. Validar cada issue

Para cada numero en `$ARGUMENTS`, ejecuta:

```bash
gh issue view <num> --json number,title,state,labels -q '"#\(.number): \(.title) [\(.state)] labels: \([.labels[].name] | join(", "))"'
```

Reglas de exclusion/abortar:

- Si el issue **no existe**: informalo y excluyelo de la lista.
- Si el issue esta `CLOSED`: informalo y excluyelo de la lista.
- Si el issue **no tiene** el label `tipo:tooling`: advierte y pregunta `s/n`. Si la respuesta es `n` (o no hay confirmacion), excluyelo de la lista.

### 1.5. Verificar label `bloqueado`

Para cada issue que sobreviva al paso 1 y tenga el label `bloqueado`, lee la seccion `## Dependencias` del body y extrae los numeros referenciados (patron `#NNN`).

Para cada referencia, consulta su estado:

```bash
gh issue view <num> --json state -q '.state'
gh pr view <num> --json state -q '.state'
```

- Si **todas** las dependencias estan cerradas (`CLOSED`) o mergeadas (`MERGED`): quita el label y deja el issue en la lista:

```bash
gh issue edit <num> --remove-label "bloqueado"
```

- Si **alguna** dependencia sigue abierta: **detente** y muestra cuales son. No lances el batch (el orden secuencial se rompe si un issue del grupo no puede correr).

```
El issue #<num> esta bloqueado. Dependencias abiertas:
  - #42: [titulo] (OPEN)

Resuelve estas dependencias antes de lanzar el batch.
```

### 2. Comprobar que queda al menos un issue valido

Si despues de filtrar la lista queda vacia, responde:

```
No quedo ningun issue valido para procesar. Aborto.
```

y detente.

### 3. Mostrar resumen y lanzar

Muestra la lista de issues que se procesaran en orden:

```
Secuencial --- N issues:
  1. #42: [titulo]
  2. #60: [titulo]
  3. #44: [titulo]
```

Luego lanza el motor secuencial dentro de tmux:

```bash
./.claude/scripts/mefisto-tmux-pipeline.sh --batch <issue1> <issue2> ...
```

### 4. Instrucciones de conexion

Responde con:

```
Batch secuencial mefisto lanzado en tmux. Para monitorear:
  tmux -CC attach -t mefisto-batch-<timestamp>

Los issues se procesaran en orden: pipeline -> PR -> merge -> sync verificado -> siguiente.
Usa /mefisto-work-status para ver el progreso sin salir de aqui.
```

### 5. Sincronizacion verificada entre eslabones (fail-loud)

El motor (`.claude/scripts/mefisto-batch-pipeline.sh`) procesa los issues en orden
`pipeline -> PR -> merge -> sync -> siguiente`. Para que una cadena con dependencias
funcione (ej. #44 depende de #43), cada eslabon debe construirse sobre el merge del
anterior. El batch lo garantiza asi:

- **Arranca solo en main/master.** Cada worktree del tooling-pipeline se crea desde la
  rama activa del repo principal; si no estas en main/master, el motor aborta antes de
  empezar con un mensaje claro (haz `git switch main` primero).
- **Sync verificado tras cada merge.** Despues de mergear el PR de un eslabon, el motor
  hace `git fetch origin main`, fast-forwardea (`--ff-only`) main local a `origin/main`
  y **confirma** que el commit de merge del PR quedo presente en main local antes de
  arrancar el siguiente issue.
- **Fail-loud, no best-effort.** Si el sync no se concreta (no se pudo confirmar el
  merge commit, hay divergencia local, el fetch fallo, etc.) y aun quedan issues por
  procesar, el motor **aborta la cadena** con un mensaje claro en lugar de continuar en
  silencio sobre un main desactualizado. Solo en el ultimo eslabon (sin un siguiente que
  dependa de el) degrada a warning.

Esto reemplaza el viejo `git pull origin main` best-effort, que silenciaba el fallo con
un warning `(continuando)` y dejaba que la cadena siguiera sobre un main potencialmente
atrasado.

## Reglas

- **No esperes a que termine.** El script corre en background dentro de tmux. Devuelve el control inmediatamente.
- **No implementes nada tu mismo.** Solo valida y delega al wrapper tmux.
- En Mefisto siempre se usa el pipeline de tooling. No expongas `--pipeline tdd|tooling` ni aceptes ese flag.
- Si tmux no esta instalado, el wrapper lo detecta y aborta.
- **Si el cwd no es Mefisto, aborta**. Los skills publicados (`/sequential`) son para el consumidor.
