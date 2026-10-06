#!/usr/bin/env bash
# Handoff real wrapper -> pane -> batch-pipeline.sh con contexto hijo (issue #2005, CA-4,
# MEF-ADR-0055): tmux y herdr reservan el hijo con execution-context.sh real, el comando
# tecleado en el pane se ejecuta tal cual y el batch debe pasar su preflight real y arrancar
# el primer issue. Dos entradas originales: direct y source:command con entryAdmission.
# Hermetico: release copiada de dist/opencode; dobles de tmux/herdr/gh/dotnet/opencode y del
# pipeline hijo; sin LLM, red ni runtime real.
#
# Uso: scripts/tests/test-autonomy-preflight-child-handoff.sh
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../.." && pwd -P)"
FIXTURE="$REPO_ROOT/src/published/scripts/tests/fixtures/autonomy/profile.json"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (esperado '$2', obtenido '$1')"; fi; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
[ -d "$REPO_ROOT/dist/opencode/scripts" ] || { echo 'falta dist/opencode'; exit 1; }
REL="$TMP/release"; cp -R "$REPO_ROOT/dist/opencode" "$REL"
jq -c '{schemaVersion,runtime:"opencode",version,commit}' "$REPO_ROOT/src/published/release-identity.json" > "$REL/mefisto-manifest.json"
cp "$REPO_ROOT/src/published/contract/command-entry.json" "$REL/src/published/contract/command-entry.json"
cat > "$REL/scripts/tooling-pipeline.sh" <<'TP'
#!/usr/bin/env bash
echo "$1" >> "$CALLS"
echo "PR creado: https://github.com/acme/x/pull/$(( $1 + 1000 ))"
TP
printf '#!/usr/bin/env bash\nexit 0\n' > "$REL/scripts/pr-sync.sh"
chmod +x "$REL/scripts/tooling-pipeline.sh" "$REL/scripts/pr-sync.sh"
EC="$REL/scripts/execution-context.sh"; PROFILE="$REL/scripts/autonomy-profile.sh"

BIN="$TMP/bin"; mkdir -p "$BIN"
for b in jq git shasum sha256sum; do p="$(command -v "$b" 2>/dev/null || true)"; [ -z "$p" ] || ln -s "$p" "$BIN/$b"; done
for b in dotnet opencode caffeinate; do printf '#!/bin/sh\n[ "$(basename "$0")" = caffeinate ] && { shift; exec "$@"; }\nexit 0\n' > "$BIN/$b"; done
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = issue ] && [ "$2" = view ] && printf 'OPEN|tipo:tooling\n'
exit 0
STUB
# Los dobles registran el comando tecleado en el pane. tmux: el test lo ejecuta despues del
# wrapper. herdr: el pane lo ejecuta en segundo plano (el propio comando escribe el marcador de
# arranque que el despachador espera), como un pane real.
cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    has-session) exit 1 ;;
    list-panes) echo "%0" ;;
    split-window) echo "%1" ;;
    send-keys) [ "${3:-}" = "%1" ] && [ -n "${4:-}" ] && printf '%s\n' "$4" >> "$PANE_CMDS" ;;
esac
exit 0
STUB
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
    "pane split") n=$(cat "$HERDR_COUNTER" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$HERDR_COUNTER"; echo "{\"result\":{\"pane\":{\"pane_id\":\"w1:p$n\"}}}" ;;
    "pane process-info") echo '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":100}}}' ;;
    "pane run")
        printf '%s\n' "${4:-}" >> "$PANE_CMDS"
        ( bash -c "${4:-}" </dev/null >"$PANE_OUT" 2>&1; echo $? > "$PANE_DONE" ) >/dev/null 2>&1 & ;;
    *) echo '{"result":{"type":"ok"}}' ;;
