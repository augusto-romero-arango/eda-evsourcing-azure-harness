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
OUT="$(request acquire lease-a 0 | bash "$CLI" acquire --data-root "$ROOT")"; RC=$?
[ "$RC" -eq 0 ] && jq -e '.revision==1' >/dev/null <<<"$OUT" && pass 'reintento identico es idempotente' || fail 'reintento identico no fue idempotente'
OUT="$(request acquire lease-a 1 | jq '.kind="execute"' | bash "$CLI" acquire --data-root "$ROOT")"; RC=$?
[ "$RC" -eq 1 ] && jq -e '.status=="conflict" and any(.diagnostics[];.code=="ID_REUSED")' >/dev/null <<<"$OUT" && pass 'id reutilizado con payload distinto es conflicto' || fail 'id reutilizado fue aceptado'
OUT="$(request acquire lease-b 0 | bash "$CLI" acquire --data-root "$ROOT")"; RC=$?
[ "$RC" -eq 1 ] && jq -e '.status=="conflict"' >/dev/null <<<"$OUT" && pass 'revision desactualizada no escribe' || fail 'conflicto de revision no detectado'
RESERVE="$(jq -cn --argjson release "$(identity)" '{schemaVersion:1,requestId:"reserve",operation:"reserve",expectedRevision:1,id:"child",kind:"retain",release:$release,parentId:"lease-a",runId:"run",projectId:"project"}')"
OUT="$(printf '%s' "$RESERVE" | bash "$CLI" reserve --data-root "$ROOT")"; RC=$?
[ "$RC" -eq 0 ] && jq -e '.revision==2 and (.leases[]|select(.id=="child").phase)=="reserved"' >/dev/null <<<"$OUT" && pass 'reserva hijo antes de lanzamiento' || fail 'reserva invalida'
FINISH="$(jq -cn --argjson pid "$$" '{schemaVersion:1,requestId:"finish",operation:"finish",expectedRevision:2,id:"child",ownerPid:$pid}')"
printf '%s' "$FINISH" | bash "$CLI" finish --data-root "$ROOT" >/dev/null; RC=$?
LATE="$(jq -cn --argjson release "$(identity)" '{schemaVersion:1,requestId:"late",operation:"reserve",expectedRevision:3,id:"child",kind:"retain",release:$release,parentId:"lease-a",runId:"run",projectId:"project"}')"
OUT="$(printf '%s' "$LATE" | bash "$CLI" reserve --data-root "$ROOT")"; RC=$?
[ "$RC" -eq 1 ] && jq -e 'any(.diagnostics[];.code=="ID_REUSED")' >/dev/null <<<"$OUT" && pass 'reserva terminada no se recrea tarde' || fail 'reserva terminada fue resucitada'

RESERVE2="$(jq -cn --argjson release "$(identity)" '{schemaVersion:1,requestId:"reserve-2",operation:"reserve",expectedRevision:3,id:"child-2",kind:"retain",release:$release,parentId:"lease-a",runId:"run",projectId:"project",bindingDigest:"contract-a"}')"
printf '%s' "$RESERVE2" | bash "$CLI" reserve --data-root "$ROOT" >/dev/null
ATTACH2="$(jq -cn --argjson pid "$$" '{schemaVersion:1,requestId:"attach-2",operation:"attach",expectedRevision:4,id:"child-2",parentId:"lease-a",ownerPid:$pid}')"
printf '%s' "$ATTACH2" | bash "$CLI" attach --data-root "$ROOT" >/dev/null
OUT="$(printf '%s' "$RESERVE2" | bash "$CLI" reserve --data-root "$ROOT")"; RC=$?
[ "$RC" -eq 0 ] && jq -e '.revision==5 and (.leases[]|select(.id=="child-2").phase)=="active"' >/dev/null <<<"$OUT" && pass 'reintento tardio de reserve no deshace attach' || fail 'reserve tardio altero la referencia adjunta'
FINISH_PARENT="$(jq -cn --argjson pid "$$" '{schemaVersion:1,requestId:"finish-parent",operation:"finish",expectedRevision:5,id:"lease-a",ownerPid:$pid}')"
OUT="$(printf '%s' "$FINISH_PARENT" | bash "$CLI" finish --data-root "$ROOT")"; RC=$?
[ "$RC" -eq 0 ] && jq -e '(.leases[]|select(.id=="lease-a").phase)=="finished" and (.leases[]|select(.id=="child-2").phase)=="active" and (.leases[]|select(.id=="child-2").bindingDigest)=="contract-a"' >/dev/null <<<"$OUT" && pass 'finish no cierra hijos ni reemplaza bindingDigest' || fail 'finish produjo cascada sobre un hijo'

