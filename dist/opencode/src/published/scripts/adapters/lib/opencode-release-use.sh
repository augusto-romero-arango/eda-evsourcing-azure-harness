#!/usr/bin/env bash
# Registro cooperativo de uso de releases. No inicia, termina ni autentica procesos.

release_use_error() { printf '%s\n' "$1" >&2; return 2; }
release_use_semver() { printf '%s\n' "$1" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'; }
release_use_id() { printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'; }
release_use_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }
release_use_uid() { stat -f '%u' "$1" 2>/dev/null || stat -c '%u' "$1" 2>/dev/null; }

release_use_empty() { jq -cn '{schemaVersion:1,revision:0,leases:[]}'; }
release_use_filter() {
    local registry="$1" request="$2"
    jq -c --arg id "$(jq -r '.id // empty' <<<"$request")" --argjson wanted "$(jq -c '.release // null' <<<"$request")" '
      .leases |= map(select(($id=="" or .id==$id) and ($wanted==null or .release==$wanted)))' <<<"$registry"
}
release_use_response() {
    local status="$1" registry="$2" lease_id="${3:-}" diagnostics="${4:-[]}"
    jq -cn --arg status "$status" --arg id "$lease_id" --argjson registry "$registry" --argjson diagnostics "$diagnostics" '
      {schemaVersion:1,status:$status,revision:$registry.revision,
       leaseId:(if $id == "" then null else $id end),
       leases:[$registry.leases[] | {id,kind,phase,release,parentId,bindingDigest,coverage}],
       retainedReleases:([$registry.leases[] | select(.phase != "finished") | .release] | unique_by(.root,.version,.commit)),
       executionBlockers:([$registry.leases[] | select(.phase != "finished" and (.kind == "execute" or .kind == "maintenance")) | {id,kind,phase}]),
       diagnostics:$diagnostics,
       capabilities:{schemaVersion:1,protocol:"release-use-v1",ownerIdentity:"host-boot-pid-start-group",reservedAttachBeforeWork:true,verifiedReconcile:true}}'
}

release_use_registry_path() { printf '%s/runtime-use/v1/registry.json\n' "$1"; }
release_use_validate_root() {
    local root="$1" current_uid
    case "$root" in /*) ;; *) return 1;; esac
    [ -d "$root" ] && [ ! -L "$root" ] && [ -d "$root/releases" ] && [ ! -L "$root/releases" ] || return 1
    current_uid="$(id -u)" || return 1
    [ "$(release_use_uid "$root")" = "$current_uid" ] && [ "$(release_use_uid "$root/releases")" = "$current_uid" ]
}
release_use_owner_valid() {
    jq -e 'type=="object" and (keys|sort)==["bootId","hostFingerprint","pgid","pid","schemaVersion","startToken"] and
      .schemaVersion==1 and (.hostFingerprint|type=="string" and test("^[0-9a-f]{64}$")) and
      (.bootId|type=="string" and length>0) and (.startToken|type=="string" and length>0) and
      (.pid|type=="number" and floor==. and .>0) and (.pgid|type=="number" and floor==. and .>0)' >/dev/null 2>&1 <<<"$1"
}
release_use_read() {
    local root="$1" path dir parent current_uid registry
    path="$(release_use_registry_path "$root")"; dir="${path%/*}"; parent="${dir%/*}"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        [ ! -e "$parent" ] && [ ! -L "$parent" ] && { release_use_empty; return 0; }
        current_uid="$(id -u)" || return 1
        [ -d "$parent" ] && [ ! -L "$parent" ] && [ "$(release_use_uid "$parent")" = "$current_uid" ] && [ "$(release_use_mode "$parent")" = 700 ] || return 1
        if [ -e "$dir" ] || [ -L "$dir" ]; then
            [ -d "$dir" ] && [ ! -L "$dir" ] && [ "$(release_use_uid "$dir")" = "$current_uid" ] && [ "$(release_use_mode "$dir")" = 700 ] || return 1
        fi
        release_use_empty; return 0
    fi
    current_uid="$(id -u)" || return 1
    [ -d "$parent" ] && [ ! -L "$parent" ] && [ "$(release_use_uid "$parent")" = "$current_uid" ] && [ "$(release_use_mode "$parent")" = 700 ] || return 1
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ "$(release_use_uid "$dir")" = "$current_uid" ] && [ "$(release_use_mode "$dir")" = 700 ] || return 1
    [ -f "$path" ] && [ ! -L "$path" ] && [ "$(release_use_uid "$path")" = "$current_uid" ] && [ "$(release_use_mode "$path")" = 600 ] || return 1
    registry="$(jq -ce '
      . as $registry | (type=="object" and (keys|sort)==["leases","revision","schemaVersion"] and .schemaVersion==1 and
      (.revision|type=="number" and floor==. and .>=0) and (.leases|type=="array") and
      (([.leases[].id]|length) == ([.leases[].id]|unique|length)) and all(.leases[];
        type=="object" and (keys|sort)==["bindingDigest","coverage","finishedReason","id","kind","owner","parentId","phase","projectId","release","runId"] and
        (.id|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
        (.kind=="retain" or .kind=="execute" or .kind=="maintenance") and
        (.phase=="reserved" or .phase=="active" or .phase=="finished") and
        (.coverage=="complete" or .coverage=="unknown") and (.runId|type=="string" and length>0 and length<=256) and
        (.projectId|type=="string" and length>0 and length<=256) and
        (.release|type=="object" and (keys|sort)==["commit","root","version"] and (.root|type=="string") and (.version|type=="string") and (.commit|type=="string")) and
        (.parentId==null or (.parentId|type=="string")) and (.bindingDigest==null or (.bindingDigest|type=="string" and length>0 and length<=256)) and
        ((.phase=="reserved" and .owner==null) or (.phase=="active" and (.owner|type=="object")) or .phase=="finished") and
        ((.phase=="finished" and (.finishedReason|type=="string" and length>0)) or (.phase!="finished" and .finishedReason==null)) and
        (.parentId==null or (.parentId as $parent | $parent!=.id and any($registry.leases[];.id==$parent))))) as $valid |
      if $valid then $registry else error("invalid registry") end' "$path" 2>/dev/null)" || return 1
    while IFS= read -r owner; do release_use_owner_valid "$owner" || return 1; done < <(jq -c '.leases[]|select(.owner!=null)|.owner' <<<"$registry")
    printf '%s\n' "$registry"
}
release_use_release_valid() {
    local root="$1" release="$2" version commit expected manifest physical
    jq -e 'type=="object" and (keys|sort)==["commit","root","version"] and (.root|type=="string") and (.version|type=="string") and (.commit|type=="string")' >/dev/null 2>&1 <<<"$release" || return 1
    version="$(jq -r .version <<<"$release")"; commit="$(jq -r .commit <<<"$release")"; expected="$(jq -r .root <<<"$release")"
    release_use_semver "$version" && printf '%s\n' "$commit" | grep -Eq '^[0-9a-f]{40}$' || return 1
    [ -d "$root/releases/$version" ] && [ ! -L "$root/releases/$version" ] || return 1
    physical="$(cd "$root/releases/$version" 2>/dev/null && pwd -P)" || return 1
    [ "$physical" = "$expected" ] || return 1
    manifest="$physical/mefisto-manifest.json"
    [ -f "$manifest" ] && [ ! -L "$manifest" ] && jq -e --arg v "$version" --arg c "$commit" '.schemaVersion==1 and .runtime=="opencode" and .version==$v and .commit==$c' "$manifest" >/dev/null 2>&1
}
release_use_request_valid() {
    jq -e 'type=="object" and .schemaVersion==1 and (.requestId|type=="string" and length>0 and length<=128) and (.operation|type=="string")' >/dev/null 2>&1 <<<"$1"
}
release_use_prepare_store() {
    local root="$1" parent="$root/runtime-use" dir="$root/runtime-use/v1" current_uid
    current_uid="$(id -u)" || return 1
    if [ ! -e "$parent" ] && [ ! -L "$parent" ]; then (umask 077; mkdir "$parent") || return 1; fi
    [ -d "$parent" ] && [ ! -L "$parent" ] && [ "$(release_use_uid "$parent")" = "$current_uid" ] && [ "$(release_use_mode "$parent")" = 700 ] || return 1
    if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then (umask 077; mkdir "$dir") || return 1; fi
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ "$(release_use_uid "$dir")" = "$current_uid" ] && [ "$(release_use_mode "$dir")" = 700 ]
}
release_use_write() {
    local root="$1" old="$2" next="$3" dir path tmp current
    dir="$root/runtime-use/v1"; path="$dir/registry.json"
    release_use_prepare_store "$root" || return 1
    if [ -e "$path" ] || [ -L "$path" ]; then
        current="$(release_use_read "$root")" || return 1
        [ "$current" = "$old" ] || return 3
    else
        [ "$old" = "$(release_use_empty)" ] || return 3
    fi
    tmp="$(mktemp "$dir/.registry.XXXXXX")" || return 1
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    if ! printf '%s\n' "$next" > "$tmp" || ! mv -f "$tmp" "$path"; then rm -f "$tmp"; return 1; fi
    [ -f "$path" ] && [ ! -L "$path" ] && [ "$(release_use_mode "$path")" = 600 ]
}
release_use_lock_valid() {
    local root="$1" lock="$root/releases/.operation.lock" token="${RELEASE_USE_LOCK_TOKEN:-}"
    [ -n "$token" ] && [ -d "$lock" ] && [ ! -L "$lock" ] && [ -f "$lock/owner" ] && [ ! -L "$lock/owner" ] && [ "$(command cat "$lock/owner" 2>/dev/null)" = "$token" ]
}
release_use_scope_valid() {
    local parent="$1" request="$2"
    [ -n "$parent" ] &&
      [ "$(jq -c .release <<<"$parent")" = "$(jq -c .release <<<"$request")" ] &&
      [ "$(jq -r .kind <<<"$parent")" = "$(jq -r .kind <<<"$request")" ] &&
      [ "$(jq -r .runId <<<"$parent")" = "$(jq -r .runId <<<"$request")" ] &&
      [ "$(jq -r .projectId <<<"$parent")" = "$(jq -r .projectId <<<"$request")" ]
}
release_use_semantic_busy() {
    local registry="$1" kind="$2" parent_id="${3:-}"
    jq -e --arg kind "$kind" --arg parent "$parent_id" 'any(.leases[]; .phase!="finished" and .id!=$parent and
      (($kind=="execute" and .kind=="maintenance") or ($kind=="maintenance" and (.kind=="execute" or .kind=="maintenance"))))' <<<"$registry" >/dev/null
}

opencode_release_use_inspect_locked() {
    [ "$#" -eq 2 ] || { release_use_error 'uso interno invalido'; return $?; }
    local root="$1" request="$2" registry filtered
    release_use_validate_root "$root" && release_use_lock_valid "$root" || { release_use_error 'lock o almacen no verificable'; return $?; }
    release_use_request_valid "$request" && jq -e '.operation=="inspect" and (.id==null or (.id|type=="string")) and (.release==null or (.release|type=="object"))' >/dev/null 2>&1 <<<"$request" || { release_use_error 'request invalido'; return $?; }
    registry="$(release_use_read "$root")" || { release_use_response conflict "$(release_use_empty)" '' '[{"code":"REGISTRY_INVALID"}]'; return 1; }
    filtered="$(release_use_filter "$registry" "$request")" || { release_use_error 'filtro invalido'; return $?; }
    release_use_response ok "$filtered"
}

# opencode_release_use_locked <data-root> <request-json>. El caller ya posee el lock comun.
opencode_release_use_locked() {
    [ "$#" -eq 2 ] || { release_use_error 'uso interno invalido'; return $?; }
    local root="$1" request="$2" op old next id existing lease owner release parent expected diagnostics='[]' changed observation response_id
    release_use_validate_root "$root" && release_use_lock_valid "$root" || { release_use_error 'lock o almacen no verificable'; return $?; }
    release_use_request_valid "$request" || { release_use_error 'request invalido'; return $?; }
    op="$(jq -r .operation <<<"$request")"; old="$(release_use_read "$root")" || { release_use_response conflict "$(release_use_empty)" '' '[{"code":"REGISTRY_INVALID"}]'; return 1; }
    case "$op" in acquire|reserve|attach|finish|reconcile) ;; *) release_use_error 'operacion invalida'; return $?;; esac
    expected="$(jq -r 'if (.expectedRevision|type)=="number" and (.expectedRevision|floor)==.expectedRevision and .expectedRevision>=0 then .expectedRevision else empty end' <<<"$request")"
    [ -n "$expected" ] || { release_use_error 'revision esperada invalida'; return $?; }
    id="$(jq -r '.id // empty' <<<"$request")"
    case "$op" in acquire|reserve|attach|finish) release_use_id "$id" || { release_use_error 'id invalido'; return $?; };; esac
    existing="$(jq -c --arg id "$id" '[.leases[]? | select(.id==$id)] | first // empty' <<<"$old")"
    case "$op" in
      acquire)
        jq -e '(.kind=="retain" or .kind=="execute" or .kind=="maintenance") and (.ownerPid|type=="number" and floor==. and .>0) and
          (.runId|type=="string" and length>0 and length<=256) and (.projectId|type=="string" and length>0 and length<=256) and (.release|type=="object") and
          (.parentId==null or (.parentId|type=="string" and length>0)) and (.coverage==null or .coverage=="complete" or .coverage=="unknown") and
          (.bindingDigest==null or (.bindingDigest|type=="string" and length>0 and length<=256)) and (.owner==null) and (.startToken==null)' >/dev/null <<<"$request" || { release_use_error 'acquire invalido'; return $?; }
        release="$(jq -c .release <<<"$request")"; release_use_release_valid "$root" "$release" || { release_use_response conflict "$old" '' '[{"code":"RELEASE_IDENTITY_INVALID"}]'; return 1; }
        if [ "$(jq -r '.parentId // empty' <<<"$request")" != '' ]; then parent="$(jq -c --arg id "$(jq -r .parentId <<<"$request")" '[.leases[]|select(.id==$id)]|first//empty' <<<"$old")"; release_use_scope_valid "$parent" "$request" || { release_use_response conflict "$old" "$id" '[{"code":"PARENT_SCOPE_INVALID"}]'; return 1; }; fi
        owner="$(release_use_process_capture "$(jq -r .ownerPid <<<"$request")" 2>/dev/null)" || { release_use_response conflict "$old" '' '[{"code":"OWNER_UNVERIFIABLE"}]'; return 1; }
        lease="$(jq -cn --arg id "$id" --argjson q "$request" --argjson owner "$owner" --argjson release "$release" --arg inherited "$(if [ -n "${parent:-}" ]; then jq -r .coverage <<<"$parent"; else printf complete; fi)" '{id:$id,kind:$q.kind,phase:"active",release:$release,owner:$owner,parentId:($q.parentId//null),runId:$q.runId,projectId:$q.projectId,coverage:($q.coverage//$inherited),bindingDigest:($q.bindingDigest//null),finishedReason:null}')"
        [ -z "${parent:-}" ] || [ "$(jq -r .coverage <<<"$lease")" = "$(jq -r .coverage <<<"$parent")" ] || { release_use_response conflict "$old" "$id" '[{"code":"COVERAGE_SCOPE_INVALID"}]'; return 1; }
        if [ -n "$existing" ]; then [ "$existing" = "$lease" ] && { release_use_response ok "$old" "$id"; return 0; }; release_use_response conflict "$old" "$id" '[{"code":"ID_REUSED"}]'; return 1; fi
        [ -z "${parent:-}" ] || [ "$(jq -r .phase <<<"$parent")" = active ] || { release_use_response conflict "$old" "$id" '[{"code":"PARENT_UNAVAILABLE"}]'; return 1; }
        ;;
      reserve)
        jq -e '(.kind=="retain" or .kind=="execute" or .kind=="maintenance") and (.parentId|type=="string" and length>0) and
          (.runId|type=="string" and length>0 and length<=256) and (.projectId|type=="string" and length>0 and length<=256) and (.release|type=="object") and
          (.coverage==null or .coverage=="complete" or .coverage=="unknown") and (.bindingDigest==null or (.bindingDigest|type=="string" and length>0 and length<=256))' >/dev/null <<<"$request" || { release_use_error 'reserve invalido'; return $?; }
        release="$(jq -c .release <<<"$request")"; release_use_release_valid "$root" "$release" || { release_use_response conflict "$old" '' '[{"code":"RELEASE_IDENTITY_INVALID"}]'; return 1; }
        parent="$(jq -c --arg id "$(jq -r .parentId <<<"$request")" '[.leases[]|select(.id==$id)]|first//empty' <<<"$old")"
        release_use_scope_valid "$parent" "$request" || { release_use_response conflict "$old" '' '[{"code":"RESERVATION_SCOPE_INVALID"}]'; return 1; }
        lease="$(jq -cn --arg id "$id" --argjson q "$request" --argjson release "$release" --arg inherited "$(jq -r .coverage <<<"$parent")" '{id:$id,kind:$q.kind,phase:"reserved",release:$release,owner:null,parentId:$q.parentId,runId:$q.runId,projectId:$q.projectId,coverage:($q.coverage//$inherited),bindingDigest:($q.bindingDigest//null),finishedReason:null}')"
        [ "$(jq -r .coverage <<<"$lease")" = "$(jq -r .coverage <<<"$parent")" ] || { release_use_response conflict "$old" "$id" '[{"code":"COVERAGE_SCOPE_INVALID"}]'; return 1; }
        if [ -n "$existing" ]; then
          if [ "$(jq -r .phase <<<"$existing")" != finished ] && jq -e --argjson desired "$lease" '.kind==$desired.kind and .release==$desired.release and .parentId==$desired.parentId and .runId==$desired.runId and .projectId==$desired.projectId and .coverage==$desired.coverage and .bindingDigest==$desired.bindingDigest' >/dev/null <<<"$existing"; then release_use_response ok "$old" "$id"; return 0; fi
          release_use_response conflict "$old" "$id" '[{"code":"ID_REUSED"}]'; return 1
        fi
        [ "$(jq -r .phase <<<"$parent")" = active ] || { release_use_response conflict "$old" "$id" '[{"code":"PARENT_UNAVAILABLE"}]'; return 1; }
        ;;
      attach)
        jq -e '(.ownerPid|type=="number" and floor==. and .>0) and (.parentId|type=="string" and length>0) and (.bindingDigest==null) and (.startToken==null)' >/dev/null <<<"$request" || { release_use_error 'attach invalido'; return $?; }
        [ -n "$existing" ] || { release_use_response conflict "$old" "$id" '[{"code":"RESERVATION_UNAVAILABLE"}]'; return 1; }
        if [ "$(jq -r .phase <<<"$existing")" = active ]; then
          owner="$(release_use_process_capture "$(jq -r .ownerPid <<<"$request")" 2>/dev/null)" || owner='null'
          [ "$(jq -c .owner <<<"$existing")" = "$owner" ] && [ "$(jq -r .parentId <<<"$existing")" = "$(jq -r .parentId <<<"$request")" ] && { release_use_response ok "$old" "$id"; return 0; }
        fi
        [ "$(jq -r .phase <<<"$existing")" = reserved ] && [ "$(jq -r .parentId <<<"$existing")" = "$(jq -r .parentId <<<"$request")" ] || { release_use_response conflict "$old" "$id" '[{"code":"RESERVATION_UNAVAILABLE"}]'; return 1; }
        owner="$(release_use_process_capture "$(jq -r .ownerPid <<<"$request")" 2>/dev/null)" || { release_use_response conflict "$old" '' '[{"code":"OWNER_UNVERIFIABLE"}]'; return 1; }
        lease="$(jq -c --argjson owner "$owner" '.phase="active" | .owner=$owner' <<<"$existing")"
        ;;
      finish)
        jq -e '(.ownerPid|type=="number" and floor==. and .>0) and (.reason==null or (.reason|type=="string" and length>0 and length<=128))' >/dev/null <<<"$request" || { release_use_error 'finish invalido'; return $?; }
        [ -n "$existing" ] || { release_use_response conflict "$old" "$id" '[{"code":"LEASE_ABSENT"}]'; return 1; }
        [ "$(jq -r .phase <<<"$existing")" = finished ] && { release_use_response ok "$old" "$id"; return 0; }
        owner="$(release_use_process_capture "$(jq -r .ownerPid <<<"$request")" 2>/dev/null)" || { release_use_response conflict "$old" "$id" '[{"code":"CLOSER_UNVERIFIABLE"}]'; return 1; }
        if [ "$(jq -r .phase <<<"$existing")" = active ]; then
          [ "$(jq -c .owner <<<"$existing")" = "$owner" ] || { release_use_response conflict "$old" "$id" '[{"code":"OWNER_MISMATCH"}]'; return 1; }
        else
          parent="$(jq -c --arg id "$(jq -r .parentId <<<"$existing")" '[.leases[]|select(.id==$id)]|first//empty' <<<"$old")"
          [ -n "$parent" ] && [ "$(jq -c .owner <<<"$parent")" = "$owner" ] || { release_use_response conflict "$old" "$id" '[{"code":"OWNER_MISMATCH"}]'; return 1; }
        fi
        lease="$(jq -c --arg reason "$(jq -r '.reason // "finished"' <<<"$request")" '.phase="finished" | .finishedReason=$reason' <<<"$existing")" ;;
      reconcile)
        jq -e '(.ids==null or (.ids|type=="array" and all(.[];type=="string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))))' >/dev/null <<<"$request" || { release_use_error 'reconcile invalido'; return $?; }
        ;;
    esac
    if [ "$op" != reconcile ] && [ -n "${lease:-}" ] && [ -n "$existing" ] && [ "$existing" = "$lease" ]; then release_use_response ok "$old" "$id"; return 0; fi
    [ "$expected" = "$(jq -r .revision <<<"$old")" ] || { release_use_response conflict "$old" "$id" '[{"code":"REVISION_CONFLICT"}]'; return 1; }
    case "$op" in
      acquire|reserve)
        if [ "$op" = acquire ]; then
          release_use_semantic_busy "$old" "$(jq -r .kind <<<"$request")" "$(jq -r '.parentId // empty' <<<"$request")" && { release_use_response busy "$old" '' '[{"code":"SEMANTIC_BUSY"}]'; return 75; }
        fi
        next="$(jq -c --argjson lease "$lease" '.leases += [$lease] | .revision += 1' <<<"$old")" ;;
      attach|finish)
        next="$(jq -c --arg id "$id" --argjson lease "$lease" '.leases |= map(if .id==$id then $lease else . end) | .revision += 1' <<<"$old")" ;;
      reconcile)
        next="$old"; changed=true
        while [ "$changed" = true ]; do
          changed=false
          while IFS= read -r lease; do
            id="$(jq -r .id <<<"$lease")"
            jq -e --arg id "$id" '.ids==null or any(.ids[];$id==.)' <<<"$request" >/dev/null || continue
            [ "$(jq -r .phase <<<"$lease")" != finished ] && [ "$(jq -r .coverage <<<"$lease")" = complete ] || continue
            if jq -e --arg id "$id" 'any(.leases[];.parentId==$id and .phase!="finished")' <<<"$next" >/dev/null; then continue; fi
            if [ "$(jq -r .phase <<<"$lease")" = reserved ]; then
              parent="$(jq -c --arg id "$(jq -r .parentId <<<"$lease")" '[.leases[]|select(.id==$id)]|first//empty' <<<"$next")"
              [ -n "$parent" ] || { diagnostics="$(jq -c --arg id "$id" '.+[{code:"PARENT_UNKNOWN",id:$id}]' <<<"$diagnostics")"; continue; }
              if [ "$(jq -r .phase <<<"$parent")" = finished ]; then observation='{"state":"gone","groupState":"empty"}'
              else observation="$(jq -c '.owner // null' <<<"$parent" | release_use_process_observe 2>/dev/null)" || observation='{"state":"unknown","groupState":"unknown"}'; fi
            else
              observation="$(jq -c .owner <<<"$lease" | release_use_process_observe 2>/dev/null)" || observation='{"state":"unknown","groupState":"unknown"}'
            fi
            if jq -e '.state=="gone" and .groupState=="empty"' >/dev/null <<<"$observation"; then
              next="$(jq -c --arg id "$id" '.leases |= map(if .id==$id then .phase="finished" | .finishedReason="reconciled" else . end)' <<<"$next")"; changed=true
            elif jq -e '.state=="unknown" or .groupState=="unknown"' >/dev/null <<<"$observation"; then
              diagnostics="$(jq -c --arg id "$id" '.+[{code:"OBSERVATION_UNKNOWN",id:$id}] | unique_by(.code,.id)' <<<"$diagnostics")"
            fi
          done < <(jq -c '.leases[]' <<<"$next")
        done
        [ "$next" = "$old" ] && { release_use_response ok "$old" '' "$diagnostics"; return 0; }
        next="$(jq -c '.revision += 1' <<<"$next")" ;;
    esac
    [ "$op" = reconcile ] && response_id='' || response_id="${id:-}"
    release_use_write "$root" "$old" "$next" || { release_use_response conflict "$old" "$response_id" '[{"code":"WRITE_CONFLICT"}]'; return 1; }
    release_use_response ok "$next" "$response_id" "$diagnostics"
}

opencode_release_use_acquire_locked() { opencode_release_use_locked "$1" "$(jq -c '.operation="acquire"' <<<"$2")"; }
opencode_release_use_reserve_locked() { opencode_release_use_locked "$1" "$(jq -c '.operation="reserve"' <<<"$2")"; }
opencode_release_use_attach_locked() { opencode_release_use_locked "$1" "$(jq -c '.operation="attach"' <<<"$2")"; }
opencode_release_use_finish_locked() { opencode_release_use_locked "$1" "$(jq -c '.operation="finish"' <<<"$2")"; }
opencode_release_use_reconcile_locked() { opencode_release_use_locked "$1" "$(jq -c '.operation="reconcile"' <<<"$2")"; }
