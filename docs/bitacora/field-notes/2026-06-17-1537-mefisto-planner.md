---
fecha: 2026-06-17
hora: 15:37
sesion: mefisto-planner
tema: refinamiento del draft #30 (resolucion de rutas de scripts y comandos bajo el modelo de plugin)
---

## Contexto

El issue #30 llego como draft `estado:borrador` originado desde el consumidor `Bitakora.ControlAsistencia` (creado cross-repo por el flujo publicado, unica operacion cross-repo permitida hacia Mefisto). El sintoma reportado desde el consumidor: las invocaciones de scripts del harness fallan cuando el plugin se ejecuta instalado via marketplace, porque las rutas no resuelven contra la ubicacion real del plugin ni contra el repo del consumidor.

Antes de refinar, verificamos la causa raiz contra el codigo del propio harness (no nos quedamos con el reporte de campo). La revision descubrio que el sintoma esconde dos defectos distintos, con causa raiz y ubicacion diferentes.

## Descubrimientos

- **Defecto A (lado comandos)**: los comandos `.md` invocan scripts con rutas `./scripts/` o `scripts/` relativas al cwd. Bajo el modelo de plugin instalado el cwd es el repo del consumidor, no el del plugin, asi que la ruta apunta a un directorio que no existe alli. Son 9 comandos afectados. El mecanismo canonico de Claude Code para esto, `${CLAUDE_PLUGIN_ROOT}`, no se usa en ningun sitio del repo.

- **Defecto B (lado scripts)**: los scripts derivan la ubicacion del repo del consumidor de `$SCRIPT_DIR/..`, lo cual asume que el script vive dentro del arbol del consumidor. Hallazgos concretos:
  - `tmux-pipeline.sh` ya calcula `_REPO_TOP` con `git rev-parse --show-toplevel` pero **descarta** ese valor y termina usando la derivacion fragil. La pieza correcta ya existe, solo hay que usarla.
  - `eda-lint.sh` valida `docs/eda/` del consumidor partiendo de la ubicacion del script; debe resolver el toplevel del consumidor con `git rev-parse --show-toplevel`.

- **El nudo de diseno**: el mecanismo canonico `${CLAUDE_PLUGIN_ROOT}` para referenciar scripts del plugin **no se puede verificar leyendo codigo**. Requiere comprobacion empirica ejecutando el plugin instalado desde un consumidor real. Esto es lo que separa el Defecto B (verificable y resoluble en este repo, con git rev-parse) del Defecto A (cuya solucion depende de un experimento de campo).

## Decisiones

Cuatro decisiones tomadas con el usuario:

1. **Partir #30 en dos issues por lado.** Reutilizamos #30 para el lado SCRIPTS y lo refinamos a `estado:listo`. Creamos #31 nuevo para el lado COMANDOS en `estado:borrador` + `bloqueado`, con `Depende de #30`. Razon: el lado scripts es verificable y resoluble ya; el lado comandos esta atado a un experimento empirico pendiente. Mezclarlos saturaria el pipeline con un issue mitad-listo mitad-bloqueado.

2. **El micro-experimento de `${CLAUDE_PLUGIN_ROOT}` queda como CA-1 de #31**, a ejecutar por el usuario desde un consumidor real. No se puede comprobar leyendo codigo del harness, asi que no pertenece a un issue `estado:listo`; es el gate que desbloqueara #31.

3. **`eda-lint.sh` se resuelve con `git rev-parse --show-toplevel`** para obtener el repo del consumidor, en lugar de derivarlo de la ubicacion del script. Confirmado y reflejado en los CAs de #30. Mismo patron aplica a `tmux-pipeline.sh`, que ya tiene el valor calculado y solo debe dejar de descartarlo.

4. **Sin ADR para la convencion.** Se trata como fix de tooling, no como decision arquitectonica del marco. Si el experimento de #31 confirma `${CLAUDE_PLUGIN_ROOT}` como mecanismo canonico y se generaliza a los 9 comandos, podria reconsiderarse documentarlo; por ahora no se modela.

## Descartado

- **Mantener #30 monolitico** (comandos + scripts en un solo issue): dejaria la mitad bloqueada por el experimento de campo y la otra mitad lista, impidiendo avanzar en lo verificable. Partir es reversible; saturar el pipeline interno con un issue ambiguo no lo es sin perder trabajo.

- **Tratar el reporte del consumidor como causa raiz sin verificar**: el reporte de campo era util como sintoma, pero la causa raiz real (dos defectos en dos lados) solo aparecio al revisar el codigo del harness. Confirmar contra el harness antes de marcar listo es la regla.

- **Resolver el lado comandos por inferencia** (asumir que `${CLAUDE_PLUGIN_ROOT}` funciona sin probarlo): el mecanismo no es verificable leyendo codigo; asumirlo arriesga refinar a `estado:listo` algo que falla en campo. Por eso #31 queda en borrador hasta el experimento.

## Preguntas abiertas

- El experimento de #31: confirma `${CLAUDE_PLUGIN_ROOT}` que el cwd-del-plugin es accesible desde un consumidor instalado via marketplace? El resultado define como se migran los 9 comandos y desbloquea #31.

- Si el experimento confirma el mecanismo y se generaliza, vale la pena un guard/lint que prohiba rutas `./scripts/` relativas en comandos `.md` futuros, para evitar regresiones del Defecto A.

## Referencias

Issues:
- #30 (SCRIPTS, `estado:listo`): Resolver el repo objetivo del consumidor en tmux-pipeline.sh y eda-lint.sh (no derivarlo de la ubicacion del script). Reutilizado desde el draft original.
- #31 (COMANDOS, `estado:borrador` + `bloqueado`, Depende de #30): Migrar las invocaciones de scripts en comandos .md al mecanismo canonico del plugin (CLAUDE_PLUGIN_ROOT). CA-1 = micro-experimento de `${CLAUDE_PLUGIN_ROOT}` ejecutado desde un consumidor.

ADRs anclados: Ninguno (tratado como fix de tooling).
