#!/usr/bin/env bash
# Pruebas con dobles de metadata; nunca consultan procesos ajenos reales.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
LIB="$REPO_ROOT/src/published/scripts/lib/release-use-process.sh"
FIXTURES="$HERE/fixtures/release-use-process"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_json() { printf '%s' "$1" | jq -e "$2" >/dev/null 2>&1 && pass "$3" || fail "$3"; }

source "$LIB"
mkdir -p "$WORK/proc/4242"
cp "$FIXTURES/linux-stat-with-comm" "$WORK/proc/4242/stat"
printf 'machine-id-de-prueba\n' > "$WORK/machine-id"
printf 'boot-a\n' > "$WORK/boot-id"
printf '4242 %s 4242\n' "$(id -u)" > "$WORK/ps-rows"
export RELEASE_USE_PROCESS_OS=Linux RELEASE_USE_PROCESS_PROC_ROOT="$WORK/proc"
export RELEASE_USE_PROCESS_MACHINE_ID_FILE="$WORK/machine-id" RELEASE_USE_PROCESS_BOOT_ID_FILE="$WORK/boot-id"
export RELEASE_USE_PROCESS_PS_ROWS_FILE="$WORK/ps-rows"

printf '[pre] sintaxis y contrato\n'
bash -n "$LIB" && pass 'biblioteca Bash valida' || fail 'biblioteca Bash invalida'
IDENTITY="$(release_use_process_capture 4242)" || IDENTITY=''
assert_json "$IDENTITY" '.schemaVersion == 1 and .pid == 4242 and .startToken == "777" and .pgid == 4242 and (.hostFingerprint | test("^[0-9a-f]{64}$"))' 'captura Linux parsea comm con espacios y parentesis sin filtrar valor crudo'
OUT="$(printf '%s' "$IDENTITY" | release_use_process_observe)"
assert_json "$OUT" '.state == "live" and .groupState == "live" and .reason == "identity-live"' 'misma identidad y PGID vivo permanecen live'

rm "$WORK/proc/4242/stat"
printf '1 %s 1\n' "$(id -u)" > "$WORK/ps-rows"
OUT="$(printf '%s' "$IDENTITY" | release_use_process_observe)"
assert_json "$OUT" '.state == "gone" and .groupState == "empty" and .reason == "pid-absent"' 'PID ausente y grupo vacio se distinguen'
printf '9999 %s 4242\n' "$(id -u)" > "$WORK/ps-rows"
OUT="$(printf '%s' "$IDENTITY" | release_use_process_observe)"
assert_json "$OUT" '.state == "gone" and .groupState == "live"' 'sobreviviente del PGID conserva groupState live'

cp "$FIXTURES/linux-stat-with-comm" "$WORK/proc/4242/stat"
STAT="$(<"$WORK/proc/4242/stat")"
printf '%s\n' "${STAT/ 777 0 0 0/ 778 0 0 0}" > "$WORK/proc/4242/stat"
OUT="$(printf '%s' "$IDENTITY" | release_use_process_observe)"
assert_json "$OUT" '.state == "gone" and .reason == "pid-reused"' 'token de inicio distinto prueba PID reutilizado'

cp "$FIXTURES/linux-stat-with-comm" "$WORK/proc/4242/stat"
OUT="$(printf '%s' "$IDENTITY" | release_use_process_observe)"
assert_json "$OUT" '.state == "live"' 'misma precision observable conserva una posible colision como retencion'
rm "$WORK/ps-rows"
OUT="$(printf '%s' "$IDENTITY" | release_use_process_observe)"
assert_json "$OUT" '.state == "live" and .groupState == "unknown"' 'error al observar grupo no se convierte en empty'
printf 'metadata-incompleta\n' > "$WORK/proc/4242/stat"
OUT="$(printf '%s' "$IDENTITY" | release_use_process_observe)"
assert_json "$OUT" '.state == "unknown" and .groupState == "unknown" and .reason == "pid-unverifiable"' 'error al observar PID no se convierte en gone ni empty'
cp "$FIXTURES/linux-stat-with-comm" "$WORK/proc/4242/stat"

