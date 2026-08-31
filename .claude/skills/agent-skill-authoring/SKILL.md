---
name: agent-skill-authoring
description: Notas operativas para definir o modificar agentes (agents/*.md, .claude/agents/*.md) y Agent Skills (skills/<nombre>/SKILL.md, .claude/skills/<nombre>/SKILL.md) del propio plugin Mefisto -- declaracion de tools MCP en allowlists, prefijo scoped de tools MCP provistas por plugins, y cuando envolver doctrina extensa en un Agent Skill en vez de crecer el body de un agente. Usar al crear o editar un agente o un skill de este repo.
---

# Notas para definir agentes y skills

- Las herramientas MCP requieren declaración explícita cuando un agente usa allowlist `tools:`. Usa wildcard: `mcp__<servidor>__*`.
- Cuando el servidor MCP lo provee un **plugin** (declarado en `.mcp.json` en la raíz del plugin, propio o de terceros), el nombre real de sus tools va scoped con el prefijo del plugin, así que la allowlist se escribe `mcp__plugin_<plugin>_<servidor>__*`, no `mcp__<servidor>__*`. Fuente: [code.claude.com/docs/en/plugins-reference](https://code.claude.com/docs/en/plugins-reference) — *"Tool matchers and `if` fields take the scoped tool name `mcp__plugin_<plugin-name>_<server-name>__<tool>` … A matcher written against the bare server key never fires"*. Ejemplo: el servidor `microsoft-learn` bundleado por este plugin (`mefisto`) se declara en `.mcp.json` y se referencia en `tools:` como `mcp__plugin_mefisto_microsoft-learn__*`.
- Si el agente **no** define `tools:`, hereda todas incluyendo MCP.
- Para **doctrina extensa** que solo aplica a algunas tareas, usa un **Agent Skill** (`skills/<nombre>/SKILL.md` publicado, `.claude/skills/<nombre>/SKILL.md` interno) en vez de otra sección en el body del agente: el Skill se carga por niveles y no se paga cuando la tarea no lo necesita. Un agente lo precarga con el campo frontmatter `skills:` (no requiere la tool `Skill` en `tools:`). Doctrina completa y caveats de versión en MEF-ADR-0033.
