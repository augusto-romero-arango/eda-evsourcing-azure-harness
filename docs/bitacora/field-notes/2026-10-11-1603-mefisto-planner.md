---
fecha: 2026-10-11
hora: 16:03
sesion: mefisto-planner
tema: Paridad de fausto-blood-pact con la cinta interna (rearme tras /clear, merge, bitácora, cabecera y pie)
---

## Contexto
Continuación de la sesión (notas previas en los PR #2278, #2290 y #2301). La meta fue dejar la banda del consumidor (`fausto-blood-pact`) con el mismo vocabulario, la misma disposición y las mismas capacidades que la cinta interna (`mefisto-divine-wager`).

## Descubrimientos
- El plugin publicado carga en tier `user`. En ese tier, `cc-plugin-sec-default` salta todos los `classic.*` (debug log del consumidor y PR #2299). Por eso eran código muerto `classic.SessionStart` (#2277) y `classic.UserPromptSubmit`/`classic.Stop` (#2296).
- Dos mods pueden registrar `tool.call` con el mismo matcher, `{ tool: 'Bash' }`: solo se rechaza un segundo registro sin matcher.
- El menú `PRs` del consumidor no aparecía porque los 9 PRs abiertos de Bitakora eran de field notes, y tanto el pact como la cinta interna los filtran.
- Tras cada release, el consumidor ve los cambios recién después de `/mefisto:upgrade`. La versión bajo la mascota sirve para diagnosticarlo.
- `Button` con `plain` + `hotkey` ya dibuja `N:`: poner la tecla en la etiqueta la duplica.

## Decisiones
- Rearme tras `/clear` con un vigilante de 1 s en ambos mods publicados (#2300).
- La cinta de merge se sigue con el `tool.call` de `pr-sync.sh --merge` (#2302).
- Primero se incluyeron los PRs de field notes en `PRs` con `--all` (#2306). Después, con la bitácora, esos PRs volvieron a `bitácora N`, como en el interno (#2312).
- Cabecera `mefisto` (rojo) ` · listos N` a todo el ancho, con `2: PRs` y `3: bitácora` arriba a la derecha (#2311, #2316).
- Pie: `1: sequential N · 4: parallel M`, sin `5-9 uno` ni `bloqueados`; `ocultar` en reposo queda solo con clic (#2316).
- `1` y `4` escriben el comando en el prompt y nunca lo envían (MEF-ADR-0055, decisión 2).

## Descartado
- Usar la letra `p` para parallel y dejar las teclas del pie como estaban.
- Cambiar `/mefisto:bitacora` para que no encadene el merge: la cinta cubre los dos desenlaces.

## Preguntas abiertas
- Mergear y publicar #2316, y luego correr `/mefisto:upgrade` en los consumidores.
- Briefs de mods internos pendientes: cierre a 15 s de las cintas y affordance de clic (`plain dimColor`, filas clicables).

## Referencias
Issues: #2300, #2302, #2306, #2307, #2311, #2312 (cerrados), #2316 (estado:listo).
