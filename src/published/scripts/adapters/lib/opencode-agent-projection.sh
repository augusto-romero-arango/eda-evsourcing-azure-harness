#!/usr/bin/env bash
# Compilador de politica por rol para los alias controlados del borde OpenCode
# (#1856). Cargar esta biblioteca no escribe, no toma locks, no invoca el SDK,
# un LLM ni la red: transforma un envelope cerrado (stdin) en la politica
# propia de cada alias, sin tocar los agentes originales ni aplicar config.
# Reutiliza opencode-entry-permissions.jq (#1838) como unico matcher/evaluador
# y el manifest de ejecucion de la propia release (#1853).
# Requiere jq. La logica de composicion vive en opencode-agent-projection.jq.

_oap_hash() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d ' ' -f 1; else sha256sum | cut -d ' ' -f 1; fi
}

_oap_conflict() {
    jq -cn --arg code "$1" '{schemaVersion:1,status:"conflict",admissionScope:"agent-projection",phase:null,catalogDigest:null,resourcesDigest:null,projectionDigest:null,actors:[],entryTaskBindings:{},diagnostics:[{code:$code,subject:"envelope"}]}'
}

# opencode_agent_projection_resolve <release-root>
#
# Envelope (stdin, schemaVersion 1): phase config|verify, profile, snapshot (#1825),
# home, roles, originals, globalPolicy, sessionPolicy, collisions y, opcionales,
# entryTaskPolicies y observed (solo verify). Exit 0 ready, 1 conflicto, 2 protocolo.
opencode_agent_projection_resolve() {
    [ "$#" -eq 1 ] || return 2
    local release_root="$1" inventory man libdir input manifest result digest edig line alias_digest
    libdir="$release_root/src/published/scripts/adapters/lib"
    manifest="$release_root/agent-execution-manifest.json"
    inventory="$release_root/src/published/contract/agent-execution.json"
    [ -f "$libdir/opencode-entry-permissions.jq" ] && [ -f "$libdir/opencode-agent-projection.jq" ] && [ -f "$manifest" ] && [ -f "$inventory" ] || return 2
    jq -e '.schemaVersion == 1 and (.roles | type == "array")' "$manifest" >/dev/null 2>&1 || return 2

    input="$(command cat)" || return 2
    jq -e '
      def optional($k): ($k | IN(["entryTaskPolicies","observed"][]));
      type == "object" and .schemaVersion == 1 and (.phase == "config" or .phase == "verify") and
      ((keys - ["schemaVersion","phase","profile","snapshot","home","roles","originals","globalPolicy","sessionPolicy","collisions","entryTaskPolicies","observed"]) | length == 0) and
      (["schemaVersion","phase","profile","snapshot","home","roles","originals","globalPolicy","sessionPolicy","collisions"] - keys | length == 0) and
      (.profile | type == "object" and (keys | sort) == ["profileDigest","projectId"]) and
      (.home | type == "string") and
      (.roles | type == "array" and length > 0 and all(.[]; type == "object" and (.role | type == "string") and (.taskTargets | type == "array" and all(.[]; type == "string")) and ((keys - ["role","taskTargets","attach"]) | length == 0))) and
      ((.roles | map(.role)) | length == (unique | length)) and
      (.originals | type == "array" and all(.[]; type == "object" and (keys | sort) == ["id","mode","permission","promptHash","tools"])) and
      (.collisions | type == "array" and all(.[]; type == "string")) and
      (.globalPolicy == null or (.globalPolicy | type == "object")) and
      (.sessionPolicy == null or (.sessionPolicy | type == "array")) and
      ((.phase == "verify") == has("observed")) and
      (if has("observed") then (.observed | type == "array" and all(.[]; type == "object" and (keys | sort) == ["available","mode","name","promptHash","rules"])) else true end) and
      (if has("entryTaskPolicies") then (.entryTaskPolicies | type == "array" and all(.[]; type == "object" and (keys | sort) == ["digest","entryId","targets"] and (.targets | type == "array" and all(.[]; type == "string")))) else true end) and
      (.snapshot | type == "object" and .schemaVersion == 1 and .resolutionScope == "resources" and (.resourcesDigest | type == "string") and
        (.resources | type == "array") and (.protectedRoots | type == "array") and (.release.root | type == "string") and (.project.executionRoot | type == "string") and
        all(.resources[]; (.aliases | type == "array") and (.excludedPaths | type == "array") and (.relativeRoot | type == "string") and (.root | type == "string")) and
        all(.protectedRoots[]; (.root | type == "string") and (.exceptions | type == "array")))
    ' >/dev/null 2>&1 <<< "$input" || return 2

    if ! jq -e '.snapshot.status == "ready" and .snapshot.projectId == .profile.projectId and .snapshot.profileDigest == .profile.profileDigest' >/dev/null <<< "$input"; then
        _oap_conflict SNAPSHOT_NOT_READY; return 1
    fi
    if jq -e '.globalPolicy == null' >/dev/null <<< "$input"; then _oap_conflict GLOBAL_POLICY_UNKNOWN; return 1; fi

    # Digest esperado de cada proyeccion de Task de entrada (forma canonica propia).
    edig='{}'
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        alias_digest="$(jq -cS '{entryId:.entryId,targets:(.targets | unique)}' <<< "$line" | tr -d '\n' | _oap_hash)"
        edig="$(jq -c --arg k "$(jq -r .entryId <<< "$line")" --arg d "$alias_digest" '. + {($k):$d}' <<< "$edig")"
    done < <(jq -c '(.entryTaskPolicies // [])[]' <<< "$input")

    man="$(jq -c --slurpfile inv "$inventory" '.roles |= map(. as $r | $r + (($inv[0].roles | map(select(.id == $r.id)) | first) // {}))' "$manifest")" || return 2
    result="$(jq -c -L "$libdir" --argjson man "$man" --argjson edig "$edig" -f "$libdir/opencode-agent-projection.jq" <<< "$input" 2>/dev/null)" || { _oap_conflict PROJECTION_UNAVAILABLE; return 1; }
    jq -e 'type == "object" and .admissionScope == "agent-projection"' >/dev/null 2>&1 <<< "$result" || { _oap_conflict PROJECTION_UNAVAILABLE; return 1; }

    if [ "$(jq -r .status <<< "$result")" = ready ]; then
        digest="$(jq -cS '._digestInput' <<< "$result" | tr -d '\n' | _oap_hash)"
        result="$(jq -c --arg d "$digest" '.projectionDigest = $d' <<< "$result")"
        local observations='[]' obs_hash
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            obs_hash="$(jq -cS '.input' <<< "$line" | tr -d '\n' | _oap_hash)"
            observations="$(jq -c --arg a "$(jq -r .alias <<< "$line")" --arg h "$obs_hash" '. + [{alias:$a,observationDigest:$h}]' <<< "$observations")"
        done < <(jq -c '._observations[]' <<< "$result")
        if [ "$(jq -r .phase <<< "$result")" = verify ]; then
            result="$(jq -c --argjson o "$observations" '.observations = $o' <<< "$result")"
        fi
    fi
    jq -c 'del(._digestInput, ._observations)' <<< "$result"
    [ "$(jq -r .status <<< "$result")" = ready ]
}
