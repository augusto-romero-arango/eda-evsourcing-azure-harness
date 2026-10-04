#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUNNER="$ROOT/src/runtime/mefisto-run-agent.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
assert_ok() { if "$@"; then pass; else fail "$*"; fi; }
mkdir -p "$TMP/bin" "$TMP/wt" "$TMP/work"; printf 'prompt\n' > "$TMP/prompt"

cat > "$TMP/bin/opencode" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${MEFISTO_TEST_CLI_ARGS:?}"
if [ "$1" = serve ]; then
  printf 'secret-on-stdout=%s\n' "${OPENCODE_SERVER_PASSWORD:-missing}"
  printf '%s\n' 'listening http://127.0.0.1:43123'
  printf 'secret-on-stderr=%s\n' "${OPENCODE_SERVER_PASSWORD:-missing}" >&2
  [ "${MEFISTO_TEST_SERVE_FAIL:-0}" = 1 ] && exit 7
  trap 'kill "$sleep_pid" 2>/dev/null; wait "$sleep_pid" 2>/dev/null; exit 0' TERM
  sleep 60 & sleep_pid=$!
  wait "$sleep_pid"
elif [ "$1" = run ]; then
  printf '%s' "${OPENCODE_SERVER_PASSWORD:-missing}" > "${MEFISTO_TEST_RUN_PASSWORD:?}"
  printf '%s\n' '{"type":"text","timestamp":1,"sessionID":"s1","part":{"type":"text","text":"ok"}}'
  printf '%s\n' '{"type":"step_finish","timestamp":2,"sessionID":"s1","part":{"type":"step-finish","reason":"stop","tokens":{"input":1,"output":1}}}'
fi
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
args_file="${MEFISTO_TEST_CURL_ARGS:?}"
: > "$args_file"
for arg in "$@"; do printf '%s\n' "$arg" >> "$args_file"; done
cat > "${MEFISTO_TEST_CURL_CONFIG:?}"
printf '%s' "${MEFISTO_TEST_CURL_RESPONSE:-{\"healthy\":true,\"version\":\"stub-1\"}}"
EOF
chmod +x "$TMP/bin/opencode" "$TMP/bin/curl"

