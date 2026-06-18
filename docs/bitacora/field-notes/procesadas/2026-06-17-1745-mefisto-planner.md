---
fecha: 2026-06-17
hora: 17:45
sesion: mefisto-planner
tema: Refinamiento de los issues #36, #37 y #38 a estado:listo
---

## Contexto

Tres drafts/issues sin refinar acumulados tras el release v0.3.0 y tras una sesion de
`/mefisto:fix-review 165` en el consumidor `Bitakora.ControlAsistencia`. Se pidio llevarlos
a `estado:listo`. Causa raiz verificada en el repo del harness antes de cerrar el refinamiento.

## Descubrimientos

- `mefisto-release.sh` aborta la fase *prepare* si `[Unreleased]` esta vacio (~L302) y ya
  expone un parser reutilizable del bloque: `extract_unreleased_section` (regex
  `(?ms)^##\s*\[Unreleased\]...`). Buen punto de apoyo para el check del #36.
- El `mefisto-fix-review.md` **interno** ya esta adaptado al modelo plugin (sus mejoras van
  a `agents/` publicados o `.claude/agents/` internos del propio repo). Solo el `fix-review`
  **publicado** arrastra la suposicion obsoleta -> el #38 se acota a `commands/fix-review.md`.
- `implementer.md` y `reviewer.md` ya hospedan microconvenciones de estilo C# que NO viven en
  ADRs (numeros magicos, cast inline). "Condiciones en positivo" (#37) encaja al mismo nivel:
  agente, no ADR. En el reviewer cae bajo el lente *Legible* de su "Objetivo de elegancia".
- ADR-0019 es el ancla del #38 (routing cross-repo: solo drafts).

## Decisiones

- **#36** (pipeline interno): se implementa como **warning informativo**, no gate duro
  (decision del usuario). Deteccion = contenido nuevo bajo `## [Unreleased]`, no solo tocar
  el archivo. Alcance solo interno (no se replica en `/tooling` publicado).
- **#37** (agentes publicados): regla en `implementer.md` + verificacion en `reviewer.md`.
  Sin ADR. Homogeneo (misma regla en 2 archivos) -> pasa revision de complejidad.
- **#38** (skill publicado): renombrado a verbo-infinitivo y marcado `bug`. Reescribir Fase 5.4
  para enrutar mejoras de agentes del harness a un draft via `gh -R`, reservando edicion
  en-rama a lo que vive en el consumidor. La "pasada general de rutas" queda como nota
  (issue separado sugerido, no creado).

## Descartado

- Gate duro en #36 (friccionaria docs/refactors; Keep a Changelog: no todo es "notable").
- ADR nuevo para #37 (es microconvencion de estilo, no decision arquitectonica).
- Crear ya el issue de auditoria general de rutas relativas al consumidor (`/parallel` ->
  `./scripts/tmux-pipeline.sh`, etc.): pendiente de confirmacion del usuario.

## Preguntas abiertas

- ¿Se crea el issue separado de auditoria de rutas relativas al consumidor en skills publicados?

## Referencias

Issues refinados a estado:listo: #36 (tipo:tooling), #37 (tipo:tooling), #38 (tipo:tooling + bug).