printf 'machine-id-otro\n' > "$WORK/machine-id"
OUT="$(printf '%s' "$IDENTITY" | release_use_process_observe)"
assert_json "$OUT" '.state == "unknown" and .groupState == "unknown" and .reason == "host-different"' 'host diferente no extrapola evidencia'
printf 'machine-id-de-prueba\n' > "$WORK/machine-id"
printf 'boot-b\n' > "$WORK/boot-id"
printf '9999 %s 4242\n' "$(id -u)" > "$WORK/ps-rows"
OUT="$(printf '%s' "$IDENTITY" | release_use_process_observe)"
assert_json "$OUT" '.state == "gone" and .groupState == "live" and .reason == "reboot"' 'reboot termina el propietario pero un PGID reutilizado permanece live'
printf 'sentinela-argv-env\n' > "$WORK/ps-rows"
OUT="$(printf '%s' "$IDENTITY" | release_use_process_observe)"
assert_json "$OUT" '.state == "gone" and .groupState == "unknown" and .reason == "reboot"' 'error de grupo tras reboot tampoco se convierte en empty'
printf '1 %s 1\n' "$(id -u)" > "$WORK/ps-rows"
OUT="$(printf '%s' "$IDENTITY" | release_use_process_observe)"
assert_json "$OUT" '.state == "gone" and .groupState == "empty" and .reason == "reboot"' 'reboot y observacion completa permiten declarar vacio el PGID'
rm "$WORK/boot-id"
OUT="$(printf '%s' "$IDENTITY" | release_use_process_observe)"
assert_json "$OUT" '.state == "unknown" and .reason == "host-unverifiable"' 'host desconocido conserva unknown'

printf 'sentinela-argv-env\n' > "$WORK/boot-id"
BAD='{ "schemaVersion": 1, "pid": 1 }'
printf '%s' "$BAD" | release_use_process_observe > "$WORK/stdout" 2>"$WORK/stderr"; RC=$?
[ "$RC" -eq 2 ] && [ ! -s "$WORK/stdout" ] && ! grep -q 'sentinela-argv-env' "$WORK/stderr" && pass 'protocolo invalido no contamina stdout ni expone centinelas' || fail 'protocolo invalido debe ser sanitizado'

printf 'boot-a\n' > "$WORK/boot-id"
printf 'sentinela-argv-env\n' > "$WORK/ps-rows"
OUT="$(printf '%s' "$IDENTITY" | release_use_process_observe 2>"$WORK/stderr")"
assert_json "$OUT" '.state == "live" and .groupState == "unknown"' 'snapshot de grupo malformado nunca se convierte en empty'
if [[ "$OUT" != *sentinela-argv-env* ]] && ! grep -q 'sentinela-argv-env' "$WORK/stderr"; then
    pass 'fallo de metadata no filtra el centinela por stdout ni stderr'
else
    fail 'fallo de metadata expuso el centinela'
fi

export RELEASE_USE_PROCESS_OS=Darwin RELEASE_USE_PROCESS_IOPLATFORMUUID_FILE="$WORK/platform-uuid" RELEASE_USE_PROCESS_BOOTSESSIONUUID_FILE="$WORK/boot-session" RELEASE_USE_PROCESS_PS_PID_FILE="$WORK/macos-pid" RELEASE_USE_PROCESS_PS_ROWS_FILE="$WORK/macos-rows"
printf 'uuid-de-prueba\n' > "$WORK/platform-uuid"; printf 'mac-boot\n' > "$WORK/boot-session"
read -r _ a b c d e _ < "$FIXTURES/macos-pid-stable"
printf '%s %s %s %s %s %s %s\n' "$(id -u)" "$a" "$b" "$c" "$d" "$e" 4242 > "$WORK/macos-pid"
printf '4242 %s 4242\n' "$(id -u)" > "$WORK/macos-rows"
MAC_IDENTITY="$(release_use_process_capture 4242)" || MAC_IDENTITY=''
MAC_OUT="$(printf '%s' "$MAC_IDENTITY" | release_use_process_observe)"
assert_json "$MAC_OUT" '.state == "live" and .groupState == "live"' 'lstart macOS estable conserva identidad sin decimales'
# La salida no expone startToken; se comprueba contra la identidad capturada.
assert_json "$MAC_IDENTITY" '.startToken == "Mon Jan 2 03:04:05 2023"' 'captura macOS conserva exactamente lstart estable'

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
