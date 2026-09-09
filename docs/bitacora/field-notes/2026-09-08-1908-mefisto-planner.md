---
fecha: 2026-09-08
hora: 19:08
sesion: mefisto-planner
tema: Empaquetado de Agent Skills publicados para OpenCode
---

## Contexto

Se refino #1055, uno de los dos drafts sin dependencia abierta que bloqueaban la certificacion multi-runtime. El body original mezclaba el arbol fisico de Skills con la traduccion semantica de referencias `skills` de agentes/comandos.

## Descubrimientos

- OpenCode v1.18.29 descubre Skills globales bajo `~/.config/opencode/skills/<name>/SKILL.md`, exige que `name` coincida con el directorio y los carga bajo demanda mediante la tool `skill`.
- Mefisto publica hoy `projections` (cuatro recursos Nivel 3) y `comment-cleanup` (`ejemplos.md`). El prefijo `mefisto-` solo pertenece al adaptador OpenCode, conforme a MEF-ADR-0050.
- #1104 ya aporta `assets`/`render-asset`, inventario SHA-256, deteccion de huerfanos y publicacion atomica. El adaptador OpenCode implementa la operacion, pero devuelve un inventario vacio.
- #1052 ya empaqueta toda `dist/opencode/` y #1091 ya proyecta recursivamente `skills/**`; no hace falta modificar packager, instalador ni proyector para materializar los Skills.
- El adaptador sigue rechazando cualquier campo neutral `skills`; esa semantica es distinta del copiado del arbol y merece un corte propio.

## Decisiones

- #1055 queda concentrado en enumerar, transformar y proyectar los arboles nativos `skills/mefisto-<id>/**` mediante el protocolo de #1104.
- Solo cambia `name:` en el frontmatter de `SKILL.md`; description, body y campos portables se conservan, y los recursos Nivel 3 se copian byte a byte.
- La enumeracion cubre Skills presentes y futuros sin hardcodear los dos ids actuales; nombre, limites OpenCode, links, colisiones y symlinks fallan antes de publicar.
- #1055 pasa a `estado:listo` sin `bloqueado`, porque #1075/#1052/#1091/#1104 estan cerrados.
- Se crea #1139 para traducir ids neutrales a `mefisto-<id>`, carga nativa y `permission.skill`; depende de #1055 y queda listo/bloqueado.
- #1066 declara explicitamente la nueva dependencia #1139.

## Descartado

- Mantener empaquetado y referencias en #1055: excedia una sola pasada y mezclaba componente Skill con semantica del agente generado.
- Modificar el packager o el proyector: ambos ya operan sobre el arbol completo y soportan `skills/**`.
- Copiar `.claude/skills/**` internos o renombrar la fuente publicada.
- Hardcodear `projections` y `comment-cleanup`; impediria que un Skill futuro converja automaticamente.

## Preguntas abiertas

- #1139 debe fijar la degradacion visible de permisos para comandos, dado que OpenCode aplica `permission.skill` al agente ejecutor y no al comando.
- La invocacion real de la tool `skill` desde una instalacion global queda como smoke de #1066; #1055 verifica estructura, instalacion y proyeccion de forma determinista.

## Referencias

Issues creados: #1139 `Traducir referencias de Agent Skills en el adaptador OpenCode`.

Drafts refinados: #1055 `Empaquetar Agent Skills publicados para OpenCode`.

Issues ajustados: #1066 (dependencia de #1139).

Fuentes: MEF-ADR-0019/0033/0050/0053; [OpenCode v1.18.29 - Agent Skills](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/web/src/content/docs/skills.mdx); PR #1138 / issue #1104.
