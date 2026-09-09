#!/usr/bin/env bash
# Entrada estable para la prueba publicada del plugin OpenCode generado.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec bash "$SCRIPT_DIR/../../src/published/scripts/tests/test-opencode-observability.sh"
