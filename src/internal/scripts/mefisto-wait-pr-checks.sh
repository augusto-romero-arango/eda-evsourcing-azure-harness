#!/usr/bin/env bash
# mefisto-wait-pr-checks.sh <pr> -- CLI del helper mefisto_wait_pr_checks (issue #1744).
# Exit: 0 CI en verde | 1 CI rojo/cancelado | 2 check ausente o timeout.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/_mefisto-common.sh"
[ $# -eq 1 ] || { echo "Uso: mefisto-wait-pr-checks.sh <pr>" >&2; exit 2; }
mefisto_wait_pr_checks "$1"
