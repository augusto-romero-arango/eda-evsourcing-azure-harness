---
fecha: 2026-10-04
hora: "18:33"
sesion: mefisto-planner
tema: horario CI y modelos OpenCode en main
---

## Contexto
Se consulto el horario del CI y que modelos usa OpenCode en main.

## Descubrimientos
El CI ya corre a las 03:00 de Colombia (cron 08:00 UTC). En pipelines OpenCode, fast usa openai/gpt-5.6-luna y balanced/deep usan openai/gpt-6-sol; las sesiones interactivas heredan el modelo del usuario.

## Decisiones
El usuario decidio dejar la configuracion actual sin cambios.

## Descartado
No crear issues ni modificar el workflow o los defaults ahora.

## Preguntas abiertas
Ninguna por ahora.

## Referencias
Issues creados: ninguno. Fuentes: .github/workflows/ci.yml, src/runtime/lib/runtime-opencode.sh, MEF-ADR-0049.
