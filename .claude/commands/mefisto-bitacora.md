---
model: haiku
---

Orquesta el ciclo completo de la bitacora del propio plugin Mefisto: invoca al agente `mefisto-historiador` (issue #529) para procesar de forma autonoma las field notes pendientes y, si termina con un PR creado, encadena `/mefisto-merge` automaticamente sobre ese PR -- sin pedir confirmacion adicional, porque el usuario ya autorizo el ciclo completo (recopilacion, escritura, cierre atomico y merge) al invocar este skill. Un subagente no puede invocar slash commands, asi que este encadenamiento vive en el hilo principal (mismo patron que `/install-auth` encadenando `/install-workos` -> `/install-apim`, y que la contraparte publicada `/bitacora`). Comunicate en **espanol**.

**Alcance**: solo opera sobre la bitacora del propio plugin Mefisto. Para la bitacora de un proyecto consumidor, usa `/bitacora` publicado.

## Pre-condicion: estas en el repo de Mefisto

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git"; exit 1;
}
[ -f "$REPO_ROOT/.claude-plugin/plugin.json" ] || {
    echo "ERROR: este skill solo se ejecuta en el repo de Mefisto."
    echo "Si trabajas en un proyecto consumidor, usa /bitacora en su lugar."
    exit 1
}
```

Si el bloque imprime `ERROR`, detente y muestra el mensaje al usuario.

## Entrada

Los argumentos estan en: $ARGUMENTS

`/mefisto-bitacora` **no requiere argumentos**: el historiador descubre solo las field notes pendientes en `docs/bitacora/field-notes/` y por defecto procesa todo el backlog. La unica forma valida de argumento es una fecha `YYYY-MM-DD`, que se propaga al historiador como su *filtro opcional por dia* (`.claude/agents/mefisto-historiador.md`) para reprocesar unicamente ese dia sin tocar el resto del backlog. Si `$ARGUMENTS` trae cualquier otra cosa, ignoralo y corre el backlog completo.

## Proceso

### 1. Invocar al agente `mefisto-historiador` (CA-2)

```bash
claude --agent mefisto-historiador "Pon al dia la bitacora procesando todas las field notes pendientes."
```

Si `$ARGUMENTS` trae una fecha `YYYY-MM-DD`, invocalo acotado a ese dia:

```bash
claude --agent mefisto-historiador "Pon al dia la bitacora procesando unicamente las field notes del dia $ARGUMENTS."
```

El agente corre de forma autonoma de punta a punta: recopila el backlog, escribe (o extiende) una entrada por cada dia pendiente, mueve todas las field notes del backlog a `procesadas/` y ejecuta el cierre atomico (rama + entradas + PR), todo sin pausas ni confirmaciones intermedias. Por eso la invocacion corre en **primer plano** -- espera a que la sesion del agente termine, nunca uses `run_in_background` --: el encadenamiento del merge (pasos 2-4) necesita el numero de PR que el historiador reporta en su mensaje final. Ese encadenamiento ocurre despues, ya de vuelta en este hilo: un subagente no puede invocar slash commands, y por eso ese eslabon vive en el skill y no dentro del historiador.

### 2. Extraer y verificar el numero de PR (CA-2, CA-4)

El contrato del historiador (seccion "Al terminar" de `.claude/agents/mefisto-historiador.md`) es reportar explicitamente el PR en su mensaje final con el patron `PR #<numero>` (ej: "PR #123 creado con las entradas del 2026-07-27 al 2026-08-04."). Toma el numero de su **mensaje final**, no de cualquier `#N` que aparezca en el medio de la conversacion: el historiador cita issues y PRs ajenos al armar cada entrada, y confundirlos aca mergearia el PR equivocado.

- **Si NO aparece ningun PR** -- el historiador reporto que no habia field notes pendientes, o fallo en algun punto antes de crear el PR -- reporta el resultado tal cual lo dijo el historiador y **detente sin invocar `/mefisto-merge`** (CA-4).
- **Si aparece un numero**, confirmalo antes de encadenar un merge automatico (a diferencia de `/mefisto-merge` invocado a mano, aca el numero no lo tipeo el usuario: lo leiste de una conversacion):

  ```bash
  gh pr view <num> --json number,state,headRefName,files
  ```

  Verifica que el PR este `OPEN` y que sus archivos caigan bajo `docs/bitacora/` (las entradas nuevas y/o los movimientos a `procesadas/`). Si el PR no existe, ya esta `MERGED`/`CLOSED`, o no toca la bitacora, **no mergees**: reporta el numero que leiste, lo que devolvio `gh pr view`, y detente para que el usuario decida (mismo criterio del CA-4).

- Con el numero verificado, continua al paso 3.

### 3. Encadenar `/mefisto-merge <PR>` (CA-3)

Con el numero de PR verificado, lee integramente el `Proceso` de `/mefisto-merge` y ejecutalo para ese PR. El skill interno vive en el repo activo, asi que se lee desde la raiz del propio repo — resuelta **en este mismo bloque**, porque cada bloque `bash` corre en su propio proceso y el `REPO_ROOT` de la pre-condicion no sobrevive hasta aca:

```bash
cat "$(git rev-parse --show-toplevel)/.claude/commands/mefisto-merge.md"
```

Ejecuta su `Proceso` completo (validar el PR, mostrar resumen, mergear con `gh pr merge --squash --delete-branch`, reportar) tal cual, con el numero de PR del paso 2 como su `$ARGUMENTS` -- su `## Entrada` queda cubierta por ese numero, y su pre-condicion "estas en el repo de Mefisto" por la de este skill (misma verificacion). No pidas ninguna confirmacion adicional antes de mergear -- el usuario ya autorizo el ciclo completo al escribir `/mefisto-bitacora` explicitamente.

### 4. Reportar

Consolida en un solo resumen:
- Lo que reporto el historiador (dias procesados, field notes integradas, o el motivo de no haber creado PR).
- El PR verificado en el paso 2, o el motivo por el que no se mergeo nada (sin PR, o verificacion fallida).
- El resultado de `/mefisto-merge` (PR mergeado, o el error tal cual lo reporto).

## Reglas

- **Nunca reimplementes la logica del historiador ni de `/mefisto-merge`.** Este skill delega leyendo integramente el `Proceso` de `/mefisto-merge`; el historiador corre de punta a punta de forma autonoma.
- **Nunca invoques `/mefisto-merge` sin un numero de PR leido del mensaje final del historiador y verificado con `gh pr view`** (abierto y tocando `docs/bitacora/`). Si no hay PR, o la verificacion falla, repórtalo y detente (CA-4).
- **Nunca pidas una confirmacion adicional antes de mergear** un PR ya verificado. El usuario autorizo el ciclo completo al invocar el skill.
- **Nunca hagas merges manuales** (`gh pr merge` fuera de `/mefisto-merge`, `git merge` + push). Todo pasa por `/mefisto-merge`.
- **No diagnostiques errores de `/mefisto-merge`.** Propalos tal cual.
- **No invoca a `historiador`** (ese opera sobre proyectos consumidores, no aplica a Mefisto).
