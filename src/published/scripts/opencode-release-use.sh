#!/usr/bin/env bash
# API JSON de referencias de uso de releases OpenCode.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [ -f "$HERE/lib/release-use-process.sh" ] && [ ! -L "$HERE/lib/release-use-process.sh" ]; then
  source "$HERE/lib/release-use-process.sh"
  source "$HERE/adapters/lib/opencode-release-use.sh"
else
  source "$HERE/src/published/scripts/lib/release-use-process.sh"
  source "$HERE/src/published/scripts/adapters/lib/opencode-release-use.sh"
fi
usage() { printf '%s\n' 'uso: release-use.sh <inspect|acquire|reserve|attach|finish|reconcile> --data-root <raiz-absoluta>' >&2; exit 2; }
[ "$#" -eq 3 ] || usage
OP="$1"; shift
case "$OP" in inspect|acquire|reserve|attach|finish|reconcile) ;; *) usage;; esac
[ "${1:-}" = --data-root ] && [ "$#" -eq 2 ] || usage
ROOT="$2"; case "$ROOT" in /*) ;; *) usage;; esac
REQUEST="$(command cat)" || exit 2
release_use_request_valid "$REQUEST" && jq -e --arg op "$OP" '.operation==$op' >/dev/null 2>&1 <<<"$REQUEST" || usage
if [ "$OP" = inspect ]; then
  jq -e '(.id==null or (.id|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))) and
    (.release==null or (.release|type=="object" and (keys|sort)==["commit","root","version"] and (.root|type=="string") and (.version|type=="string") and (.commit|type=="string")))' >/dev/null <<<"$REQUEST" || usage
  release_use_validate_root "$ROOT" || { release_use_response conflict "$(release_use_empty)" '' '[{"code":"STORE_UNAVAILABLE"}]'; exit 1; }
  REGISTRY="$(release_use_read "$ROOT")" || { release_use_response conflict "$(release_use_empty)" '' '[{"code":"REGISTRY_INVALID"}]'; exit 1; }
  FILTERED="$(release_use_filter "$REGISTRY" "$REQUEST")" || usage
  release_use_response ok "$FILTERED"; exit 0
fi
release_use_validate_root "$ROOT" || { release_use_response conflict "$(release_use_empty)" '' '[{"code":"STORE_UNAVAILABLE"}]'; exit 1; }
(
  LOCK="$ROOT/releases/.operation.lock"; TOKEN="$$-${RANDOM}-${RANDOM}"; acquired=false
  cleanup() {
    if [ "$acquired" = true ] && [ -f "$LOCK/owner" ] && [ ! -L "$LOCK/owner" ] && [ "$(command cat "$LOCK/owner" 2>/dev/null)" = "$TOKEN" ]; then
      rm -f "$LOCK/owner" "$LOCK/operation" "$LOCK/pid" 2>/dev/null || true
      rmdir "$LOCK" 2>/dev/null || true
    elif [ "$acquired" = true ] && [ ! -e "$LOCK/owner" ] && [ ! -L "$LOCK/owner" ]; then
      rm -f "$LOCK/operation" "$LOCK/pid" 2>/dev/null || true
      rmdir "$LOCK" 2>/dev/null || true
    fi
  }
  trap cleanup EXIT
  trap 'exit 1' HUP INT TERM
  deadline=$((SECONDS + 5))
  until (umask 077; mkdir "$LOCK") 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      REGISTRY="$(release_use_read "$ROOT" 2>/dev/null)" || REGISTRY="$(release_use_empty)"
      release_use_response busy "$REGISTRY" '' '[{"code":"LOCK_BUSY","recovery":"inspect-owner-and-remove-manually-only-after-verification"}]'; exit 75
    fi
    sleep 1
  done
  acquired=true
  if ! (umask 077; printf '%s\n' "$TOKEN" > "$LOCK/owner" && printf '%s\n' release-use > "$LOCK/operation" && printf '%s\n' "$$" > "$LOCK/pid"); then exit 1; fi
  RELEASE_USE_LOCK_TOKEN="$TOKEN" opencode_release_use_locked "$ROOT" "$REQUEST"
)