esac
STUB
chmod +x "$BIN"/*
BASE_PATH="$BIN:/usr/bin:/bin"
export CALLS PANE_CMDS HERDR_COUNTER PANE_OUT PANE_DONE

ec() { printf '%s' "$2" | PATH="$BASE_PATH" bash "$EC" $1; }

# new_consumer <dir>: repo Git con perfil aprobado.
new_consumer() {
    R="$1"; mkdir -p "$R/.mefisto"; git -C "$R" init -q -b main
    git -C "$R" config user.email t@example.com; git -C "$R" config user.name t
    printf '.mefisto/\n' > "$R/.gitignore"; git -C "$R" add . && git -C "$R" commit -qm base
    cp "$FIXTURE" "$R/.mefisto/harness.config.json"
    local d; d="$(cd "$R" && bash "$PROFILE" preview --project-root "$R" | jq -r .expectedDigest)"
    (cd "$R" && bash "$PROFILE" approve --project-root "$R" --expected-digest "$d" >/dev/null)
}

# command_entry <run> <ctx>: contexto de entrada source:command (sequential) adjunto a este
# proceso, con sesion y entryAdmission permitida; deja ENTRY_CTX y ENTRY_DIGEST.
command_entry() {
    local run="$1" ctx="$2" base nonce
    ENTRY_DIGEST="$(ec prepare "$(jq -cn --arg r "$R" --arg run "$run" --arg c "$ctx" '{schemaVersion:1,projectRoot:$r,runId:$run,contextId:$c,rootCommand:"sequential",source:"command",runtime:{id:"opencode",version:"1"},leaseId:("l-"+$c)}')" | jq -r .digest)"
    ec attach "$(jq -cn --arg r "$R" --arg run "$run" --arg c "$ctx" --arg d "$ENTRY_DIGEST" --argjson p $$ '{schemaVersion:1,projectRoot:$r,runId:$run,contextId:$c,digest:$d,ownerPid:$p}')" >/dev/null
    ENTRY_CTX="$R/.mefisto/pipeline/autonomy/runs/$run/contexts/$ctx.json"
    base="$(jq -cn --arg r "$R" --arg run "$run" --arg c "$ctx" --arg d "$ENTRY_DIGEST" '{schemaVersion:1,projectRoot:$r,runId:$run,contextId:$c,digest:$d}')"
    ec bind-session "$(jq -c '. + {sessionID:"s1"}' <<< "$base")" >/dev/null
    nonce="$(jq -r .contract.nonce "$ENTRY_CTX")"
    ec record-entry-admission "$(jq -c --arg n "$nonce" --arg v "$(jq -r .version "$REL/mefisto-manifest.json")" '. + {controllerNonce:$n,entryAdmission:{sessionID:"s1",commandId:"sequential",release:$v,permissionImageDigest:"i",resourcesDigest:"r",policyResult:"allowed",ownership:"projected"}}' <<< "$base")" >/dev/null
}

# run_case <ui:tmux|herdr> <entrada:direct|command>
run_case() {
    local ui="$1" entry="$2" label="$1/$2" rc cmd
    local dir="$TMP/case-$ui-$entry"; mkdir -p "$dir"
    new_consumer "$dir/consumidor"
    CALLS="$dir/calls"; PANE_CMDS="$dir/pane.cmds"; HERDR_COUNTER="$dir/herdr.count"
    PANE_OUT="$dir/batch.out"; PANE_DONE="$dir/pane.done"
    : > "$CALLS"; : > "$PANE_CMDS"; echo 0 > "$HERDR_COUNTER"
    local sets=(PATH="$BASE_PATH" MEFISTO_RUNTIME=opencode)
    if [ "$entry" = command ]; then command_entry run-cmd ctx-cmd; sets+=(MEFISTO_EXECUTION_CONTEXT="$ENTRY_CTX" MEFISTO_EXECUTION_DIGEST="$ENTRY_DIGEST"); fi
    [ "$ui" = herdr ] && sets+=(HERDR_ENV=1 HERDR_PANE_ID=w1:p0 HERDR_WORKSPACE_ID=w1 HERDR_DISPATCH_CONFIRM_TIMEOUT=30)
    ( cd "$R" && env -u MEFISTO_UI -u MEFISTO_STATE_DIR -u MEFISTO_RUNTIME_LIB_DIR -u TMUX -u HERDR_ENV -u HERDR_PANE_ID \
        -u HERDR_WORKSPACE_ID -u MEFISTO_EXECUTION_CONTEXT -u MEFISTO_EXECUTION_DIGEST "${sets[@]}" \
        bash "$REL/scripts/$ui-pipeline.sh" --batch 1 2 ) </dev/null >"$dir/wrapper.out" 2>&1
    rc=$?
    eq "$rc" 0 "$label: el wrapper despacha"
    cmd="$(grep 'batch-pipeline.sh' "$PANE_CMDS" | head -1)"
    if [ -z "$cmd" ]; then fail "$label: el pane no recibio la invocacion del batch"; return; fi
    case "$cmd" in *MEFISTO_EXECUTION_CONTEXT=*ctx-c-*) pass "$label: el pane transporta el contexto hijo" ;;
        *) fail "$label: el pane no transporta el contexto hijo" ;; esac
    if [ "$ui" = tmux ]; then
        ( cd "$R" && PATH="$BASE_PATH" bash -c "$cmd" ) </dev/null >"$PANE_OUT" 2>&1
    else
        local i=0; while [ ! -s "$PANE_DONE" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
    fi
    if grep -q 'Preflight de autonomia antes del primer issue: blocked\|no iniciado por preflight' "$PANE_OUT"; then
        fail "$label: el batch bloqueo su preflight ($(grep -o 'blocked \[[^]]*\]' "$PANE_OUT" | head -1))"
    else
        pass "$label: el batch pasa su preflight con el contexto hijo"
    fi
    eq "$(head -1 "$CALLS")" 1 "$label: el batch arranca el primer issue"
}

for ui in tmux herdr; do
    for entry in direct command; do
        echo "[$ui/$entry] handoff wrapper -> pane -> batch-pipeline.sh"
        run_case "$ui" "$entry"
    done
done

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
