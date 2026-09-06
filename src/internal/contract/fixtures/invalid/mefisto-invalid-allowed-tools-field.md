---
{
  "kind": "command",
  "id": "mefisto-invalid-allowed-tools-field",
  "description": "Fixture invalido: declara 'allowed-tools', variante de permisos de Claude Code prohibida en la fuente neutral.",
  "allowed-tools": ["Bash(git *)"]
}
---

Fixture de `fixtures/invalid/` (issue #853): debe rechazarse por
`allowed-tools` como propiedad adicional no declarada en el schema.
