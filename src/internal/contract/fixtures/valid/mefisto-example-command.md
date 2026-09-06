---
{
  "kind": "command",
  "id": "mefisto-example-command",
  "description": "Comando de ejemplo para validar el contrato neutral de comandos (issue #853). No se invoca en produccion.",
  "profile": "fast",
  "capabilities": ["read", "shell"],
  "agent": "mefisto-example-agent",
  "arguments": "<issue> -- numero del issue a procesar"
}
---

Cuerpo de ejemplo de un comando neutral. Procesa el issue $ARGUMENTS
invocando al agente declarado en el campo `agent` del frontmatter.
`$ARGUMENTS` es el unico placeholder neutral de argumentos (CA-1).

Fixture de `fixtures/valid/` (issue #853).
