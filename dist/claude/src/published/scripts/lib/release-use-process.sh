#!/usr/bin/env bash
# Observa identidad de procesos locales registrados. No envia senales, no crea
# archivos y consulta solamente metadata de proceso (MEF-ADR-0031 y 0053).

release_use_process_error() { printf 'ERROR: %s\n' "$1" >&2; return 2; }

release_use_process_sha256() {
    local digest
    if command -v shasum >/dev/null 2>&1; then
        digest="$(shasum -a 256 | awk '{print $1}')" || return 1
    elif command -v sha256sum >/dev/null 2>&1; then
        digest="$(sha256sum | awk '{print $1}')" || return 1
    else
        return 1
    fi
    case "$digest" in *[!0-9a-f]*|'') return 1 ;; esac
    [ "${#digest}" -eq 64 ] || return 1
    printf '%s\n' "$digest"
}

release_use_process_os() { printf '%s\n' "${RELEASE_USE_PROCESS_OS:-$(uname -s)}"; }

release_use_process_read_one() {
    [ -f "$1" ] && [ ! -L "$1" ] && IFS= read -r RELEASE_USE_PROCESS_VALUE < "$1"
}

release_use_process_linux_host() {
    local machine_id_file="${RELEASE_USE_PROCESS_MACHINE_ID_FILE:-/etc/machine-id}" boot_file="${RELEASE_USE_PROCESS_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
    release_use_process_read_one "$machine_id_file" || return 1
    [ -n "$RELEASE_USE_PROCESS_VALUE" ] || return 1
    local fingerprint
    fingerprint="$(printf 'mefisto-release-use-process-host-v1\0%s' "$RELEASE_USE_PROCESS_VALUE" | release_use_process_sha256)" || return 1
    release_use_process_read_one "$boot_file" || return 1
    [ -n "$RELEASE_USE_PROCESS_VALUE" ] || return 1
    jq -cn --arg host "$fingerprint" --arg boot "$RELEASE_USE_PROCESS_VALUE" '{hostFingerprint:$host,bootId:$boot}'
}

release_use_process_macos_host() {
    local uuid boot uuid_file="${RELEASE_USE_PROCESS_IOPLATFORMUUID_FILE:-}" boot_file="${RELEASE_USE_PROCESS_BOOTSESSIONUUID_FILE:-}"
    if [ -n "$uuid_file" ]; then
        release_use_process_read_one "$uuid_file" || return 1
        uuid="$RELEASE_USE_PROCESS_VALUE"
    else
        uuid="$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/ { print $4; exit }')" || return 1
    fi
    if [ -n "$boot_file" ]; then
        release_use_process_read_one "$boot_file" || return 1
        boot="$RELEASE_USE_PROCESS_VALUE"
    else
        boot="$(sysctl -n kern.bootsessionuuid 2>/dev/null)" || return 1
    fi
    [ -n "$uuid" ] && [ -n "$boot" ] || return 1
    local fingerprint
    fingerprint="$(printf 'mefisto-release-use-process-host-v1\0%s' "$uuid" | release_use_process_sha256)" || return 1
    jq -cn --arg host "$fingerprint" --arg boot "$boot" '{hostFingerprint:$host,bootId:$boot}'
}

release_use_process_host() {
    case "$(release_use_process_os)" in
        Linux) release_use_process_linux_host ;;
        Darwin) release_use_process_macos_host ;;
        *) return 1 ;;
    esac
}

