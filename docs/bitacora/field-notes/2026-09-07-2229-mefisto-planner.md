---
fecha: 2026-09-07
hora: 22:29
sesion: mefisto-planner
tema: Refinamiento del contrato de directivas del consumidor en AGENTS.md
---

## Contexto

Se reviso el issue #1051, que ya figuraba como `estado:listo`, para verificar su causa raiz, alcance y Definition of Ready frente al rollout publicado multi-runtime de MEF-ADR-0053.

## Descubrimientos

- La causa raiz esta vigente: `scripts/onboard-diagnose.sh`, `commands/onboard.md`, `README.md` y `.claude/skills/harness-config-contract/SKILL.md` siguen tratando `CLAUDE.md` como fuente de tokens y verificacion de fuentes.
- El alcance original mezclaba tres trabajos independientes: contrato/documentacion, diagnostico de solo lectura y provision opt-in.
- Una migracion automatica de todo `CLAUDE.md` no puede distinguir de forma segura doctrina neutral de directivas exclusivas de Claude Code.
- Para conservar una sola fuente canonica sin borrar contenido legacy, `/onboard` debe detectar tambien las dos secciones contractuales conocidas que permanezcan duplicadas en `CLAUDE.md`.

## Decisiones

- Se partio el alcance en tres issues pequenos: #1051 para el contrato, #1079 para el diagnostico y #1080 para la migracion opt-in.
- Solo `Tokens del harness` y `Verificacion de fuentes` son secciones obligatorias de `AGENTS.md`; las convenciones adicionales del proyecto quedan opcionales.
- El puente `CLAUDE.md` con una linea exacta `@AGENTS.md` se exige para que un consumidor nuevo quede utilizable por ambos adaptadores, incluso si hoy opera principalmente con OpenCode.
- La migracion sera conservadora: genera `AGENTS.md` desde el config canonico cuando esta ausente y agrega el import preservando contenido, pero no mueve ni elimina doctrina legacy automaticamente.
- #1051 deja de depender de #1049 y pierde el label `bloqueado`; #1079 y #1080 quedan bloqueados por sus dependencias abiertas.

## Descartado

- Mantener contrato, diagnostico y provision dentro de #1051.
- Mover todo `CLAUDE.md` a `AGENTS.md`, por el riesgo de trasladar directivas especificas de Claude.
- Extraer y borrar automaticamente secciones de `CLAUDE.md`; la limpieza de duplicados conocidos queda como accion manual visible.
- Introducir una tercera seccion obligatoria de convenciones del proyecto sin un contrato previo que defina su forma.

## Preguntas abiertas

Ninguna para el refinamiento. La implementacion de #1080 debera materializar el preflight y la preservacion de archivos definidos en sus criterios de aceptacion.

## Referencias

Issues creados: #1079, #1080

Issue refinado: #1051