EXEC1="$(request acquire execute-1 6 | jq '.kind="execute" | .runId="run-a"')"
OUT="$(printf '%s' "$EXEC1" | bash "$CLI" acquire --data-root "$ROOT")"; RC=$?
EXEC2="$(request acquire execute-2 7 | jq '.kind="execute" | .runId="run-b"')"
OUT2="$(printf '%s' "$EXEC2" | bash "$CLI" acquire --data-root "$ROOT")"; RC2=$?
MAINT="$(request acquire maintenance-1 8 | jq '.kind="maintenance" | .runId="maint"')"
BUSY="$(printf '%s' "$MAINT" | bash "$CLI" acquire --data-root "$ROOT")"; BUSY_RC=$?
[ "$RC" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$BUSY_RC" -eq 75 ] && jq -e '.status=="busy" and .revision==8 and any(.diagnostics[];.code=="SEMANTIC_BUSY")' >/dev/null <<<"$BUSY" && pass 'dos corridas ejecutan y bloquean maintenance durante hold o retry' || fail 'exclusion execute/maintenance incorrecta'

FILTER="$(jq -cn --argjson release "$(identity)" '{schemaVersion:1,requestId:"filter",operation:"inspect",id:"execute-1",release:$release}')"
OUT="$(printf '%s' "$FILTER" | bash "$CLI" inspect --data-root "$ROOT")"; RC=$?
[ "$RC" -eq 0 ] && jq -e '(.leases|length)==1 and .leases[0].id=="execute-1" and (.retainedReleases|length)==1 and .capabilities.protocol=="release-use-v1"' >/dev/null <<<"$OUT" && pass 'inspect filtra y anuncia capacidades sin efectos' || fail 'inspect no respeto filtros o capacidades'
LOCK="$ROOT/releases/.operation.lock"; mkdir "$LOCK"; printf 'test-lock\n' > "$LOCK/owner"
OUT="$(RELEASE_USE_LOCK_TOKEN=test-lock bash -c 'source "$1"; source "$2"; opencode_release_use_inspect_locked "$3" "$4"' _ "$REPO_ROOT/src/published/scripts/lib/release-use-process.sh" "$REPO_ROOT/src/published/scripts/adapters/lib/opencode-release-use.sh" "$ROOT" "$INSPECT")"; RC=$?
rm -f "$LOCK/owner"; rmdir "$LOCK"
[ "$RC" -eq 0 ] && jq -e '.status=="ok" and .revision==8 and .leaseId==null' >/dev/null <<<"$OUT" && pass 'inspect_locked reutiliza el lock adquirido por prune' || fail 'inspect_locked intento adquirir otro mutex'

# Observaciones deterministas de #1851: no dependen de los procesos del host de CI.
PROC="$WORK/proc"; HOST="$WORK/machine-id"; BOOT="$WORK/boot-id"; ROWS="$WORK/ps-rows"
mkdir -p "$PROC"; printf 'machine-fixture\n' > "$HOST"; printf 'boot-a\n' > "$BOOT"
UID_NOW="$(id -u)"; printf '1 %s 1\n' "$UID_NOW" > "$ROWS"
export RELEASE_USE_PROCESS_OS=Linux RELEASE_USE_PROCESS_PROC_ROOT="$PROC" RELEASE_USE_PROCESS_MACHINE_ID_FILE="$HOST" RELEASE_USE_PROCESS_BOOT_ID_FILE="$BOOT" RELEASE_USE_PROCESS_PS_ROWS_FILE="$ROWS"
fake_process() {
  local pid="$1" start="$2" pgid="${3:-$1}"
  mkdir -p "$PROC/$pid"
  printf '%s (fixture) S 1 %s %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 %s 0 0 0\n' "$pid" "$pgid" "$pgid" "$start" > "$PROC/$pid/stat"
}
ROOT2="$WORK/reconcile"; RELEASE2="$ROOT2/releases/1.2.3"; mkdir -p "$RELEASE2"
jq -n '{schemaVersion:1,runtime:"opencode",version:"1.2.3",commit:"0123456789abcdef0123456789abcdef01234567",minimumRuntimeVersion:"1"}' > "$RELEASE2/mefisto-manifest.json"
RELEASE2="$(cd "$RELEASE2" && pwd -P)"
identity2() { jq -cn --arg root "$RELEASE2" '{root:$root,version:"1.2.3",commit:"0123456789abcdef0123456789abcdef01234567"}'; }
fixture_acquire() { jq -cn --arg id "$1" --argjson rev "$2" --argjson pid "$3" --argjson release "$(identity2)" --arg coverage "${4:-complete}" '{schemaVersion:1,requestId:("acquire-"+$id),operation:"acquire",expectedRevision:$rev,id:$id,kind:"retain",release:$release,ownerPid:$pid,runId:"fixture",projectId:"fixture",coverage:$coverage}'; }
reconcile() { jq -cn --argjson rev "$1" '{schemaVersion:1,requestId:("reconcile-"+($rev|tostring)),operation:"reconcile",expectedRevision:$rev}'; }

fake_process 5001 101
fixture_acquire reboot 0 5001 | bash "$CLI" acquire --data-root "$ROOT2" >/dev/null
printf 'boot-b\n' > "$BOOT"; OUT="$(reconcile 1 | bash "$CLI" reconcile --data-root "$ROOT2")"; RC=$?
[ "$RC" -eq 0 ] && jq -e '(.leases[]|select(.id=="reboot").phase)=="finished"' >/dev/null <<<"$OUT" && pass 'reboot demostrado recupera referencia' || fail 'reboot demostrado no recupero referencia'

fake_process 5002 201
fixture_acquire recycled 2 5002 | bash "$CLI" acquire --data-root "$ROOT2" >/dev/null
fake_process 5002 202
OUT="$(reconcile 3 | bash "$CLI" reconcile --data-root "$ROOT2")"; RC=$?
[ "$RC" -eq 0 ] && jq -e '(.leases[]|select(.id=="recycled").phase)=="finished"' >/dev/null <<<"$OUT" && pass 'PID reciclado no conserva una identidad vieja' || fail 'PID reciclado fue confundido con el propietario'

fake_process 5003 301
fixture_acquire unknown 4 5003 | bash "$CLI" acquire --data-root "$ROOT2" >/dev/null
mv "$HOST" "$HOST.unavailable"
OUT="$(reconcile 5 | bash "$CLI" reconcile --data-root "$ROOT2")"; RC=$?
[ "$RC" -eq 0 ] && jq -e '.revision==5 and (.leases[]|select(.id=="unknown").phase)=="active" and any(.diagnostics[];.code=="OBSERVATION_UNKNOWN" and .id=="unknown")' >/dev/null <<<"$OUT" && pass 'observacion desconocida conserva y diagnostica' || fail 'observacion desconocida cerro una referencia'
mv "$HOST.unavailable" "$HOST"

fake_process 5004 401
fixture_acquire detached 5 5004 unknown | bash "$CLI" acquire --data-root "$ROOT2" >/dev/null
rm -f "$PROC/5004/stat"; OUT="$(reconcile 6 | bash "$CLI" reconcile --data-root "$ROOT2")"; RC=$?
[ "$RC" -eq 0 ] && jq -e '.revision==6 and (.leases[]|select(.id=="detached").phase)=="active"' >/dev/null <<<"$OUT" && pass 'detached sin recibo y cobertura desconocida conserva' || fail 'cobertura desconocida se trato como prueba de terminacion'

fake_process 6001 501 6001; fake_process 6002 502 6002
fixture_acquire graph-parent 6 6001 | bash "$CLI" acquire --data-root "$ROOT2" >/dev/null
GRAPH_RESERVE="$(jq -cn --argjson release "$(identity2)" '{schemaVersion:1,requestId:"graph-reserve",operation:"reserve",expectedRevision:7,id:"graph-child",kind:"retain",release:$release,parentId:"graph-parent",runId:"fixture",projectId:"fixture"}')"
printf '%s' "$GRAPH_RESERVE" | bash "$CLI" reserve --data-root "$ROOT2" >/dev/null
GRAPH_ATTACH="$(jq -cn '{schemaVersion:1,requestId:"graph-attach",operation:"attach",expectedRevision:8,id:"graph-child",parentId:"graph-parent",ownerPid:6002}')"
printf '%s' "$GRAPH_ATTACH" | bash "$CLI" attach --data-root "$ROOT2" >/dev/null
rm -f "$PROC/6001/stat"; printf '6002 %s 6002\n' "$UID_NOW" > "$ROWS"
OUT="$(reconcile 9 | bash "$CLI" reconcile --data-root "$ROOT2")"; RC=$?
[ "$RC" -eq 0 ] && jq -e '.revision==9 and (.leases[]|select(.id=="graph-parent").phase)=="active" and (.leases[]|select(.id=="graph-child").phase)=="active"' >/dev/null <<<"$OUT" && pass 'padre ausente no borra hijo vivo' || fail 'grafo vivo se recupero prematuramente'
rm -f "$PROC/6002/stat"; printf '1 %s 1\n' "$UID_NOW" > "$ROWS"
OUT="$(reconcile 9 | bash "$CLI" reconcile --data-root "$ROOT2")"; RC=$?
[ "$RC" -eq 0 ] && jq -e '.revision==10 and (.leases[]|select(.id=="graph-parent").phase)=="finished" and (.leases[]|select(.id=="graph-child").phase)=="finished"' >/dev/null <<<"$OUT" && pass 'propietario y todos los hijos terminados se recuperan' || fail 'grafo terminado no se recupero'

BAD_ROOT="$WORK/foreign"; mkdir -p "$BAD_ROOT/releases"; ln -s "$WORK" "$BAD_ROOT/runtime-use"
OUT="$(printf '%s' "$INSPECT" | bash "$CLI" inspect --data-root "$BAD_ROOT")"; RC=$?
[ "$RC" -eq 1 ] && jq -e 'any(.diagnostics[];.code=="REGISTRY_INVALID")' >/dev/null <<<"$OUT" && pass 'almacen symlink falla cerrado sin inicializar contenido ajeno' || fail 'almacen symlink fue seguido'
[ -x "$REPO_ROOT/dist/opencode/release-use.sh" ] && jq -e '.assets[]|select(.id=="release-use" and .destination=="release-use.sh" and .mode=="0755")' "$REPO_ROOT/dist/opencode/.mefisto-generated-assets.json" >/dev/null && pass 'CLI se distribuye en la raiz OpenCode e inventariada' || fail 'CLI no se distribuyo en dist/opencode/release-use.sh'
SOURCE="$(command cat "$REPO_ROOT/src/published/scripts/adapters/lib/opencode-release-use.sh")"
case "$SOURCE" in *'kill '*|*'pkill '*|*'curl '*|*'http:'*) fail 'biblioteca expone red o terminacion de procesos' ;; *) pass 'biblioteca solo coordina localmente' ;; esac
printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
