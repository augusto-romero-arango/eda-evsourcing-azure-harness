#!/usr/bin/env bash
# Expone las pruebas de poda publicadas al barrido estándar.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec bash "$SCRIPT_DIR/../../src/published/scripts/tests/test-prune-opencode-releases.sh"
