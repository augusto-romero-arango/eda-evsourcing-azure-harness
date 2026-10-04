#!/usr/bin/env bash
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/../../src/published/scripts/tests/test-agent-execution-contract.sh"
