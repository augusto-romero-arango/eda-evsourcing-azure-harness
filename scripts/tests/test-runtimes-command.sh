#!/usr/bin/env bash
# Expone el contrato publicado de runtimes al barrido estándar de scripts/tests.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec bash "$SCRIPT_DIR/../../src/published/scripts/tests/test-runtimes-command.sh"
