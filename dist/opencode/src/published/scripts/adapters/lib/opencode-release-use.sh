#!/usr/bin/env bash
# Registro cooperativo de uso de releases. No inicia, termina ni autentica procesos.

release_use_error() { printf '%s\n' "$1" >&2; return 2; }
release_use_semver() { printf '%s\n' "$1" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'; }
release_use_id() { printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'; }

release_use_empty() { jq -cn '{schemaVersion:1,revision:0,leases:[]}'; }
release_use_response() {
    local status="$1" registry="$2" lease_id="${3:-}" diagnostics="${4:-[]}"
    jq -cn --arg status "$status" --arg id "$lease_id" --argjson registry "$registry" --argjson diagnostics "$diagnostics" '
      {schemaVersion:1,status:$status,revision:$registry.revision,
       leaseId:(if $id == "" then null else $id end),
       leases:[$registry.leases[] | {id,kind,phase,release,parentId,bindingDigest,coverage}],
       retainedReleases:([$registry.leases[] | select(.phase != "finished" and .kind == "retain") | .release]),
       executionBlockers:([$registry.leases[] | select(.phase != "finished" and (.kind == "execute" or .kind == "maintenance")) | {id,kind,phase}]),
       diagnostics:$diagnostics,
       capabilities:{schemaVersion:1,reserve:true,attach:true,reconcile:true,verifiedOwnerIdentity:true}}'
}

release_use_registry_path() { printf '%s/runtime-use/v1/registry.json\n' "$1"; }
release_use_validate_root() {
    local root="$1"
    case "$root" in /*) ;; *) return 1;; esac
    [ -d "$root/releases" ] && [ ! -L "$root/releases" ]
}
release_use_read() {
    local root="$1" path
    path="$(release_use_registry_path "$root")"
    [ ! -e "$path" ] && [ ! -L "$path" ] && { release_use_empty; return 0; }
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    jq -ce '. as $registry | (type == "object" and (keys|sort)==["leases","revision","schemaVersion"] and .schemaVersion==1 and (.revision|type=="number" and floor==. and .>=0) and (.leases|type=="array")) as $valid | if $valid then $registry else error("invalid registry") end' "$path" 2>/dev/null
}
release_use_release_valid() {
    local root="$1" release="$2" version commit expected manifest physical
    version="$(jq -r .version <<<"$release")"; commit="$(jq -r .commit <<<"$release")"; expected="$(jq -r .root <<<"$release")"
    release_use_semver "$version" && printf '%s\n' "$commit" | grep -Eq '^[0-9a-f]{40}$' || return 1
    [ -d "$root/releases/$version" ] && [ ! -L "$root/releases/$version" ] || return 1
    physical="$(cd "$root/releases/$version" 2>/dev/null && pwd -P)" || return 1
    [ "$physical" = "$expected" ] || return 1
    manifest="$physical/mefisto-manifest.json"
    [ -f "$manifest" ] && [ ! -L "$manifest" ] && jq -e --arg v "$version" --arg c "$commit" '.schemaVersion==1 and .runtime=="opencode" and .version==$v and .commit==$c' "$manifest" >/dev/null 2>&1
}
release_use_request_valid() {
    jq -e 'type=="object" and .schemaVersion==1 and (.requestId|type=="string" and length>0 and length<=128)' >/dev/null 2>&1 <<<"$1"
}
release_use_write() {
    local root="$1" old="$2" next="$3" dir path tmp
    dir="$root/runtime-use/v1"; path="$dir/registry.json"
    if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then mkdir -p -m 700 "$dir" || return 1; chmod 700 "$root/runtime-use" "$dir" 2>/dev/null || return 1
    fi
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    if [ -e "$path" ] || [ -L "$path" ]; then [ -f "$path" ] && [ ! -L "$path" ] || return 1; [ "$(release_use_read "$root")" = "$old" ] || return 3; fi
    tmp="$dir/.registry.$$.${RANDOM}.new"; (umask 077; printf '%s\n' "$next" > "$tmp") || return 1
    chmod 600 "$tmp" && mv -f "$tmp" "$path" && chmod 600 "$path"
}
release_use_lock_valid() {
    local root="$1" lock="$root/releases/.operation.lock"
    [ -n "${RELEASE_USE_LOCK_TOKEN:-}" ] && [ -d "$lock" ] && [ ! -L "$lock" ] && [ -f "$lock/owner" ] && [ "$(command cat "$lock/owner" 2>/dev/null)" = "$RELEASE_USE_LOCK_TOKEN" ]
}

# opencode_release_use_locked <data-root> <request-json>. El caller ya posee el lock comun.
opencode_release_use_locked() {
    [ "$#" -eq 2 ] || { release_use_error 'uso interno invalido'; return $?; }
    local root="$1" request="$2" op old next id existing lease owner release parent expected revision observation all_gone=true
    release_use_validate_root "$root" && release_use_lock_valid "$root" || { release_use_error 'lock o almacen no verificable'; return $?; }
    release_use_request_valid "$request" || { release_use_error 'request invalido'; return $?; }
    op="$(jq -r .operation <<<"$request")"; old="$(release_use_read "$root")" || { release_use_response conflict "$(release_use_empty)" '' '[{"code":"REGISTRY_INVALID"}]'; return 1; }
    case "$op" in acquire|reserve|attach|finish|reconcile) ;; *) release_use_error 'operacion invalida'; return $?;; esac
    if [ "$op" != reconcile ]; then
        expected="$(jq -r '.expectedRevision // empty' <<<"$request")"
        [ -n "$expected" ] && [ "$expected" = "$(jq -r .revision <<<"$old")" ] || { release_use_response conflict "$old" '' '[{"code":"REVISION_CONFLICT"}]'; return 1; }
    fi
    id="$(jq -r '.id // empty' <<<"$request")"
    case "$op" in acquire|reserve|attach|finish) release_use_id "$id" || { release_use_error 'id invalido'; return $?; };; esac
    existing="$(jq -c --arg id "$id" '[.leases[]? | select(.id==$id)] | first // empty' <<<"$old")"
    case "$op" in
      acquire)
        jq -e '(.kind=="retain" or .kind=="execute" or .kind=="maintenance") and (.ownerPid|type=="number" and floor==. and .>0) and (.runId|type=="string") and (.projectId|type=="string") and (.release|type=="object")' >/dev/null <<<"$request" || { release_use_error 'acquire invalido'; return $?; }
        release="$(jq -c .release <<<"$request")"; release_use_release_valid "$root" "$release" || { release_use_response conflict "$old" '' '[{"code":"RELEASE_IDENTITY_INVALID"}]'; return 1; }
        owner="$(release_use_process_capture "$(jq -r .ownerPid <<<"$request")" 2>/dev/null)" || { release_use_response conflict "$old" '' '[{"code":"OWNER_UNVERIFIABLE"}]'; return 1; }
        lease="$(jq -cn --arg id "$id" --argjson q "$request" --argjson owner "$owner" --argjson release "$release" '{id:$id,kind:$q.kind,phase:"active",release:$release,owner:$owner,parentId:($q.parentId//null),runId:$q.runId,projectId:$q.projectId,coverage:"complete",bindingDigest:($q.bindingDigest//null),finishedReason:null}')"
        if [ -n "$existing" ]; then [ "$existing" = "$lease" ] && { release_use_response ok "$old" "$id"; return 0; }; release_use_response conflict "$old" "$id" '[{"code":"ID_REUSED"}]'; return 1; fi
        if jq -e --arg kind "$(jq -r .kind <<<"$request")" 'any(.leases[]; .phase!="finished" and ((.kind=="maintenance" and $kind=="execute") or (.kind=="execute" and $kind=="maintenance") or (.kind=="maintenance" and $kind=="maintenance")))' <<<"$old" >/dev/null; then release_use_response busy "$old" '' '[{"code":"SEMANTIC_BUSY"}]'; return 75; fi
        ;;
      reserve)
        jq -e '(.kind=="retain" or .kind=="execute" or .kind=="maintenance") and (.parentId|type=="string") and (.runId|type=="string") and (.projectId|type=="string") and (.release|type=="object")' >/dev/null <<<"$request" || { release_use_error 'reserve invalido'; return $?; }
        if [ -n "$existing" ]; then
          [ "$(jq -r .phase <<<"$existing")" != finished ] && [ "$(jq -c .release <<<"$existing")" = "$(jq -c .release <<<"$request")" ] && { release_use_response ok "$old" "$id"; return 0; }
          release_use_response conflict "$old" "$id" '[{"code":"ID_REUSED"}]'; return 1
        fi
        parent="$(jq -c --arg id "$(jq -r .parentId <<<"$request")" '[.leases[]? | select(.id==$id and .phase!="finished")] | first // empty' <<<"$old")"; [ -n "$parent" ] || { release_use_response conflict "$old" '' '[{"code":"PARENT_UNAVAILABLE"}]'; return 1; }
        release="$(jq -c .release <<<"$request")"; [ "$release" = "$(jq -c .release <<<"$parent")" ] || { release_use_response conflict "$old" '' '[{"code":"RESERVATION_SCOPE_INVALID"}]'; return 1; }
        lease="$(jq -cn --arg id "$id" --argjson q "$request" --argjson release "$release" '{id:$id,kind:$q.kind,phase:"reserved",release:$release,owner:null,parentId:$q.parentId,runId:$q.runId,projectId:$q.projectId,coverage:"complete",bindingDigest:($q.bindingDigest//null),finishedReason:null}')"
        ;;
      attach)
        jq -e '(.ownerPid|type=="number" and floor==. and .>0) and (.parentId|type=="string")' >/dev/null <<<"$request" || { release_use_error 'attach invalido'; return $?; }
        [ -n "$existing" ] && [ "$(jq -r .phase <<<"$existing")" = reserved ] && [ "$(jq -r .parentId <<<"$existing")" = "$(jq -r .parentId <<<"$request")" ] || { release_use_response conflict "$old" "$id" '[{"code":"RESERVATION_UNAVAILABLE"}]'; return 1; }
        owner="$(release_use_process_capture "$(jq -r .ownerPid <<<"$request")" 2>/dev/null)" || { release_use_response conflict "$old" '' '[{"code":"OWNER_UNVERIFIABLE"}]'; return 1; }
        lease="$(jq -c --argjson owner "$owner" '.phase="active" | .owner=$owner' <<<"$existing")"
        ;;
      finish)
        [ -n "$existing" ] || { release_use_response conflict "$old" "$id" '[{"code":"LEASE_ABSENT"}]'; return 1; }
        [ "$(jq -r .phase <<<"$existing")" = finished ] && { release_use_response ok "$old" "$id"; return 0; }
        lease="$(jq -c '.phase="finished" | .finishedReason="finished"' <<<"$existing")" ;;
      reconcile)
        next="$old"
        while IFS= read -r lease; do
          [ "$(jq -r .phase <<<"$lease")" = finished ] && continue
          owner="$(jq -c '.owner // null' <<<"$lease")"; [ "$owner" != null ] || continue
          observation="$(release_use_process_observe <<<"$owner" 2>/dev/null)" || observation='{"state":"unknown","groupState":"unknown"}'
          if jq -e '.state=="gone" and .groupState=="empty"' >/dev/null <<<"$observation"; then
            next="$(jq -c --arg id "$(jq -r .id <<<"$lease")" '.leases |= map(if .id==$id then .phase="finished" | .finishedReason="reconciled" else . end)' <<<"$next")"
          fi
        done < <(jq -c '.leases[]' <<<"$old")
        [ "$next" = "$old" ] && { release_use_response ok "$old"; return 0; }
        next="$(jq -c '.revision += 1' <<<"$next")"; release_use_write "$root" "$old" "$next" || { release_use_response conflict "$old" '' '[{"code":"WRITE_CONFLICT"}]'; return 1; }; release_use_response ok "$next"; return 0 ;;
    esac
    next="$(jq -c --arg id "$id" --argjson lease "$lease" '.leases += [$lease] | .revision += 1' <<<"$old")"
    if [ "$op" = attach ] || [ "$op" = finish ]; then next="$(jq -c --arg id "$id" --argjson lease "$lease" '.leases |= map(if .id==$id then $lease else . end) | .revision += 1' <<<"$old")"; fi
    release_use_write "$root" "$old" "$next" || { release_use_response conflict "$old" "$id" '[{"code":"WRITE_CONFLICT"}]'; return 1; }
    release_use_response ok "$next" "$id"
}
