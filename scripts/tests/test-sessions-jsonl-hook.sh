#!/usr/bin/env bash
# Compatibilidad del gate historico de sessions.jsonl con el contrato vigente.
# La prueba canonica cubre inicio, identidad de distribucion y observaciones Stop.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/../../src/published/scripts/tests/test-generate-claude-hooks.sh"
