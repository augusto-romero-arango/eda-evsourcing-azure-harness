---
model: "haiku"
---

Escribe la senal de parada suave de los orquestadores publicados de Mefisto (`batch-pipeline.sh` y `parallel-pipeline.sh`). Comunicate en **espanol**.

## Pre-condicion: cwd != Mefisto

Este skill es del plugin publicado y solo aplica al repo consumidor:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /batch-stop no aplica al repo de Mefisto. Usa /mefisto-batch-stop en su lugar."
    exit 1
fi
```

## Proceso

### 1. Detectar si hay un orquestador corriendo

Criterio: el proceso real de `batch-pipeline.sh` o `parallel-pipeline.sh` -- ni la sesion tmux ni un log activo distinguen una corrida activa de una ya terminada sin volver a parsear su contenido.

```bash
pgrep -f "[s]cripts/batch-pipeline\.sh" >/dev/null 2>&1 || pgrep -f "[s]cripts/parallel-pipeline\.sh" >/dev/null 2>&1
```

El patron ancla en `scripts/` (no solo `batch-pipeline.sh` a secas) para no confundirse con el motor interno de Mefisto (`mefisto-batch-pipeline.sh`, que vive en `src/internal/scripts/` de OTRO repo/checkout): si ese proceso corre en la misma maquina, `batch-pipeline.sh` SI aparece como substring de `mefisto-batch-pipeline.sh`, pero `scripts/batch-pipeline.sh` no.

- Si **no** hay ningun proceso: responde y detente sin escribir nada:
  ```
  No hay ningun batch ni corrida paralela corriendo ahora mismo. No se escribio ninguna senal.
  ```
- Si **si** hay uno: continua al paso 2.

### 2. Escribir la senal

```bash
mkdir -p "$REPO_ROOT/pipeline-state"
touch "$REPO_ROOT/pipeline-state/batch-stop"
```

### 3. Confirmar

Responde:

```
Senal de parada escrita. El orquestador se detendra tras el trabajo en curso:
- batch-pipeline.sh completa el issue en curso entero (pipeline -> PR -> merge) y no arranca los siguientes.
- parallel-pipeline.sh deja terminar los worktrees ya en vuelo (pipeline -> PR, sin merge automatico) y no lanza mas issues de la cola.
Los issues no procesados quedaran "aplazado" en el resumen final, con la linea lista para relanzarlos en el mismo orden.
```

## Reglas

- No pidas confirmacion adicional: el usuario ya la dio al escribir `/batch-stop` explicitamente.
- No mates ningun proceso ni pane: la senal es cooperativa, el propio motor la consulta.
- No la escribas si no detectaste ningun orquestador corriendo (paso 1): dejarla puesta sin necesidad envenenaria la proxima corrida.
- La senal se autoconsume: el propio motor la borra al detenerse (`pipeline-state/` esta gitignored, MEF-ADR-0017). Este comando nunca la borra por su cuenta.
