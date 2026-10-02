---
description: "Invoca al historiador para poner al dia la bitacora y encadena merge sobre el PR resultante."
---
<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/bitacora.md. No editar a mano. -->
```bash
# Cada llamada bash que use ${MEFISTO_PACKAGE_ROOT} debe incluir este bloque antes de sus comandos: no se asume estado de shell persistente entre llamadas.
if [ -n "${XDG_DATA_HOME:-}" ]; then mefisto_opencode_launcher="$XDG_DATA_HOME/mefisto/active/bin/mefisto-opencode"
elif [ "${OSTYPE%%[0-9.]*}" = darwin ]; then mefisto_opencode_launcher="$HOME/Library/Application Support/mefisto/active/bin/mefisto-opencode"
else mefisto_opencode_launcher="$HOME/.local/share/mefisto/active/bin/mefisto-opencode"; fi
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
MEFISTO_PACKAGE_ROOT="$(cd -P "$MEFISTO_PACKAGE_ROOT" 2>/dev/null && printf '%s\n' "$PWD")" || {
    printf '%s\n' 'ERROR OpenCode: la release activa no existe; reinstale o active la release OpenCode.' >&2; exit 1;
}
export MEFISTO_PACKAGE_ROOT
```

Orquesta el ciclo completo de la bitacora: invoca al agente `historiador` (multi-dia, issue #527) para procesar de forma autonoma las field notes pendientes y, si termina con un PR creado, encadena `/mefisto:merge` automaticamente sobre ese PR -- sin pedir confirmacion adicional, porque el usuario ya autorizo el ciclo completo (recopilacion, escritura, cierre atomico y merge) al invocar este skill. Un subagente no puede invocar slash commands, asi que este encadenamiento vive en el hilo principal (mismo patron que `/mefisto:install-auth` encadenando `/mefisto:install-workos` -> `/mefisto:install-apim`). Comunicate en **espanol**.

Antes de continuar, aborta si existe `src/internal/scripts/generate-internal-adapters.sh`: ese directorio es el repositorio de Mefisto, no un consumidor.

## Entrada

Los argumentos estan en: $ARGUMENTS

`/mefisto:bitacora` **no requiere argumentos**: el historiador descubre solo las field notes pendientes en `docs/bitacora/field-notes/` y por defecto procesa todo el backlog. La unica forma valida de argumento es una fecha `YYYY-MM-DD`, que se propaga al historiador como su *filtro opcional por dia* para reprocesar unicamente ese dia sin tocar el resto del backlog. Si `$ARGUMENTS` trae cualquier otra cosa, ignoralo y corre el backlog completo.

## Proceso

### 1. Invocar al agente `historiador` (CA-2)

Si `$ARGUMENTS` no trae una fecha `YYYY-MM-DD`, delega en el backlog completo:

invoca la tool `task` con el agente `historiador` y este mensaje: Pon al dia la bitacora procesando todas las field notes pendientes. Espera su resultado final y continua con el paso siguiente del comando.

Si `$ARGUMENTS` trae una fecha `YYYY-MM-DD`, delega acotado a ese dia (usa la fecha recibida en lugar de `<fecha>`):

invoca la tool `task` con el agente `historiador` y este mensaje: Pon al dia la bitacora procesando unicamente las field notes del dia <fecha>. Espera su resultado final y continua con el paso siguiente del comando.

El agente corre de forma autonoma de punta a punta: recopila el backlog, escribe (o extiende) una entrada por cada dia pendiente, mueve todas las field notes del backlog a `procesadas/` y ejecuta el cierre atomico (rama + entradas + PR), todo sin pausas ni confirmaciones intermedias. Por eso la delegacion es **sincronica** -- espera a que el agente termine y devuelva su mensaje final, nunca la lances en segundo plano --: el encadenamiento del merge (pasos 2-4) necesita el numero de PR que el historiador reporta en ese mensaje. Si el runtime no te devuelve el mensaje final del historiador, no adivines el PR: reportalo como un gap del runtime (debe registrarse como `bug` dependiente) y detente. Ese encadenamiento ocurre despues, ya de vuelta en este hilo: un subagente no puede invocar slash commands, y por eso ese eslabon vive en el skill y no dentro del historiador.

### 2. Extraer y verificar el numero de PR (CA-2, CA-4)

El contrato del historiador (CA-6 de #527) es reportar explicitamente el PR en su mensaje final con el patron `PR #<numero>` (ej: "PR #123 creado con las entradas del 2026-07-27 al 2026-08-04."). Toma el numero de su **mensaje final**, no de cualquier `#N` que aparezca en el medio de la conversacion: el historiador cita issues y PRs ajenos al armar cada entrada, y confundirlos aca mergearia el PR equivocado.

- **Si NO aparece ningun PR** -- el historiador reporto que no habia field notes pendientes, o fallo en algun punto antes de crear el PR -- reporta el resultado tal cual lo dijo el historiador y **detente sin invocar `/mefisto:merge`** (CA-4).
- **Si aparece un numero**, confirmalo antes de encadenar un merge automatico (a diferencia de `/mefisto:merge` invocado a mano, aca el numero no lo tipeo el usuario: lo leiste de una conversacion):

  ```bash
  gh pr view <num> --json number,state,headRefName,files
  ```

  Verifica que el PR este `OPEN` y que sus archivos caigan bajo `docs/bitacora/` (las entradas nuevas y/o los movimientos a `procesadas/`). Si el PR no existe, ya esta `MERGED`/`CLOSED`, o no toca la bitacora, **no mergees**: reporta el numero que leiste, lo que devolvio `gh pr view`, y detente para que el usuario decida (mismo criterio del CA-4).

- Con el numero verificado, continua al paso 3.

### 3. Encadenar `/mefisto:merge <PR>` (CA-3)

Con el numero de PR verificado, lee `"${MEFISTO_PACKAGE_ROOT}/commands/mefisto:merge.md"` (el documento del comando `/mefisto:merge` de la distribucion activa) sin transcribirlo aca, y ejecuta integramente su `Proceso` para ese PR.

Ejecuta su `Proceso` completo (validar el PR, mostrar resumen, invocar `pr-sync.sh --merge`, reportar) tal cual, con el numero de PR del paso 2 como su `$ARGUMENTS` -- su `## Entrada` queda cubierta por ese numero, y su guard de consumidor por el de este skill. No pidas ninguna confirmacion adicional antes de mergear -- el usuario ya autorizo el ciclo completo al escribir `/mefisto:bitacora` explicitamente.

### 4. Reportar

Consolida en un solo resumen:
- Lo que reporto el historiador (dias procesados, field notes integradas, o el motivo de no haber creado PR).
- El PR verificado en el paso 2, o el motivo por el que no se mergeo nada (sin PR, o verificacion fallida).
- El resultado de `/mefisto:merge` (PR mergeado, o el error tal cual lo imprimio `pr-sync.sh`).

## Reglas

- **Nunca reimplementes la logica del historiador ni de `/mefisto:merge`.** Este skill delega leyendo integramente el `Proceso` de `/mefisto:merge`; el historiador corre de punta a punta de forma autonoma.
- **Nunca invoques `/mefisto:merge` sin un numero de PR leido del mensaje final del historiador y verificado con `gh pr view`** (abierto y tocando `docs/bitacora/`). Si no hay PR, o la verificacion falla, reportalo y detente (CA-4).
- **Nunca pidas una confirmacion adicional antes de mergear** un PR ya verificado. El usuario autorizo el ciclo completo al invocar el skill.
- **Nunca hagas merges manuales** (`gh pr merge`, `git merge` + push). Todo pasa por `/mefisto:merge` -> `pr-sync.sh`.
- **No diagnostiques errores de `pr-sync.sh`.** Propalos tal cual, igual que hace `/mefisto:merge`.
