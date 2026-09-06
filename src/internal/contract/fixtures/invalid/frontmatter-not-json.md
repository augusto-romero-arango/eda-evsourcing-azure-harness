---
kind: agent
id: frontmatter-not-json
description: YAML plano, no JSON -- el contrato exige un objeto JSON (MEF-ADR-0049 CA-6).
mode: subagent
---

Fixture de `fixtures/invalid/` (issue #853): debe rechazarse porque el bloque
entre los delimitadores no es JSON valido (YAML plano con `clave: valor`, no
un objeto `{...}`).
