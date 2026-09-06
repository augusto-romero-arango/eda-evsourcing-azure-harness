---
{
  "kind": "agent",
  "id": "mefisto-invalid-capability-value",
  "description": "Fixture invalido: declara una capacidad fuera del vocabulario cerrado (issue #853 CA-3).",
  "mode": "subagent",
  "capabilities": ["read", "bash"]
}
---

Fixture de `fixtures/invalid/` (issue #853): debe rechazarse por
`capabilities` con un valor fuera del vocabulario cerrado (`bash` es un
permiso de OpenCode, no una capacidad semantica del contrato).
