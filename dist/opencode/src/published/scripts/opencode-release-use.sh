#!/usr/bin/env bash
# API JSON de referencias de uso de releases OpenCode.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [ -f "$HERE/lib/release-use-process.sh" ]; then
  source "$HERE/lib/release-use-process.sh"
  source "$HERE/adapters/lib/opencode-release-use.sh"
else
  source "$HERE/src/published/scripts/lib/release-use-process.sh"
  source "$HERE/src/published/scripts/adapters/lib/opencode-release-use.sh"
fi
usage() { printf '%s\n' 'uso: release-use.sh <inspect|acquire|reserve|attach|finish|reconcile> --data-root <raiz-absoluta>' >&2; exit 2; }
[ "$#" -ge 3 ] || usage
OP="$1"; shift
[ "${1:-}" = --data-root ] && [ "$#" -eq 2 ] || usage
ROOT="$2"; case "$ROOT" in /*) ;; *) usage;; esac
REQUEST="$(command cat)" || exit 2
jq -e --arg op "$OP" '.operation==$op' >/dev/null 2>&1 <<<"$REQUEST" || usage
if [ "$OP" = inspect ]; then
  release_use_validate_root "$ROOT" || { release_use_response conflict "$(release_use_empty)" '' '[{"code":"STORE_UNAVAILABLE"}]'; exit 1; }
  REGISTRY="$(release_use_read "$ROOT")" || { release_use_response conflict "$(release_use_empty)" '' '[{"code":"REGISTRY_INVALID"}]'; exit 1; }
  release_use_response ok "$REGISTRY"; exit 0
fi
release_use_validate_root "$ROOT" || { release_use_response conflict "$(release_use_empty)" '' '[{"code":"STORE_UNAVAILABLE"}]'; exit 1; }
(
  LOCK="$ROOT/releases/.operation.lock"; TOKEN="$$-${RANDOM}-${RANDOM}"; acquired=false
  cleanup() { if [ "$acquired" = true ] && [ -f "$LOCK/owner" ] && [ "$(command cat "$LOCK/owner" 2>/dev/null)" = "$TOKEN" ]; then rm -rf "$LOCK"; fi; }
  trap cleanup EXIT HUP INT TERM
  deadline=$((SECONDS + 5))
  until mkdir "$LOCK" 2>/dev/null; do [ "$SECONDS" -lt "$deadline" ] || { release_use_response busy "$(release_use_empty)" '' '[{"code":"LOCK_BUSY"}]'; exit 75; }; sleep 1; done
  acquired=true; printf '%s\n' "$TOKEN" > "$LOCK/owner" && printf '%s\n' release-use > "$LOCK/operation" && printf '%s\n' "$$" > "$LOCK/pid" || exit 1
  RELEASE_USE_LOCK_TOKEN="$TOKEN" opencode_release_use_locked "$ROOT" "$REQUEST"
)
