---
description: "Mergea uno o varios PRs del consumidor a main via pr-sync."
---
<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/merge.md. No editar a mano. -->
```bash
mefisto_opencode_data_root() {
    if [ -n "${XDG_DATA_HOME:-}" ]; then printf '%s/mefisto\n' "$XDG_DATA_HOME"
    elif [ "$(uname -s)" = Darwin ]; then printf '%s/Library/Application Support/mefisto\n' "$HOME"
    else printf '%s/.local/share/mefisto\n' "$HOME"; fi
}
mefisto_opencode_launcher="$(mefisto_opencode_data_root)/active/bin/mefisto-opencode"
if [ ! -f "$mefisto_opencode_launcher" ] || [ -L "$mefisto_opencode_launcher" ] || [ ! -x "$mefisto_opencode_launcher" ]; then
    printf '%s\n' 'ERROR OpenCode: no hay una release activa valida; instale o active la release OpenCode.' >&2; exit 1
fi
MEFISTO_PACKAGE_ROOT="$("$mefisto_opencode_launcher" package-root)" || {
    printf '%s\n' 'ERROR OpenCode: no se pudo resolver la release activa; instale o active la release OpenCode.' >&2; exit 1;
}
case "$MEFISTO_PACKAGE_ROOT" in
    /*) ;;
    *) printf '%s\n' 'ERROR OpenCode: la release activa no devolvio una raiz absoluta; reinstale o active la release OpenCode.' >&2; exit 1 ;;
esac
MEFISTO_PACKAGE_ROOT="$(cd "$MEFISTO_PACKAGE_ROOT" 2>/dev/null && pwd -P)" || {
    printf '%s\n' 'ERROR OpenCode: la release activa no existe; reinstale o active la release OpenCode.' >&2; exit 1;
}
export MEFISTO_PACKAGE_ROOT
```

Antes de continuar, aborta si existe `src/internal/scripts/generate-internal-adapters.sh`: ese directorio es el repositorio de Mefisto, no un consumidor.

Mergea uno o varios PRs a main via `pr-sync`. Comunicate en **espanol**.

**Alcance**: este comando solo mergea PRs del proyecto consumidor.

## Entrada

Los argumentos estan en: $ARGUMENTS

Formas validas:

- `<numero-de-PR>` — un solo PR
- `<numero-de-PR> <numero-de-PR> ...` — varios PRs en orden
- `--all` — todos los PRs abiertos

Si `$ARGUMENTS` esta vacio, responde:

```
Uso: /mefisto:merge <numero-de-PR> [<numero-de-PR> ...] | --all
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

No pidas confirmacion adicional. El usuario ya la dio al escribir el comando explicitamente.

### 3. Invocar el script

Lanza directamente el script `pr-sync.sh` con `--merge`.

Para los PRs validados en el paso 1 (numeros separados por espacio):

```bash
"${MEFISTO_PACKAGE_ROOT}/scripts/pr-sync.sh" <PRs> --merge
```

Para todos los PRs abiertos:

```bash
"${MEFISTO_PACKAGE_ROOT}/scripts/pr-sync.sh" --all --merge
```

El script imprime progreso en tiempo real. Espera a que termine.

### 4. Colapsar paneles Herdr sobrantes (issue #799)

Bajo `HERDR_ENV=1`, si la tabla de resumen del paso anterior muestra al menos un PR en estado `mergeado`, cierra los paneles Herdr ociosos que dejo el lote (cada issue lanzado en paralelo termina en su propio pane apilado, y sin esto quedan abiertos hasta el proximo despacho). Es best-effort: nunca debe hacer fallar el comando ni bloquear el reporte final.

```bash
"${MEFISTO_PACKAGE_ROOT}/scripts/herdr-pipeline.sh" --collapse-panes
```

Imprime por stdout la cantidad de paneles cerrados (o "0"; nunca falla, incluso sin estado previo). Fuera de `HERDR_ENV=1`, no ejecutes este bloque.

### 5. Reportar resultado

El script ya imprime un resumen final con tabla `PR | Rama | Estado` y la ruta del log. Tu solo debes:

- Confirmar el exit code.
- Si hubo errores, apunta al log en `.mefisto/pipeline/logs/pr-sync-<ts>.log` y ofrece reintentar con el PR concreto:

  ```
  Reintentar el PR fallido: /mefisto:merge <num>
  ```
- Si el paso 4 conto una cantidad de paneles cerrados mayor que 0, mencionalo brevemente: "Paneles Herdr sobrantes cerrados: <n>". Si fue 0 (o no corriste el paso 4 por estar fuera de `HERDR_ENV=1`), no lo menciones.

---

## Reglas

- **Nunca hagas merges manuales** (`gh pr merge`, `git merge` + push, etc.). Todo pasa por `pr-sync.sh`.
- **No diagnostiques errores del script.** Reporta el error tal cual viene en su output y espera instruccion del usuario.
- **No reintentes automaticamente** un PR fallido. El script ya hace retry interno del merge con backoff exponencial. Si se rinde, es decision del usuario.
- **No instales dependencias** ni arregles el entorno. Si falta `gh`, `git` o `dotnet`, informa al usuario y detente.
- **No toques PRs que no esten en la lista final.** Si el usuario pidio `--all`, el script decide cuales procesar.
