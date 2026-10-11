---
fecha: 2026-10-11
hora: 14:18
sesion: mefisto-planner
tema: Mods de 0.46.2 rotos por doble registro, gate de claude plugin validate y affordance de clic en las cintas
---

## Contexto
Continuación de la sesión (notas previas en los PR #2278 y #2290). En 0.46.2, el consumidor dejó de ver `fausto-board` y `fausto-blood-pact`. Además, la cinta del release no tenía forma de cerrarse y la del pact se percibía clicable mientras las internas no.

## Descubrimientos
- El engine de mods rechaza el módulo entero si un evento se registra dos veces sin matcher. #2292 (cinta de merge del pact) añadió `prompt.submit` y `turn.complete`, que fausto-board ya registraba. El log solo muestra la primera colisión: `turn.complete` aparece solo después de quitar la primera (verificado en el sandbox).
- `on()` exige el nombre del evento como literal, así que no sirve una composición genérica que envuelva `on`.
- `claude plugin validate` detecta el defecto, corre sin autenticación y valida también cada mod y el marketplace de `.claude/mods`. Ningún gate lo corría.
- Todo `Button` de un mod es clicable por contrato del engine. La diferencia percibida con el pact está en el estilo `plain dimColor`, que se aviva bajo el puntero, y en que sus filas son `Button` y no `Text`.
- Las cintas de merge y bitácora ya se cerraban solas a los 8 s. La del release usaba 120 s y dependía solo de `$.clock.after`.

## Decisiones
- #2294: `hooks/index.tsx` es el único que registra `prompt.submit` y `turn.complete`. Cada mod exporta sus efectos como funciones, que corren primero board y después pact, cada uno con su `try/catch`.
- #2295: un workflow de PR por paths (`plugin-validate.yml`, ubuntu-24.04, instalador nativo, canal latest) que solo avisa. No es obligatorio y no toca el ruleset.
- #2289 (ya hecho en #2292): cinta de merge del consumidor con sondeo a GitHub cada 5 s.
- Cintas terminadas: cierre a los 15 s, con el vencimiento calculado al dibujar (brief de mods internos).
- Affordance de clic: aplicarla primero en los mods internos (brief) y después llevarla al consumidor como issue.

## Descartado
- Composición genérica de `on` en `index.tsx` (el engine la rechaza).
- Gate en `/mefisto-release` y check obligatorio con espera en el batch.

## Preguntas abiertas
- Publicar la 0.46.3 en cuanto se mergee #2294.
- Briefs de mods internos pendientes: sobrevivir a `/clear`, cierre a 15 s de las cintas y affordance de clic.

## Referencias
Issues: #2289 (cerrado vía #2292), #2294 (estado:listo, bug), #2295 (estado:listo).
