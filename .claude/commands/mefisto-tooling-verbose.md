---
model: haiku
---

Lanza el pipeline INTERNO de tooling para un issue del repo de Mefisto igual que `/mefisto-tooling`, pero con el visor en vivo abierto en un tercer pane (`--verbose`, issue #435 sobre el visor `mefisto-stream-watch.sh` de #434). Delega integramente en `/mefisto-tooling` para toda la validacion; la unica desviacion del procedimiento es el flag que se pasa al wrapper tmux en el lanzamiento (y, en consecuencia, las instrucciones de conexion, que describen 3 panes en vez de 2). Comunicate en **espanol**.

**Alcance**: igual que `/mefisto-tooling` -- este skill solo opera dentro del repo del propio plugin Mefisto. Modifica archivos del harness (skills, agentes, scripts, hooks, ADRs, metadata del plugin). NO toca codigo de aplicacion ni archivos del consumidor.

## Por que una skill aparte, y no un flag en /mefisto-tooling

`/mefisto-tooling` interpola `$ARGUMENTS` crudo en sus validaciones (`gh issue view $ARGUMENTS --json ...`), asi que `/mefisto-tooling 528 --verbose` reventaria antes de llegar al lanzamiento. Ensenarle a reenviar el flag obligaria a separar el numero de issue de los flags **dentro de un prompt** -- un parser blando que se desincroniza de `extract_wrapper_flags` (`.claude/scripts/mefisto-tmux-pipeline.sh`) sin que nadie lo note en una corrida headless. Esta skill evita el problema de raiz: `$ARGUMENTS` sigue siendo un numero de issue pelado en las dos.

## Por que no hay variante para /mefisto-sequential ni para lotes

El visor renderiza una linea por accion del agente y solo aporta si hay alguien mirando: en un lote de varios issues son horas de scroll que nadie lee. Ademas `mefisto-stream-watch.sh` salta solo al stream mas reciente, asi que en un batch cambiaria de issue debajo del observador mientras este intenta seguir uno. Deliberado, no un olvido -- ver issue #533.

## Entrada

El numero de issue esta en: $ARGUMENTS

Si `$ARGUMENTS` esta vacio, responde: `Uso: /mefisto-tooling-verbose <numero-de-issue>`

`$ARGUMENTS` es un numero de issue pelado -- esta skill no parsea flags. `--verbose` lo agrega el Paso 2 al lanzar, no algo que el usuario escriba.

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

Si el bloque imprime `ERROR`, detente y muestra el mensaje al usuario.

### 1. Delegar en `/mefisto-tooling` hasta el lanzamiento (CA-2)

Lee integramente el skill delegado -- vive en el mismo repo, sin necesidad de resolver `$PLUGIN_ROOT` (patron interno de delegacion skill -> skill, ver `/mefisto-bitacora`):

```bash
cat "$(git rev-parse --show-toplevel)/.claude/commands/mefisto-tooling.md"
```

Ejecuta su `Proceso` completo para el issue en `$ARGUMENTS` tal cual, sin reproducir esa logica aca: Paso 1 (validar que el issue existe y esta abierto), Paso 2 (validar `tipo:tooling`), Paso 2.5 (label `bloqueado` y sus dependencias) y la primera mitad de su Paso 3 (mostrar la linea con info del issue). Si cualquiera de esas validaciones detiene el flujo (issue cerrado/inexistente, sin `tipo:tooling` y el usuario no confirma continuar, o dependencias abiertas), detente exactamente igual que `/mefisto-tooling` lo haria -- no llegues al Paso 2 de este skill.

Los dos ultimos tramos del skill delegado los **reemplazan** los pasos de aca y no se ejecutan: la segunda mitad de su Paso 3 (el lanzamiento sin flag) la reemplaza el Paso 2, y su Paso 4 (instrucciones de conexion de dos panes) la reemplaza el Paso 3. No lances el pipeline dos veces ni emitas los dos mensajes de conexion.

### 2. Lanzar con `--verbose` (unica desviacion, CA-3)

Donde la segunda mitad del Paso 3 de `/mefisto-tooling` lanzaria `./.claude/scripts/mefisto-tmux-pipeline.sh --tooling $ARGUMENTS`, esta skill suma el flag:

```bash
./.claude/scripts/mefisto-tmux-pipeline.sh --tooling $ARGUMENTS --verbose
```

### 3. Instrucciones de conexion -- layout de 3 panes (CA-4)

`--verbose` suma un tercer pane a la sesion tmux de siempre: **events.log arriba-izquierda** (`tail -f` del log de eventos del pipeline), **pipeline arriba-derecha** (el stage corriendo), y **visor en vivo abajo, a lo ancho completo** (`mefisto-stream-watch.sh`).

Responde con:

```
Pipeline mefisto-tooling lanzado en tmux (con visor en vivo). Para monitorear:
  tmux -CC attach -t mefisto-tooling-<numero>

Layout: events.log (arriba-izquierda), pipeline (arriba-derecha), visor en vivo (abajo, ancho completo).

Caveat: el visor descubre el *.stream.jsonl mas reciente y el pane se abre ANTES
de que el pipeline nuevo haya escrito el suyo -- hasta entonces muestra la traza
de la corrida ANTERIOR (su encabezado dice a que issue y stage pertenece) y salta
sola a la nueva en cuanto esta empieza a crecer (tras crear el worktree y validar
el DoR). No hace falta reconectar.

Usa /mefisto-work-status para ver el progreso sin salir de aqui.
```

### 4. Reportar

Si alguna validacion delegada del Paso 1 detuvo el flujo antes del lanzamiento, reporta el mismo mensaje que `/mefisto-tooling` habria mostrado -- no inventes uno nuevo ni reinterpretes el motivo.

## Reglas

- **Nunca reimplementes la logica de `/mefisto-tooling`.** Este skill delega leyendo integramente su `Proceso`; lo unico que le cambia es el flag `--verbose` en el lanzamiento (Paso 2) y el mensaje de conexion, que describe 3 panes (Paso 3).
- **No esperes a que termine.** El script corre en background dentro de tmux. Devuelve el control inmediatamente.
- **No implementes nada tu mismo.** Solo valida (delegado) y lanza el script.
- Si tmux no esta instalado, el script lo detecta y muestra el error.
- **Si el cwd no es Mefisto, aborta**. Los skills publicados (`/tooling`) son para el consumidor.
- **No hay variante para `/mefisto-sequential` ni para lotes** (`--batch`/`--parallel`) -- deliberado, ver "Por que no hay variante para /mefisto-sequential ni para lotes" arriba. No la agregues sin un issue propio (fuera de alcance de #533).
