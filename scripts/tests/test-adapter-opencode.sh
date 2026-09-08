#!/usr/bin/env bash
# Entrada de la suite publicada para el test canonico bajo src/published/.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec bash "$SCRIPT_DIR/../../src/published/scripts/tests/test-adapter-opencode.sh"
