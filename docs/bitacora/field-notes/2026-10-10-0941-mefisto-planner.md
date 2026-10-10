---
fecha: 2026-10-10
hora: 09:41
sesion: mefisto-planner
tema: Cintas de merge/bitacora/release, sitio mefisto.io, version bajo la mascota y fausto-blood-pact tras /clear
---

## Contexto
Sesion de exploracion sobre las bandas ("cintas") de los mods: nuevas cintas en `mefisto-divine-wager` para `/mefisto-merge`, `/mefisto-bitacora` y `/mefisto-release`, mas ajustes del lado publicado (version visible, bug de `/clear` en `fausto-blood-pact`) y el enlace al sitio comercial.

## Descubrimientos
- "Cinta" = la banda sobre el prompt de los mods (render site `AbovePrompt`).
- Colapsar la banda es nativo de Claude Code: `abovePrompt:toggle` (Ctrl+X Ctrl+A), sobre toda la franja compartida; ocultar solo un mod requiere un `on/off` propio.
- `mefisto-release.sh` consolida todos los fragmentos de `changelog.d/` de una vez: la cinta del release avanza por fases, no por fragmento.
- Causa raiz del bug de `/clear` en `fausto-blood-pact` (reproducida via Herdr con `claude --debug`): el `ui.render` llamaba `activate` (escribe `$.state`) y el engine lo rechaza con `state.set: denied ... drawing is pure`; ademas, al arrancar, el primer render llega antes de que termine `session.start`, sale sin leer atoms y queda sin suscripcion. La reactivacion correcta tras `/clear` es `classic.SessionStart` con `source: clear|resume|fork` (doc oficial de mods).
- El `mefisto-planner-board` interno usa el mismo patron (escribe en el render tras #2176): probablemente tiene el mismo error.

## Decisiones
- Mascota del merge: diablito cosiendo ramas. Bitacora: reutiliza al historiador.
- `/mefisto-bitacora` deja de encadenar el merge; reporta y sugiere `/mefisto-merge`/`gh pr close`. La invitacion interactiva vive en la cinta.
- Las cintas de mods internos van por briefs a sesiones de trabajo directo (sin issues); los cambios del lado publicado (`hooks/`) van por issue.
- README enlaza `https://mefisto.io` (badge + linea), no el repo `mefisto-site`.
- Version bajo la mascota: `mefisto-manifest.json` con fallback a `plugin.json`.

## Descartado
- Mantener el auto-merge de `/mefisto-bitacora`, o anadirle `--no-merge`.
- Preguntar desde el skill de bitacora (duplicaria la invitacion de la cinta).

## Preguntas abiertas
- Aplicar el arreglo de render sin escrituras a `mefisto-planner-board` (trabajo directo de mods).
- La homepage del repo (`gh repo edit --homepage https://mefisto.io`) queda a mano del usuario.
- `mefisto-next-order.sh` tarda en ver issues recien pasados a `estado:listo` (probable latencia del indice de busqueda de GitHub).

## Referencias
Issues creados: #2260 (cerrado), #2267 (cerrado), #2274 (cerrado), #2277 (estado:listo, bug).
Briefs entregados: cinta-merge, cinta-bitacora, cinta-release.