# Imprime uid, startToken y pgid para un PID; 1 significa ausente y 2 ambiguo.
release_use_process_linux_pid() {
    local pid="$1" root="${RELEASE_USE_PROCESS_PROC_ROOT:-/proc}" stat_file stat tail uid pgid start
    [ -d "$root" ] && [ ! -L "$root" ] || return 2
    stat_file="$root/$pid/stat"
    [ -e "$stat_file" ] || return 1
    [ -f "$stat_file" ] && [ ! -L "$stat_file" ] || return 2
    stat="$(<"$stat_file")" || return 2
    # El comm puede incluir espacios y parentesis: se elimina hasta el ultimo ") ".
    tail="${stat##*) }"
    [ "$tail" != "$stat" ] || return 2
    set -- $tail
    [ "$#" -ge 20 ] || return 2
    pgid="$3"; start="${20}"
    case "$pgid:$start" in *[!0-9:]*|:*|0:*) return 2 ;; esac
    uid="$(stat -f '%u' "$root/$pid" 2>/dev/null || stat -c '%u' "$root/$pid" 2>/dev/null)" || return 2
    case "$uid" in ''|*[!0-9]*) return 2 ;; esac
    printf '%s\t%s\t%s\n' "$uid" "$start" "$pgid"
}

release_use_process_ps_rows() {
    if [ -n "${RELEASE_USE_PROCESS_PS_ROWS_FILE:-}" ]; then
        [ -f "$RELEASE_USE_PROCESS_PS_ROWS_FILE" ] && [ ! -L "$RELEASE_USE_PROCESS_PS_ROWS_FILE" ] || return 2
        cat "$RELEASE_USE_PROCESS_PS_ROWS_FILE"
    else
        TZ=UTC LC_ALL=C ps -eo pid=,uid=,pgid= 2>/dev/null
    fi
}

release_use_process_macos_pid() {
    local pid="$1" row
    if [ -n "${RELEASE_USE_PROCESS_PS_PID_FILE:-}" ]; then
        [ -f "$RELEASE_USE_PROCESS_PS_PID_FILE" ] && [ ! -L "$RELEASE_USE_PROCESS_PS_PID_FILE" ] || return 2
        row="$(cat "$RELEASE_USE_PROCESS_PS_PID_FILE")"
    else
        row="$(TZ=UTC LC_ALL=C ps -p "$pid" -o uid=,lstart=,pgid= 2>/dev/null)"
    fi
    [ -n "$row" ] || return 1
    # uid + cinco palabras lstart + pgid: no se consulta command ni argv.
    set -- $row
    [ "$#" -eq 7 ] || return 2
    case "$1:$7" in *[!0-9:]*|:*|0:*) return 2 ;; esac
    printf '%s\t%s %s %s %s %s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

release_use_process_pid() {
    case "$(release_use_process_os)" in
        Linux) release_use_process_linux_pid "$1" ;;
        Darwin) release_use_process_macos_pid "$1" ;;
        *) return 2 ;;
    esac
}

release_use_process_group() {
    local pgid="$1" rows
    rows="$(release_use_process_ps_rows)" || return 2
    printf '%s\n' "$rows" | awk -v pgid="$pgid" '
        NF == 0 { next }
        NF != 3 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $1 == 0 || $3 == 0 {
            invalid = 1
            next
        }
        { seen = 1 }
        $3 == pgid { member = 1 }
        END {
            if (invalid || !seen) exit 2
            print member ? "live" : "empty"
        }
    ' || return 2
}

release_use_process_capture() {
    [ "$#" -eq 1 ] || release_use_process_error 'uso: release_use_process_capture <pid>' || return $?
    local pid="$1" host identity row confirmation uid start pgid current_uid
    case "$pid" in ''|*[!0-9]*|0) release_use_process_error 'pid invalido'; return $? ;; esac
    command -v jq >/dev/null 2>&1 || { release_use_process_error 'jq es requerido'; return $?; }
    host="$(release_use_process_host)" || { release_use_process_error 'identidad de host no verificable'; return $?; }
    row="$(release_use_process_pid "$pid")"; case $? in 0) ;; *) release_use_process_error 'metadata de proceso no verificable'; return $? ;; esac
    confirmation="$(release_use_process_pid "$pid")"; case $? in 0) ;; *) release_use_process_error 'captura de proceso inestable'; return $? ;; esac
    [ "$row" = "$confirmation" ] || { release_use_process_error 'captura de proceso inestable'; return $?; }
    IFS=$'\t' read -r uid start pgid <<EOF
