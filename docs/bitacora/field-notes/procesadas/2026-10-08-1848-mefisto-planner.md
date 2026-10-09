---
fecha: 2026-10-08
hora: 18:48
sesion: mefisto-planner
tema: Refinar #2080, #2081 y #2083; cerrar #1746
---

## Contexto
Completar el refinamiento de la cadena del tablero del planner publicado (#2079-#2083).

## Descubrimientos
- La decision 4 de MEF-ADR-0055 decia "No se edita el `hooks/hooks.json` publicado": choca con el tablero publicado.
- `generate-claude-hooks.sh` exige claves de primer nivel exactamente `["hooks"]`; hoy rechaza `modules`.
- El marketplace Claude publica la raiz del repo (`source: "./"`): los modulos de `hooks/` viajan sin tocar el empaquetado.
- El gate de neutralidad (R2) rechaza `claude --agent`; el tablero publicado lo necesita para activarse.

## Decisiones
- #2080 -> listo: generalizar las decisiones 4 y 8 de MEF-ADR-0055 a ambos lados en vez de una decision 9.
- Los tableros interno y publicado son **totalmente independientes**: sin codigo compartido, sin obligacion de sincronizarlos, sin cabeceras de copia hermana; el interno solo es punto de partida del port. #2082 corregido en consecuencia.
- #2081 -> listo: `modules` desde el generador mas un `hooks/register.tsx` sin efecto que #2082 reemplaza; registra tambien la excepcion R2 para `hooks/*.ts`/`*.tsx` antes de poblarlos.
- #2083 -> listo: fila de version de Claude Code en `onboard-diagnose.sh` (FALTA si < 2.1.287, informativa bajo otro runtime) y nota en el README.
- #1746 cerrado not planned por decision del usuario.

## Descartado
- Decision 9 separada en MEF-ADR-0055.
- Emitir `modules` condicionado a que exista `hooks/register.tsx`, o fusionar #2081 con #2082.

## Preguntas abiertas
- `.github/rulesets/main.json` sigue en `main` sin aplicarse tras cerrar #1746.

## Referencias
Issues refinados: #2080, #2081, #2083 (y ajuste de #2082). Cerrado: #1746. Orden: `/mefisto-sequential 2080 2081 2082 2083`.
