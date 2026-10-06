#!/usr/bin/env bash
# Preflight con contexto hijo delegado (source:pipeline, issue #2005, MEF-ADR-0055): el hijo
# lo reserva execution-context.sh reserve-child; el padre vino de entrada direct o de un comando.
# Tambien cubre el helper unico pipeline_preflight_source en los cuatro orquestadores.
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
PF="$REL/scripts/autonomy-preflight.sh"; PROFILE="$REL/scripts/autonomy-profile.sh"; EC="$REL/scripts/execution-context.sh"
BIN="$TMP/bin"; mkdir -p "$BIN"
for b in jq git shasum sha256sum; do p="$(command -v "$b" 2>/dev/null || true)"; [ -z "$p" ] || ln -s "$p" "$BIN/$b"; done
printf '#!/bin/sh\nexit 0\n' > "$BIN/gh"; chmod +x "$BIN/gh"
BASE_PATH="$BIN:/usr/bin:/bin"

R="$TMP/consumer"; mkdir -p "$R/.mefisto"; git -C "$R" init -q -b main
git -C "$R" config user.email t@example.com; git -C "$R" config user.name t
printf '.mefisto/\n' > "$R/.gitignore"; git -C "$R" add . && git -C "$R" commit -qm base
cp "$FIXTURE" "$R/.mefisto/harness.config.json"
DIGEST="$(cd "$R" && bash "$PROFILE" preview --project-root "$R" | jq -r .expectedDigest)"
(cd "$R" && bash "$PROFILE" approve --project-root "$R" --expected-digest "$DIGEST" >/dev/null)

ec() { printf '%s' "$2" | PATH="$BASE_PATH" bash "$EC" $1; }
ctxpath() { printf '%s/.mefisto/pipeline/autonomy/runs/%s/contexts/%s.json' "$R" "$1" "$2"; }
mkparent() { # run ctx source -> digest
    local d
    d="$(ec prepare "$(jq -cn --arg r "$R" --arg run "$1" --arg c "$2" --arg s "$3" '{schemaVersion:1,projectRoot:$r,runId:$run,contextId:$c,rootCommand:"sequential",source:$s,runtime:{id:"opencode",version:"1"},leaseId:("l-"+$c)}')" | jq -r .digest)"
    ec attach "$(jq -cn --arg r "$R" --arg run "$1" --arg c "$2" --arg d "$d" --argjson p $$ '{schemaVersion:1,projectRoot:$r,runId:$run,contextId:$c,digest:$d,ownerPid:$p}')" >/dev/null
    printf '%s' "$d"
}
mkchild() { # run parentctx parentdigest childid -> ruta
    ec reserve-child "$(jq -cn --arg r "$R" --arg run "$1" --arg p "$2" --arg d "$3" --arg c "$4" '{schemaVersion:1,projectRoot:$r,runId:$run,contextId:$p,digest:$d,childContextId:$c,reservationId:("res-"+$c),executionRoot:$r,pipelineKind:"tooling"}')" | jq -r .path
}
plan() { jq -cn --arg lk "$1" --arg s "$2" '{schemaVersion:1,launchKind:$lk,source:$s,issues:[{number:1,pipelineKind:"tooling"},{number:2,pipelineKind:"tooling"}],requestedOperations:[]}'; }
OUT=""; RC=0
pf() { OUT="$(cd "$R" && printf '%s' "$1" | PATH="$BASE_PATH" bash "$PF" --project-root "$R" --runtime opencode --context "$2" 2>/dev/null)"; RC=$?; }
j() { printf '%s' "$OUT" | jq -r "$1 // empty"; }
chk() { printf '%s' "$OUT" | jq -r --arg c "$1" '[.checks[] | select(.code == $c)][0] | "\(.state)/\(.actionCode)"'; }
codes() { printf '%s' "$OUT" | jq -r '.diagnostics | map(split(":")[0]) | join(",")'; }