$row
EOF
    current_uid="$(id -u)" || { release_use_process_error 'uid actual no verificable'; return $?; }
    [ "$uid" = "$current_uid" ] || { release_use_process_error 'pid no pertenece al usuario actual'; return $?; }
    identity="$(jq -cn --argjson host "$host" --argjson pid "$pid" --arg start "$start" --argjson pgid "$pgid" '$host + {schemaVersion:1,pid:$pid,startToken:$start,pgid:$pgid}')" || { release_use_process_error 'no se pudo serializar identidad'; return $?; }
    printf '%s\n' "$identity"
}

release_use_process_observe() {
    [ "$#" -eq 0 ] || { release_use_process_error 'uso: release_use_process_observe < identidad.json'; return $?; }
    command -v jq >/dev/null 2>&1 || { release_use_process_error 'jq es requerido'; return $?; }
    local identity host expected_host expected_boot pid expected_start pgid row uid start observed_pgid current_uid group state group_state reason
    identity="$(cat)" || { release_use_process_error 'no se pudo leer stdin'; return $?; }
    jq -e 'type == "object" and (keys | sort) == ["bootId","hostFingerprint","pgid","pid","schemaVersion","startToken"] and .schemaVersion == 1 and (.hostFingerprint | type == "string" and test("^[0-9a-f]{64}$")) and (.bootId | type == "string" and length > 0 and contains("\n") | not) and (.pid | type == "number" and floor == . and . > 0) and (.pgid | type == "number" and floor == . and . > 0) and (.startToken | type == "string" and length > 0 and contains("\n") | not)' >/dev/null 2>&1 <<<"$identity" || { release_use_process_error 'identidad invalida'; return $?; }
    expected_host="$(jq -r .hostFingerprint <<<"$identity")"; expected_boot="$(jq -r .bootId <<<"$identity")"; pid="$(jq -r .pid <<<"$identity")"; expected_start="$(jq -r .startToken <<<"$identity")"; pgid="$(jq -r .pgid <<<"$identity")"
    host="$(release_use_process_host)" || { jq -cn '{schemaVersion:1,state:"unknown",groupState:"unknown",reason:"host-unverifiable"}'; return 0; }
    [ "$(jq -r .hostFingerprint <<<"$host")" = "$expected_host" ] || { jq -cn '{schemaVersion:1,state:"unknown",groupState:"unknown",reason:"host-different"}'; return 0; }
    if [ "$(jq -r .bootId <<<"$host")" != "$expected_boot" ]; then
        group="$(release_use_process_group "$pgid")" || group=unknown
        jq -cn --arg group "$group" '{schemaVersion:1,state:"gone",groupState:$group,reason:"reboot"}'
        return 0
    fi
    row="$(release_use_process_pid "$pid")"; case $? in
        0) IFS=$'\t' read -r uid start observed_pgid <<EOF
$row
EOF
           current_uid="$(id -u)" || { jq -cn '{schemaVersion:1,state:"unknown",groupState:"unknown",reason:"uid-unverifiable"}'; return 0; }
           [ "$uid" = "$current_uid" ] && [ "$start" = "$expected_start" ] && { state=live; reason=identity-live; } || { state=gone; reason=pid-reused; } ;;
        1) state=gone; reason=pid-absent ;;
        *) jq -cn '{schemaVersion:1,state:"unknown",groupState:"unknown",reason:"pid-unverifiable"}'; return 0 ;;
    esac
    group="$(release_use_process_group "$pgid")" || { group_state=unknown; jq -cn --arg state "$state" --arg group "$group_state" --arg reason "$reason" '{schemaVersion:1,state:$state,groupState:$group,reason:$reason}'; return 0; }
    jq -cn --arg state "$state" --arg group "$group" --arg reason "$reason" '{schemaVersion:1,state:$state,groupState:$group,reason:$reason}'
}
