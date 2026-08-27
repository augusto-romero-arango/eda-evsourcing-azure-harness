---
model: haiku
---

Lanza el pipeline de tooling para un issue de GitHub dentro de una sesion tmux. Comunicate en **espanol**.

**Alcance**: este skill modifica unicamente artefactos del proyecto consumidor que NO son logica de dominio. Rutas permitidas: `.github/workflows/`, `.claude/harness.config.json`, `.claude/settings.json`, `pipeline-state/`, `scripts/` (custom del consumidor), `tests/` (fixtures y helpers, no logica de dominio), `docs/adr-proyecto/`, `docs/adr/` (ADRs locales del consumidor, con el prefijo propio que haya elegido o sin prefijo -- MEF-ADR-0030). Rutas prohibidas: cualquier archivo bajo `commands/`, `skills/`, `agents/`, `hooks/` o `.claude-plugin/`, y los ADRs del marco `docs/adr/mef-adr-*` (todo eso pertenece al plugin Mefisto). Si tu cambio requiere tocar el plugin, NO uses este skill: crea un draft en el repo de Mefisto via `gh issue create -R augusto-romero-arango/eda-evsourcing-azure-harness --label "estado:borrador" ...` y luego cambia al repo de Mefisto para trabajarlo con `/mefisto-tooling`.

## Entrada

El numero de issue esta en: $ARGUMENTS

Si `$ARGUMENTS` esta vacio, responde: `Uso: /tooling <numero-de-issue> [--models 'agente=modelo[,agente=modelo...]'] [--variant <label>]`

`$ARGUMENTS` puede incluir opcionalmente el flag `--models 'agente=modelo[,agente=modelo...]'` (experimentos A/B de desempeno del harness): asigna el modelo de un stage puntual del pipeline tooling. La clave es el nombre de agente que recibe `run_agent()` en `tooling-pipeline.sh`: hoy `reviewer` (Stage 2) y `writer` -- que cubre **dos** stages, el Stage 1 y la etapa de merge, porque ambos invocan `run_agent` con ese mismo nombre. Un stage sin entrada en el mapa usa su default de siempre. Escribe el mapa **sin espacios** alrededor de las comas ni de los `=`: `$ARGUMENTS` se reenvia sin comillas en el paso 3, y un espacio lo partiria en dos argumentos. Ejemplo: `/tooling 42 --models reviewer=opus,writer=sonnet`.

`$ARGUMENTS` tambien puede incluir opcionalmente el flag `--variant <label>` (segunda pieza del mecanismo de experimentos: correr el MISMO issue N veces en paralelo para comparar calidad/velocidad/costo). `<label>` es un slug de minusculas, digitos y guiones ([a-z0-9-], hasta 40 caracteres); un label invalido aborta el pipeline antes de crear el worktree. En modo variante, worktree/rama/nombres de log llevan el sufijo `-<label>` (dos corridas simultaneas del mismo issue sin este sufijo colisionarian), y el pipeline **no hace push, no abre PR y no muta el issue** (ni comentarios, ni labels, ni transiciones) -- la rama queda local, y el resumen final explica como promoverla a mano si esa variante gana la comparacion. Ese mismo criterio aplica a este skill: en modo variante, el paso 2.5 de abajo tampoco quita el label `bloqueado`. Se combina con `--models` para comparar modelo por variante (una variante sin `--models` es la corrida de control). Ejemplo de dos variantes paralelas:

```
/tooling 42 --variant a --models writer=sonnet
/tooling 42 --variant b --models writer=opus
```

Extrae `ISSUE_NUM` como el primer token numerico de `$ARGUMENTS` y usalo en los pasos 1, 2 y 2.5 de abajo (esos `gh issue view`/`gh issue edit` no entienden `--models` ni `--variant`; sin ninguno de los dos, `ISSUE_NUM` es simplemente `$ARGUMENTS` completo). `$ARGUMENTS` completo, con `--models`/`--variant` incluidos si vinieron, se reenvia intacto a `tmux-pipeline.sh --tooling` en el paso 3.

## Proceso

### 0. Verificar que NO estas en el repo de Mefisto

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git"; exit 1;
}
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: este skill es del plugin publicado y solo aplica al repo consumidor."
    echo "Estas en el repo de Mefisto. Para mejorar el plugin, usa /mefisto-tooling."
    exit 1
fi
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
Si es logica de dominio, usa /implement en su lugar.
¿Continuar de todos modos? (s/n)
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

**Excepcion en modo variante**: si `$ARGUMENTS` trae `--variant`, **NO** ejecutes ese `gh issue edit`. Una corrida de variante no muta el issue -- ni comentarios, ni labels, ni transiciones: solo produce una rama local para comparar. Informa que el label `bloqueado` queda puesto (lo quitara la corrida normal que abra el PR) y sigue al paso 3.

- Si **alguna** dependencia sigue abierta: muestra cuales y **detente**:

```
El issue #$ISSUE_NUM esta bloqueado. Dependencias abiertas:
  - #42: [titulo] (OPEN)
  - #55: [titulo] (OPEN)

Resuelve estas dependencias antes de lanzar el pipeline.
```

### 3. Mostrar info y lanzar

Muestra una linea con el issue:

```
#18: Implementar smoke tests para Service Bus triggers
Tipo: tooling | Estado: listo
```

Luego lanza el pipeline en tmux:

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"
"$PLUGIN_SCRIPTS/tmux-pipeline.sh" --tooling $ARGUMENTS
```

### 4. Instrucciones de conexion

Dentro de herdr (`HERDR_ENV=1` en el entorno), el script delega en la interfaz herdr y no hay nada que adjuntar: el pipeline queda corriendo en un pane de este mismo workspace con el visor en vivo del agente. En ese caso responde con:

```
Pipeline tooling corriendo en un pane de este workspace (visor en vivo del agente).
Usa /work-status para ver el progreso sin salir de aqui.
```

Fuera de herdr responde con:

```
Pipeline tooling lanzado en tmux. Para monitorear:
  tmux -CC attach -t tooling-<numero>

Usa /work-status para ver el progreso sin salir de aqui.
```

Si vino `--variant <label>`, la sesion tmux (o el titulo del pane en herdr) lleva el sufijo `-<label>` (p. ej. `tooling-<numero>-<label>`): ajusta el nombre de sesion del hint de conexion en consecuencia.

## Reglas

- **No esperes a que termine.** El script corre en background (en un pane herdr o una sesion tmux). Devuelve el control inmediatamente.
- **No implementes nada tu mismo.** Solo lanza el script.
- Si tmux no esta instalado (y no estas dentro de herdr), el script lo detecta y muestra el error.
