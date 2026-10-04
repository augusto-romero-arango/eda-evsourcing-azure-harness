#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
CLI="$REPO_ROOT/src/published/scripts/opencode-release-use.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }
ROOT="$WORK/data con espacios"; RELEASE="$ROOT/releases/1.2.3"; mkdir -p "$RELEASE"
jq -n '{schemaVersion:1,runtime:"opencode",version:"1.2.3",commit:"0123456789abcdef0123456789abcdef01234567",minimumRuntimeVersion:"1"}' > "$RELEASE/mefisto-manifest.json"
RELEASE="$(cd "$RELEASE" && pwd -P)"
identity() { jq -cn --arg root "$RELEASE" '{root:$root,version:"1.2.3",commit:"0123456789abcdef0123456789abcdef01234567"}'; }
request() { jq -cn --arg op "$1" --arg id "${2:-}" --argjson revision "${3:-0}" --argjson release "$(identity)" --argjson pid "$$" '{schemaVersion:1,requestId:("r-"+$op+$id),operation:$op,expectedRevision:$revision,id:$id,kind:"retain",release:$release,ownerPid:$pid,runId:"run",projectId:"project"}'; }
INSPECT="$(jq -cn '{schemaVersion:1,requestId:"inspect",operation:"inspect"}')"
OUT="$(printf '%s' "$INSPECT" | bash "$CLI" inspect --data-root "$ROOT")"; RC=$?
[ "$RC" -eq 0 ] && jq -e '.status=="ok" and .revision==0 and .leases==[]' >/dev/null <<<"$OUT" && [ ! -e "$ROOT/runtime-use" ] && pass 'inspect ausente no crea el registro' || fail 'inspect tuvo efectos o respuesta invalida'
OUT="$(request acquire lease-a 0 | bash "$CLI" acquire --data-root "$ROOT")"; RC=$?
[ "$RC" -eq 0 ] && jq -e '.status=="ok" and .revision==1 and .leaseId=="lease-a" and .leases[0].phase=="active"' >/dev/null <<<"$OUT" && [ "$(stat -f '%Lp' "$ROOT/runtime-use/v1/registry.json" 2>/dev/null || stat -c '%a' "$ROOT/runtime-use/v1/registry.json")" = 600 ] && pass 'acquire persiste una referencia con permisos privados' || fail 'acquire no persistio correctamente'
OUT="$(request acquire lease-a 1 | bash "$CLI" acquire --data-root "$ROOT")"; RC=$?
[ "$RC" -eq 0 ] && jq -e '.revision==1' >/dev/null <<<"$OUT" && pass 'reintento identico es idempotente' || fail 'reintento identico no fue idempotente'
OUT="$(request acquire lease-a 1 | jq '.kind="execute"' | bash "$CLI" acquire --data-root "$ROOT")"; RC=$?
[ "$RC" -eq 1 ] && jq -e '.status=="conflict" and any(.diagnostics[];.code=="ID_REUSED")' >/dev/null <<<"$OUT" && pass 'id reutilizado con payload distinto es conflicto' || fail 'id reutilizado fue aceptado'
OUT="$(request acquire lease-b 0 | bash "$CLI" acquire --data-root "$ROOT")"; RC=$?
[ "$RC" -eq 1 ] && jq -e '.status=="conflict"' >/dev/null <<<"$OUT" && pass 'revision desactualizada no escribe' || fail 'conflicto de revision no detectado'
RESERVE="$(jq -cn --argjson release "$(identity)" '{schemaVersion:1,requestId:"reserve",operation:"reserve",expectedRevision:1,id:"child",kind:"retain",release:$release,parentId:"lease-a",runId:"run",projectId:"project"}')"
OUT="$(printf '%s' "$RESERVE" | bash "$CLI" reserve --data-root "$ROOT")"; RC=$?
[ "$RC" -eq 0 ] && jq -e '.revision==2 and (.leases[]|select(.id=="child").phase)=="reserved"' >/dev/null <<<"$OUT" && pass 'reserva hijo antes de lanzamiento' || fail 'reserva invalida'
FINISH="$(jq -cn '{schemaVersion:1,requestId:"finish",operation:"finish",expectedRevision:2,id:"child"}')"
printf '%s' "$FINISH" | bash "$CLI" finish --data-root "$ROOT" >/dev/null; RC=$?
LATE="$(jq -cn --argjson release "$(identity)" '{schemaVersion:1,requestId:"late",operation:"reserve",expectedRevision:3,id:"child",kind:"retain",release:$release,parentId:"lease-a",runId:"run",projectId:"project"}')"
OUT="$(printf '%s' "$LATE" | bash "$CLI" reserve --data-root "$ROOT")"; RC=$?
[ "$RC" -eq 1 ] && jq -e 'any(.diagnostics[];.code=="ID_REUSED")' >/dev/null <<<"$OUT" && pass 'reserva terminada no se recrea tarde' || fail 'reserva terminada fue resucitada'
SOURCE="$(command cat "$REPO_ROOT/src/published/scripts/adapters/lib/opencode-release-use.sh")"
case "$SOURCE" in *'kill '*|*'pkill '*|*'curl '*|*'http:'*) fail 'biblioteca expone red o terminacion de procesos' ;; *) pass 'biblioteca solo coordina localmente' ;; esac
printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
