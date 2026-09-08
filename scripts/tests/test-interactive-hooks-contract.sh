#!/usr/bin/env bash
# Expone el contrato publicado al barrido estándar de scripts/tests.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/../../src/published/scripts/tests/test-interactive-hooks-contract.sh"
