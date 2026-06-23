Mergea uno o varios PRs a main via `pr-sync`. Comunicate en **espanol**.

## Pre-condicion: cwd != Mefisto

Este skill es del plugin publicado y solo aplica al repo consumidor. Para PRs del propio plugin, usa `/mefisto-merge`:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /merge no aplica al repo de Mefisto. Usa /mefisto-merge en su lugar."
    exit 1
fi
```

## Entrada

Los argumentos estan en: $ARGUMENTS

Formas validas:

- `<numero-de-PR>` — un solo PR
- `<numero-de-PR> <numero-de-PR> ...` — varios PRs en orden
- `--all` — todos los PRs abiertos

Si `$ARGUMENTS` esta vacio, responde:

```
Uso: /merge <numero-de-PR> [<numero-de-PR> ...] | --all
```

Y detente.

---

## Proceso

### 1. Validar PRs

Si los argumentos son `--all`, salta al paso 2.

Si son uno o mas numeros, para cada numero consulta:

```bash
gh pr view <num> --json number,title,state,headRefName,mergeable,statusCheckRollup
```

- Si el PR no existe o esta `CLOSED` / `MERGED`: informalo y quitalo de la lista.
- Si todos los PRs fueron descartados: muestra el motivo y detente.

### 2. Mostrar resumen

Imprime la lista a procesar con titulo, rama y estado de checks para que el usuario vea exactamente que va a pasar:

```
Se mergearan via pr-sync:
  #120 [MERGEABLE, checks SUCCESS] Adicionar marcacion a ControlDiario...
  #121 [MERGEABLE, checks PENDING] Otra cosa...
```

No pidas confirmacion adicional. El usuario ya la dio al escribir `/merge` explicitamente.

### 3. Invocar el script

Lanza directamente el script `pr-sync.sh` del plugin (resuelto via `.claude/pipeline/.plugin-root`) con `--merge`. NO invoques al agente `pr-sync` — es un envoltorio delgado sobre el script y el skill ya cumple esa funcion.

Para PRs especificos:

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"
"$PLUGIN_SCRIPTS/pr-sync.sh" <pr1> <pr2> ... --merge
```

Para todos los PRs abiertos:

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"
"$PLUGIN_SCRIPTS/pr-sync.sh" --all --merge
```

El script imprime progreso en tiempo real. Espera a que termine (no uses `run_in_background`).

### 4. Reportar resultado

El script ya imprime un resumen final con tabla `PR | Rama | Estado` y la ruta del log. Tu solo debes:

- Confirmar el exit code.
- Si hubo errores, apuntar al log (`.claude/pipeline/logs/pr-sync-<ts>.log`) y ofrecer reintentar con el PR concreto:

  ```
  Reintentar el PR fallido: /merge <num>
  ```

---

## Reglas

- **Nunca hagas merges manuales** (`gh pr merge`, `git merge` + push, etc.). Todo pasa por `pr-sync.sh`.
- **No diagnostiques errores del script.** Reporta el error tal cual viene en su output y espera instruccion del usuario.
- **No reintentes automaticamente** un PR fallido. El script ya hace retry interno del merge con backoff exponencial (ver la logica de retry en `pr-sync.sh`). Si se rinde, es decision del usuario.
- **No instales dependencias** ni arregles el entorno. Si falta `claude`, `gh`, `git` o `dotnet`, informa al usuario y detente.
- **No toques PRs que no esten en la lista final.** Si el usuario pidio `--all`, el script decide cuales procesar.
