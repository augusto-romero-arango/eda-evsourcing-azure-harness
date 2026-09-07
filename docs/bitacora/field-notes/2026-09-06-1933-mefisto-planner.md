---
fecha: 2026-09-06
hora: 19:33
sesion: mefisto-planner
tema: principio de neutralidad de runtime (MEF-ADR-0050) y herramienta next-order en ambos lados
---

## Contexto

Claude Insights recomendo al mantenedor crear un Skill `.claude/skills/next-order/SKILL.md` que ordene topologicamente los issues `estado:listo` a partir de `## Dependencias`. El mantenedor pidio que fuera util tanto en Claude Code como en OpenCode, y aprovecho para fijar como doctrina que **toda operacion de Mefisto sea agnostica al runtime**, con el conjunto de runtimes abierto a futuro. Pidio ademas investigar en que otros lugares (ademas del ADR) debe vivir esa doctrina.

## Descubrimientos

- **`orden-de-batch` ya existe pero es manual**: `mefisto-validate-batch-deps.sh` valida un orden dado, no lo calcula ni detecta ciclos. El parsing de `## Dependencias` (`awk` de seccion + `grep` de `Depende de|Bloqueado por`) es canonico y reutilizable.
- **Un Skill no es la primitiva agnostica para una accion invocable**: en OpenCode los Skills se cargan via la tool `skill`, no como slash commands (https://opencode.ai/docs/skills/). La primitiva neutral de este repo para `/mefisto-*` es el **comando** de `src/internal/commands/` generado a ambos adaptadores.
- **Frontmatter portable de SKILL.md**: la spec abierta (https://agentskills.io/specification) define seis campos (`name`, `description`, `license`, `compatibility`, `metadata`, `allowed-tools` experimental); OpenCode reconoce cinco e ignora el resto en silencio; Claude Code documenta cuales son estandar y cuales extension propia (https://code.claude.com/docs/en/skills#using-skill-frontmatter-outside-claude-code). Los 4 Skills del repo hoy usan solo `name`+`description`.
- **Claude Code no lee `.agents/skills/`** (solo `.claude/skills/` y plugin `skills/`); OpenCode si lee `.claude/skills/`. Por eso `.claude/skills/` sigue siendo el unico archivo fisico compartido.
- **`mefisto-writer` y `mefisto-reviewer` tienen 0 menciones de neutralidad**; el gate (#923) los frena post-hoc. `AGENTS.md` es el vehiculo que ambos runtimes cargan.
- **Namespace en OpenCode (verificado empiricamente, 1.18.29, proyecto temporal + `opencode run --command`)**: no existe namespace de plugin (los "plugins" son modulos JS/TS de hooks). Pero un comando llamado `mefisto:x` se registra e invoca correctamente, tanto desde archivo `.opencode/commands/mefisto:x.md` como desde clave `command` en `opencode.json`; `mefisto/x` tambien funciona via subcarpeta (Claude Code ignora la subcarpeta en el nombre: semantica divergente). Tolerancia de `:` **no documentada**. Un Skill `mefisto:g` cargo, pero viola la regex de la spec.
- **Lugares donde vive la doctrina de neutralidad** (ademas de `docs/adr/`): `AGENTS.md` (directivas canonicas), `.claude/skills/agent-skill-authoring/SKILL.md` (how-to de autores, hoy Claude-centrico), `src/internal/contract/README.md` (contrato + tabla de mapeo por runtime), `mefisto-neutrality-gate.sh` + `neutrality-allowlist.json` (doctrina ejecutable R1-R4), `scripts/tests/test-guards.sh` bloque `[F]` (Skills), y `changelog.d/<issue>.adr-index.md` para el indice tematico.

## Decisiones

1. **ADR nuevo, MEF-ADR-0050**, no enmienda de 0049: 0049 es arquitectura del rollout interno; el principio general sobrevive mejor separado y a #874.
2. **Alcance (a)**: vinculante para toda operacion, ambos lados; **no-regresion** en el publicado mientras siga siendo Claude Code Plugin.
3. **Namespace `mefisto` con separador `:`** en runtimes sin plugin (`/mefisto:sequential` identico en ambos), preservando `mefisto:`=publicado / `mefisto-`=interno; Skills con `mefisto-` por spec. Descartado `-` (dos grafias, colision nominal con internos) y `/` (semantica divergente entre runtimes).
4. **`allowed-tools` prohibido** en todo SKILL.md (degrada en silencio en OpenCode).
5. **next-order = script canonico + wrapper por runtime**; el script publicado recibe `--launch-command` porque la linea final depende del runtime; el interno imprime siempre `/mefisto-sequential`. Ambos cierran **siempre** con la linea de lanzamiento.
6. **Ambos lados** (interno y publicado), duplicacion aceptada por MEF-ADR-0019/0018.

## Descartado

- Skill `.claude/skills/next-order/` tal como lo propuso Insights (sin prefijo `mefisto-`, no invocable en OpenCode, frontmatter no portable).
- Enmendar MEF-ADR-0049 en vez de crear 0050.
- Separadores `-`, `/`, `|`, `>` para el namespace en OpenCode.
- Migrar `.claude/skills/` a fuente generada (ambos runtimes leen el mismo archivo; no hay divergencia que generar).
- Test sentinela hoy para la tolerancia de `:` en OpenCode: solo tiene sentido cuando #874 cree el adaptador publicado; anotado en #935 CA-4.

## Preguntas abiertas

- Al materializar #874, como renombrar los Skills publicados para OpenCode (`skills/projections/` -> `mefisto-projections`, `name` incluido) sin romper el `/mefisto:projections` de Claude Code: decision del adaptador, pendiente.
- Si una version futura de OpenCode valida el charset de los nombres de comando y rechaza `:`, el fallback documentado seria `-`; 0050 debe decirlo o dejarlo a #874.
- Extraer el parsing de `## Dependencias` a `_mefisto-common.sh` cuando aparezca el tercer consumidor (hoy: validador + next-order interno).

## Referencias

Issues creados: #935 (MEF-ADR-0050), #936 (script interno `mefisto-next-order.sh`), #937 (regla F5 en `test-guards.sh`, bloqueado por #935), #938 (reescritura neutral de `agent-skill-authoring`, bloqueado por #935), #939 (comando neutral `mefisto-next-order` + planner, bloqueado por #936), #940 (script publicado `scripts/next-order.sh`, bloqueado por #936), #941 (comando publicado `next-order`, bloqueado por #940).

Orden de batch sugerido: 935 936 937 938 939 940 941 (o 936 antes de 935: son independientes).