PATH="$TMP/bin:$PATH" MEFISTO_TEST_CLI_ARGS="$TMP/cli-args" \
MEFISTO_TEST_CURL_ARGS="$TMP/curl-args" MEFISTO_TEST_CURL_CONFIG="$TMP/curl-config" \
MEFISTO_TEST_RUN_PASSWORD="$TMP/run-password" bash -c '
  MEFISTO_RUNTIME_LIB_DIR="$1/src/runtime/lib"
  source "$1/src/runtime/lib/mefisto-runtime.sh"
  OPENCODE_SERVER_PASSWORD=valor-previo; export OPENCODE_SERVER_PASSWORD
  runtime_service_start opencode "$2/wt" "$2/work" 3 || { printf "start: %s\n" "$MEFISTO_RUNTIME_SERVICE_ERROR" >&2; exit 10; }
  [ "$MEFISTO_RUNTIME_SERVICE_ENDPOINT" = http://127.0.0.1:43123 ] || exit 11
  [ "$MEFISTO_RUNTIME_SERVICE_VERSION" = stub-1 ] || exit 12
  service_password=$MEFISTO_OPENCODE_SERVICE_PASSWORD
  [ "$OPENCODE_SERVER_PASSWORD" = "$service_password" ] || exit 13
  if runtime_service_start opencode "$2/wt" "$2/work" 1; then exit 14; fi
  runtime_service_request opencode GET /agent "$2/work" >/dev/null || exit 15
  if runtime_service_request opencode GET /session/a/abort "$2/work" >/dev/null; then exit 16; fi
  if "$1/src/runtime/mefisto-run-agent.sh" --runtime opencode --agent logical \
      --execution-agent technical --runtime-endpoint http://127.0.0.1:43124 \
      --cwd "$2/wt" --prompt-file "$2/prompt" --event-log "$2/events-wrong" >/dev/null 2>&1; then exit 17; fi
  [ ! -e "$2/run-password" ] || exit 18
  "$1/src/runtime/mefisto-run-agent.sh" --runtime opencode --agent logical \
      --execution-agent technical --runtime-endpoint "$MEFISTO_RUNTIME_SERVICE_ENDPOINT" \
      --cwd "$2/wt" --prompt-file "$2/prompt" --event-log "$2/events" >/dev/null 2>&1 || exit 19
  [ "$(cat "$2/run-password")" = "$service_password" ] || exit 20
  grep -q "secret-on-stdout=\[credencial-redactada\]" "$MEFISTO_OPENCODE_SERVICE_LOG" || exit 21
  if grep -qF "$service_password" "$MEFISTO_OPENCODE_SERVICE_LOG" "$2/cli-args" "$2/events"; then exit 22; fi
  service_log=$MEFISTO_OPENCODE_SERVICE_LOG
  runtime_service_stop opencode || { printf "stop: %s\n" "$MEFISTO_RUNTIME_SERVICE_ERROR" >&2; exit 23; }
  [ "$OPENCODE_SERVER_PASSWORD" = valor-previo ] || exit 24
  [ ! -e "$service_log" ] || exit 25
' _ "$ROOT" "$TMP"
assert_ok test "$?" -eq 0

assert_ok grep -qx -- '--hostname' "$TMP/cli-args"
assert_ok grep -qx -- '127.0.0.1' "$TMP/cli-args"
assert_ok grep -qx -- '--port' "$TMP/cli-args"
assert_ok grep -qx -- '0' "$TMP/cli-args"
assert_ok grep -qx -- '--mdns=false' "$TMP/cli-args"
assert_ok grep -qx -- '--attach' "$TMP/cli-args"
assert_ok grep -qx -- 'technical' "$TMP/cli-args"
assert_ok grep -q '"agent":"logical"' "$TMP/events"
assert_ok grep -qx -- '--max-redirs' "$TMP/curl-args"
assert_ok grep -qx -- '--noproxy' "$TMP/curl-args"
if grep -q 'opencode:' "$TMP/curl-args" "$TMP/cli-args" 2>/dev/null; then fail "credencial en argv"; else pass; fi
assert_ok grep -q 'opencode:' "$TMP/curl-config"

MEFISTO_FAKE_SCRIPT=success "$RUNNER" --runtime fake --agent logical --execution-agent technical --cwd "$TMP/wt" --prompt-file "$TMP/prompt" --event-log "$TMP/events-alias" >/dev/null 2>&1
assert_ok test "$?" -eq 64
MEFISTO_FAKE_SCRIPT=success "$RUNNER" --runtime fake --agent logical --execution-agent '' --runtime-endpoint http://127.0.0.1:9 --cwd "$TMP/wt" --prompt-file "$TMP/prompt" --event-log "$TMP/events-empty" >/dev/null 2>&1
assert_ok test "$?" -eq 64
MEFISTO_FAKE_SCRIPT=success "$RUNNER" --runtime fake --agent logical --runtime-endpoint http://example.test:9 --cwd "$TMP/wt" --prompt-file "$TMP/prompt" --event-log "$TMP/events-remote" >/dev/null 2>&1
assert_ok test "$?" -eq 64

source "$ROOT/src/runtime/lib/runtime-opencode.sh"
for invalid in 'http://127.0.0.1:0' 'http://127.0.0.1:65536' 'http://127.0.0.1:999999999999999999999999999999' 'http://127.0.0.1:80/path' 'http://user@127.0.0.1:80' 'https://127.0.0.1:80'; do
  if runtime_opencode_service_endpoint_is_loopback "$invalid"; then fail "endpoint invalido aceptado: $invalid"; else pass; fi
done
runtime_opencode_service_endpoint_is_loopback 'http://127.0.0.1:9' && pass || fail 'puerto de un digito valido'

# Health invalido y fallo temprano del CLI no dejan un handle reutilizable.
for mode in unhealthy startup-fail; do
  if [ "$mode" = unhealthy ]; then response='{"healthy":false,"version":"stub-1"}'; serve_fail=0; else response='{"healthy":true,"version":"stub-1"}'; serve_fail=1; fi
  PATH="$TMP/bin:$PATH" MEFISTO_RUNTIME_LIB_DIR="$ROOT/src/runtime/lib" MEFISTO_TEST_CLI_ARGS="$TMP/cli-$mode" \
    MEFISTO_TEST_CURL_ARGS="$TMP/curl-$mode" MEFISTO_TEST_CURL_CONFIG="$TMP/config-$mode" MEFISTO_TEST_RUN_PASSWORD="$TMP/run-$mode" \
    MEFISTO_TEST_CURL_RESPONSE="$response" MEFISTO_TEST_SERVE_FAIL="$serve_fail" bash -c '
      source "$1/src/runtime/lib/mefisto-runtime.sh"
      if runtime_service_start opencode "$2/wt" "$2/work" 1; then exit 1; fi
      [ -z "$MEFISTO_RUNTIME_SERVICE_PID" ] && [ -z "$MEFISTO_RUNTIME_SERVICE_RUNTIME" ]
    ' _ "$ROOT" "$TMP"
  assert_ok test "$?" -eq 0
done

# Stop no senala un PID cuya identidad ya no coincide y reap/invalida uno terminado.
bash -c '
  source "$1/src/runtime/lib/runtime-opencode.sh"
  sleep 30 & child=$!
  MEFISTO_RUNTIME_SERVICE_PID=$child; MEFISTO_RUNTIME_SERVICE_IDENTITY=identidad-reciclada
  if runtime_opencode_service_stop; then exit 1; fi
  kill -0 "$child" 2>/dev/null || exit 2
  [ "$MEFISTO_RUNTIME_SERVICE_PID" = "$child" ] || exit 3
  kill "$child"; wait "$child" 2>/dev/null || true
  sleep 0.05 & ended=$!; wait "$ended"
  MEFISTO_RUNTIME_SERVICE_PID=$ended; MEFISTO_RUNTIME_SERVICE_IDENTITY=ya-terminado
  runtime_opencode_service_stop || exit 4
  [ -z "$MEFISTO_RUNTIME_SERVICE_PID" ]
' _ "$ROOT"
assert_ok test "$?" -eq 0

bash -c '
  source "$1/src/runtime/lib/runtime-opencode.sh"
  sleep 30 & child=$!
  MEFISTO_RUNTIME_SERVICE_PID=$child
  MEFISTO_RUNTIME_SERVICE_IDENTITY="$(runtime_opencode_service_identity "$child")"
  kill() { return 1; }
  if runtime_opencode_service_stop; then exit 1; fi
  [ "$MEFISTO_RUNTIME_SERVICE_PID" = "$child" ] || exit 2
  unset -f kill
  command kill "$child"; wait "$child" 2>/dev/null || true
' _ "$ROOT"
assert_ok test "$?" -eq 0

echo "RESULTADO servicio preparado: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
