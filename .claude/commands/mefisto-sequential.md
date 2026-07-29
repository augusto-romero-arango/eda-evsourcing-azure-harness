---
model: haiku
---

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

### 1.5. Verificar label `bloqueado` (con resolucion intra-batch)

Para cada issue que sobreviva al paso 1 y tenga el label `bloqueado`, lee la seccion
`## Dependencias` del body y extrae **solo** los numeros precedidos por un marcador forward
canonico (`Depende de #NNN` / `Bloqueado por #NNN`, case-insensitive, en la misma linea).
Ignora referencias inversas (`Consumido por #NNN`, `Bloquea #NNN` / `Bloquea a #NNN`), notas
libres (`... se traslada a #NNN`, `Relacionado con #NNN`) y prosa: no son dependencias forward
de este issue.

La idea clave (issue #47): una dependencia abierta **no siempre** es un bloqueo. Como la
cadena hace `pipeline -> PR -> merge -> sync verificado -> siguiente` (ver paso 5 e issue
#46), si la dependencia es **otro issue del mismo batch que se procesa antes en el orden**,
quedara resuelta **durante** la ejecucion. Por eso clasificamos cada dependencia abierta:

- **(a) Satisfactible por el batch**: la dependencia es otro issue del batch y aparece
  **antes** en el orden. No es un bloqueo: el orden + el sync verificado (#46) garantizan
  que ya estara mergeada cuando arranque este eslabon.
- **(b) Bloqueo real**: la dependencia esta **fuera del batch** (y no esta `CLOSED`/`MERGED`),
  o esta **dentro del batch pero despues** en el orden (mal ordenada). En ambos casos el
  batch no la puede resolver por si mismo.

Las dependencias ya `CLOSED`/`MERGED` siguen siendo el caso ortogonal de siempre: estan
satisfechas y no cuentan como bloqueo (no importa si estaban o no en el batch).

**Regla de decision**:

- Si **todas** las dependencias abiertas de un issue son de tipo (a) (o ya estan cerradas):
  el batch **se puede lanzar** y el issue se procesa en su posicion. Se le **quita** el label
  `bloqueado` al validar (decision CA-5: el orden + el sync de #46 garantizan su resolucion,
  asi que mantener el label seria mentir sobre el estado).
- Si existe **al menos una** dependencia de tipo (b): **aborta** y no lances el batch,
  mostrando cual es y por que. Si la causa es una dependencia intra-batch mal ordenada,
  sugiere el reordenamiento concreto (ej. "mueve #44 antes de #43").

Para clasificar, necesitas la **lista ordenada** de issues que sobrevivieron al paso 1
(en el mismo orden de `$ARGUMENTS`). Invoca el script `mefisto-validate-batch-deps.sh`
pasando esa lista como argumentos, respetando el orden del batch:

```bash
./.claude/scripts/mefisto-validate-batch-deps.sh <issue1> <issue2> ...
```

El script interpreta el batch completo (no un issue a la vez) y termina con uno de tres
exit codes:

- **`0`**: el batch se puede lanzar. Ya quito el label `bloqueado` de los issues cuyas
  dependencias abiertas resuelve el propio orden del batch (regla de decision de arriba).
  Continua al paso 2.
- **`1`**: hay al menos un bloqueo real -- aborta, no se muto ningun label. Muestra el
  mensaje del script (incluye el reordenamiento concreto si la causa es una dependencia
  intra-batch mal ordenada, ej. "Mueve #44 antes de #43") y detente.
- **`2`**: se invoco sin argumentos -- no se valido nada. No interpretes esto como un OK
  vacio; vuelve a invocar con la lista de issues.

Ejemplos canonicos (issue #47):

- `/mefisto-sequential 44 43 45` (43 y 45 dependen de 44) -> **lanza**: 44 va antes que sus
  dependientes, asi que ambas dependencias son de tipo (a). Se les quita `bloqueado` a #43 y #45.
- `/mefisto-sequential 43 44` (43 depende de 44) -> **aborta**: 44 esta en el batch pero
  **despues** de #43 (tipo b). Mensaje: "Mueve #44 antes de #43".
- `/mefisto-sequential 43` (43 depende de 44, que no esta en el batch y sigue OPEN) ->
  **aborta**: bloqueo real fuera del batch.

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
