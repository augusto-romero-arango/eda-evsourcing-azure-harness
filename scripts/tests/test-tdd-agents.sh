#!/usr/bin/env bash
# Shim de compatibilidad: la suite publicada vive junto a su fuente neutral.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec bash "$SCRIPT_DIR/../../src/published/scripts/tests/test-tdd-agents.sh"
