---
fecha: 2026-09-08
hora: 06:42
sesion: mefisto-planner
tema: Refinamiento y particion de #1053 (instalacion OpenCode) en cuatro issues
---

## Contexto

Se pidio refinar #1053 ("Instalar y activar globalmente Mefisto para OpenCode"),
issue del rollout de MEF-ADR-0053 ya en `estado:listo` pero con cuatro defectos
que la revision de complejidad simplificada no deja pasar.

## Descubrimientos

- **CA-3 original era inverificable en su turno**: exigia descubrimiento de
  Skills, MCP y hooks que llegan en #1055, #1056 y #1057-#1059, posteriores en
  la cadena.
- **MEF-ADR-0053 asigna nominalmente a #1053 una verificacion que ningun CA
  recogia**: decision 2 y su consecuencia negativa dicen que hasta que #1053
  compruebe el mecanismo de discovery global "esta decision no autoriza asumir
  ni implementar una forma de configuracion global".
- **Hueco en el rollout #1044-#1066**: el segundo parrafo de la decision 3
  (comparar identidades Claude vs OpenCode e informar degradacion visible) no
  tenia dueno. #1054 CA-6 solo cubre drift dentro de un mismo runtime y #1066
  CA-3 solo exige que los logs carguen `version`/`commit`.
- **`src/published/scripts/` ya aloja maquinaria de empaquetado no renderizada
  a `dist/`** (`generate-published-adapters.sh`, `validate-published-artifacts.sh`),
  y `src/published/` ya esta en ambos gates de scope: un instalador ahi no
  necesita el PR previo de registro de MEF-ADR-0019.E.
- **El repo es publico** (`isPrivate: false`): la descarga del artefacto no
  requiere credenciales ni `gh` autenticado.
- **Los GitHub Releases actuales no llevan asset alguno** y no existe
  `.github/workflows/`; los publica la fase publish de
  `src/internal/scripts/mefisto-release.sh`. Los tests de #1053 no pueden
  depender de un release real.
- **`mefisto-validate-batch-deps.sh` ignora las referencias inversas**: solo
  parsea `Depende de` / `Bloqueado por` en el body del propio issue. Declarar
  "Bloquea #N" en el issue origen es invisible para la herramienta.

## Decisiones

1. **Particion de #1053 en cuatro** (fronteras de escritura disjuntas para que
   un fallo se atribuya sin ambiguedad):
   - #1053 acotado: almacen de releases inmutables, swap atomico de `active`,
     rollback, idempotencia y `status`. Cero escrituras fuera de la raiz de datos.
   - #1091: proyeccion de `active` a `<config>`, unico autorizado a escribir ahi.
   - #1092: diagnostico de deriva de identidad Claude/OpenCode.
   - #1093: poda opt-in de releases inactivos.
2. **Entrega del instalador embebido en el tarball verificado** (opcion b):
   bootstrap manual de 3 pasos la primera vez, self-upgrade verificado despues.
   Descartadas: instalador como segundo asset del release (`curl | sh` con pasos
   extra) e instalacion desde checkout (contradice el ADR).
3. **Punto de entrada** `<data>/mefisto/active/bin/mefisto-opencode <subcomando>`,
   sin symlink en `~/.local/bin`.
4. **#1091 enmienda MEF-ADR-0053 en su mismo PR**: elimina del cuerpo las tres
   frases que la verificacion vuelve falsas, deja el mecanismo verificado y la
   version minima, y registra el cambio en control de cambios. La evidencia
   reproducible va aparte en `docs/testing/`.
5. **Poda como no-goal declarado de #1053**, no como nota tecnica ambigua.

## Descartado

- Refinar #1053 como issue unico con la proyeccion adentro: dos componentes
  principales y muy por encima de los 30 minutos de una pasada.
- Symlink en `~/.local/bin` en #1053: tres casos borde nuevos (deteccion de
  PATH, colision de nombre, limpieza al desinstalar) por comodidad.
- Septimo CA de poda en #1053: habria roto el techo de 6 y es el criterio que
  menos comparte eje con los otros.
- Anadir alcance de Claude Code a #1053: Claude sigue por marketplace.

## Preguntas abiertas

- #1055 declara hoy sus dependencias solo hacia #1075 y #1052. Como el validador
  ignora las referencias inversas, hace falta anadir `Depende de #1091` en el
  body de #1055 para que el grafo sea correcto para la herramienta. Pendiente de
  autorizacion.
- #1052 CA-5 apunta a "el workflow de release", pero `.github/workflows/` no
  existe: hoy el release lo hace la fase publish de
  `src/internal/scripts/mefisto-release.sh`. Conviene revisarlo al refinar #1052.

## Referencias

Issues creados: #1091, #1092, #1093
Issue reescrito: #1053 (retitulado "Instalar y activar releases OpenCode en la
raiz de datos del usuario")
