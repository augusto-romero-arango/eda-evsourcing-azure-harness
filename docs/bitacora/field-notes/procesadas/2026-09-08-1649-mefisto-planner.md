---
fecha: 2026-09-08
hora: 16:49
sesion: mefisto-planner
tema: Refinamiento de la resolucion de raiz activa del paquete
---

## Contexto

Se pidio elegir el siguiente borrador a refinar. Se priorizo #1054 porque su unica dependencia original, #1053, ya habia cerrado y porque desbloquea la migracion del corte vertical tooling publicado.

## Descubrimientos

- El adaptador Claude publicado traduce `{{mefisto:run ...}}` y `{{mefisto:package-root}}` directamente a `${CLAUDE_PLUGIN_ROOT}`, aunque esa variable no esta garantizada en el shell que termina ejecutando un slash command.
- El adaptador OpenCode traduce esas directivas a `${MEFISTO_PACKAGE_ROOT}`, pero ningun artefacto generado inicializa hoy esa variable.
- #1053 ya materializo una raiz OpenCode estable bajo `<data>/mefisto/active`, con manifiesto, release inmutable y launcher instalado; #1075 y #1076 dejaron disponibles ambos adaptadores publicados.
- Claude ya dispone del marker legacy `.claude/pipeline/.plugin-root`; el resolutor puede preferir el marker canonico cuando exista y conservar ese fallback sin recorrer el cache del marketplace.

## Decisiones

- #1054 queda acotado a materializar y validar una sola interfaz efectiva, `MEFISTO_PACKAGE_ROOT`, dentro de las salidas de ambos adaptadores.
- La migracion y prueba productiva de `/mefisto:tooling` permanece en #1061; no se incorpora a #1054.
- El adaptador Claude resuelve desde la variable propia del runtime o los markers canonico/legacy y valida `.claude-plugin/plugin.json`; nunca elige la version mas reciente de un cache.
- El launcher OpenCode gana un subcomando no interactivo `package-root` que reutiliza las validaciones del almacen de #1053 y devuelve solamente la ruta fisica activa.
- #1058 y #1091 no son dependencias de implementacion: la lectura canonica se prueba con fixture, el marker legacy mantiene compatibilidad y el puntero OpenCode ya existe independientemente de su proyeccion global.
- #1054 paso de `estado:borrador` a `estado:listo`; se retiro `bloqueado` y se conservaron seis criterios homogeneos y verificables.

## Descartado

- Incluir la migracion de `tooling` en el mismo issue, porque duplicaria el alcance ya asignado a #1061.
- Resolver desde el cwd, el root Git del consumidor o un barrido del cache, porque cualquiera puede seleccionar una distribucion distinta de la cargada.
- Sourcear un helper desde una raiz candidata antes de validar su metadata.

## Preguntas abiertas

- #1092 sigue siendo responsable de comparar las identidades Claude/OpenCode y reportar deriva cruzada.
- #1058 materializara la escritura canonica del marker Claude y #1091 proyectara globalmente la distribucion OpenCode; ninguna bloquea la primitiva refinada.

## Referencias

Issues creados: ninguno

Issue refinado: #1054
