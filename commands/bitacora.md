---
model: haiku
---

Orquesta el ciclo completo de la bitacora: invoca al agente `historiador` (multi-dia, issue #527) para procesar las field notes pendientes y, si termina con un PR creado, encadena `/merge` automaticamente sobre ese PR -- sin pedir confirmacion adicional, porque el gate humano ya ocurrio dentro del historiador (aprobacion del borrador de cada dia + confirmacion del cierre atomico). Un subagente no puede invocar slash commands, asi que este encadenamiento vive en el hilo principal (mismo patron que `/install-auth` encadenando `/install-workos` -> `/install-apim`). Comunicate en **espanol**.

## Pre-condicion: cwd != Mefisto

Este skill es del plugin publicado y solo aplica al repo consumidor. Para la bitacora del propio plugin, usa `/mefisto-bitacora`:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /bitacora no aplica al repo de Mefisto. Usa /mefisto-bitacora en su lugar."
    exit 1
fi
```

Si el bloque imprime `ERROR`, detente y muestra el mensaje al usuario.

## Proceso

### 1. Invocar al agente `historiador` (CA-2)

No se requieren argumentos: el historiador descubre solo las field notes pendientes en `docs/bitacora/field-notes/`.

```bash
claude --agent historiador "Pon al dia la bitacora procesando todas las field notes pendientes."
```

El agente es conversacional: presenta el backlog, propone un borrador por cada dia pendiente y pide tu aprobacion antes de escribir, y al final pide una confirmacion explicita para el cierre atomico (rama + entradas + movimiento de field notes + PR). Esta invocacion corre en el hilo principal -- interactua con el historiador directamente cuando te lo pida, nunca lo delegues a un subagente headless.

### 2. Extraer el numero de PR del mensaje final (CA-2, CA-4)

El contrato del historiador (CA-6 de #527) es reportar explicitamente el PR en su mensaje final con el patron `PR #<numero>` (ej: "PR #123 creado con las entradas del 2026-07-27 al 2026-08-04."). Busca esa coincidencia en la salida del paso 1.

- **Si aparece un numero de PR**: continua al paso 3.
- **Si NO aparece** -- el historiador reporto que no habia field notes pendientes, o el usuario cancelo el borrador o el cierre atomico en algun punto de la conversacion -- reporta el resultado tal cual lo dijo el historiador y **detente sin invocar `/merge`** (CA-4).

### 3. Encadenar `/merge <PR>` (CA-3)

Con el numero de PR en mano, lee integramente el `Proceso` de `/merge` del propio plugin y ejecutalo para ese PR:

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
cat "${PLUGIN_ROOT%/}/commands/merge.md"
```

Ejecuta su `Proceso` completo (validar el PR, mostrar resumen, invocar `pr-sync.sh --merge`, reportar) tal cual, con el numero de PR extraido en el paso 2. No pidas ninguna confirmacion adicional antes de mergear -- el usuario ya la dio al escribir `/bitacora` explicitamente, y el historiador ya paso por su propio gate humano antes de crear el PR.

### 4. Reportar

Consolida en un solo resumen:
- Lo que reporto el historiador (dias procesados, field notes integradas/excluidas, o el motivo de no haber creado PR).
- El resultado de `/merge` (PR mergeado, o el error tal cual lo imprimio `pr-sync.sh`).

## Reglas

- **Nunca reimplementes la logica del historiador ni de `/merge`.** Este skill delega leyendo integramente el `Proceso` de `/merge`; el historiador corre como agente conversacional completo, con su propio gate humano.
- **Nunca invoques `/merge` sin un numero de PR confirmado en el mensaje final del historiador.** Si el historiador no creo PR, repórtalo y detente (CA-4).
- **Nunca pidas una confirmacion adicional antes de mergear.** El gate humano ya ocurrio dentro del historiador.
- **Nunca hagas merges manuales** (`gh pr merge`, `git merge` + push). Todo pasa por `/merge` -> `pr-sync.sh`.