echo '[1] Hijo de una entrada direct'
PD="$(mkparent runD ctx-d pipeline)"; CH="$(mkchild runD ctx-d "$PD" ctx-c-d1)"
pf "$(plan sequential pipeline)" "$CH"
eq "$(j .status)/$RC" 'ready-to-dispatch/0' 'hijo valido con padre direct queda ready-to-dispatch'
eq "$(chk ENTRY_ADMISSION)" 'not-applicable/DIRECT_INVOCATION' 'sin comando de origen la entrada no aplica'
pf "$(plan sequential command)" "$CH"
eq "$(j .status)/$(codes | grep -c CONTEXT_SCOPE)" 'blocked/1' 'contexto pipeline presentado como command sigue bloqueando'
pf "$(plan sequential direct)" "$CH"; eq "$RC" 2 'source:direct con --context es protocolo invalido'
pf "$(plan parallel pipeline)" "$CH"
eq "$(chk CONTEXT_SCOPE)" 'block/CONTEXT_SCOPE_MISMATCH' 'rootCommand incoherente con launchKind bloquea'

echo '[2] Hijo de una entrada source:command'
PC="$(mkparent runC ctx-p command)"; CC="$(mkchild runC ctx-p "$PC" ctx-c-p1)"
pf "$(plan sequential pipeline)" "$CC"
eq "$(j .status)/$(chk ENTRY_ADMISSION)" 'incomplete/block/ENTRY_ADMISSION_MISSING' 'padre command sin entryAdmission bloquea'
PCTX="$(ctxpath runC ctx-p)"
base="$(jq -cn --arg r "$R" --arg d "$PC" '{schemaVersion:1,projectRoot:$r,runId:"runC",contextId:"ctx-p",digest:$d}')"
ec bind-session "$(jq -c '. + {sessionID:"s1"}' <<< "$base")" >/dev/null
NONCE="$(jq -r .contract.nonce "$PCTX")"
ec record-entry-admission "$(jq -c --arg n "$NONCE" --arg v "$(jq -r .version "$REL/mefisto-manifest.json")" '. + {controllerNonce:$n,entryAdmission:{sessionID:"s1",commandId:"sequential",release:$v,permissionImageDigest:"i",resourcesDigest:"r",policyResult:"allowed",ownership:"projected"}}' <<< "$base")" >/dev/null
pf "$(plan sequential pipeline)" "$CC"
eq "$(j .status)/$RC/$(chk ENTRY_ADMISSION)" 'ready-to-dispatch/0/pass/NONE' 'padre command con entryAdmission valida admite al hijo'
eq "$(j .resourcesDigest)" 'r' 'la evidencia de entrada es la del padre'

echo '[3] Rechazos con causa concreta'
mkdir -p "$R/.mefisto/pipeline/autonomy/runs/runX/contexts"; cp "$CH" "$R/.mefisto/pipeline/autonomy/runs/runX/contexts/ctx-c-d1.json"
pf "$(plan sequential pipeline)" "$R/.mefisto/pipeline/autonomy/runs/runX/contexts/ctx-c-d1.json"
eq "$(chk CONTEXT_ORIGIN)" 'block/CONTEXT_ORIGIN_MISMATCH' 'contexto hijo de otro run'
jq '.contract.allowedPipelines = ["iac"]' "$CH" > "$TMP/c.json" && cp "$TMP/c.json" "$CH"
pf "$(plan sequential pipeline)" "$CH"
eq "$(j .status)" 'blocked' 'allowedPipelines que no cubre el plan (o digest alterado) bloquea'
(cd "$R" && bash "$PROFILE" revoke --project-root "$R" >/dev/null)
pf "$(plan sequential pipeline)" "$CC"
eq "$(j .status)/$(chk PROFILE_CONSENT)" 'blocked/block/CONSENT_REVOKED' 'perfil revocado bloquea'

echo '[4] Helper unico en los orquestadores'
if git -C "$REPO_ROOT" grep -n 'src=command' -- scripts >/dev/null 2>&1; then fail 'quedan src=command en scripts/'; else pass 'sin src=command en scripts/'; fi
for o in batch parallel tmux herdr; do
    grep -q 'src="$(pipeline_preflight_source)"' "$REPO_ROOT/scripts/$o-pipeline.sh" && pass "$o usa el helper" || fail "$o no usa el helper"
done
HELPER_SRC="$(sed -n '/^pipeline_preflight_source()/,/^}/p' "$REPO_ROOT/scripts/_pipeline-common.sh")"
helper() { MEFISTO_EXECUTION_CONTEXT="$1" bash -c "$HELPER_SRC"$'\n''pipeline_preflight_source'; }
eq "$(helper '')" direct 'sin contexto: direct'
eq "$(helper "$CC")" pipeline 'contexto hijo: pipeline'
eq "$(helper "$TMP/no-existe.json")" command 'contexto ilegible: command (el preflight lo bloquea)'

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
