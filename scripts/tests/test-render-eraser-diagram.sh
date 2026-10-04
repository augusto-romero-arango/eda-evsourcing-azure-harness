#!/usr/bin/env bash
# Contrato aislado del renderizador Eraser: no usa red ni credenciales reales.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/render-eraser-diagram.sh"
FIXTURE="$HERE/fixtures/render-eraser-diagram/valid-payload.json"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CONSUMER="$WORK/consumer"; mkdir -p "$CONSUMER/.mefisto/pipeline/tmp" "$WORK/bin"
git -C "$CONSUMER" init -q
cp "$FIXTURE" "$CONSUMER/.mefisto/pipeline/tmp/payload.json"
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
sentinel='sentinel-eraser-token'
for arg in "$@"; do [ "$arg" != "$sentinel" ] || exit 91; done
config="$(cat)"
case "$config" in *"header = \"Authorization: Bearer $sentinel\""*) ;; *) printf '%s\n' 'invalid-config' > "$FAKE_CURL_TRACE"; exit 92 ;; esac
printf '%s\n' 'channel=config endpoint=fixed payload=data-binary' > "$FAKE_CURL_TRACE"
case "${FAKE_CURL_MODE:-success}" in
  success) printf '%s\n' '{"imageUrl":"https://image.example/diagram.png","createEraserFileUrl":"https://app.eraser.io/file/1","ignored":"private"}' ;;
  http) exit 22 ;;
  timeout) exit 28 ;;
  incomplete) printf '%s\n' '{"imageUrl":"https://image.example/diagram.png"}' ;;
esac
EOF
chmod +x "$WORK/bin/curl"
run() {
    local mode="$1" payload="$2" output rc
    output="$(cd "$CONSUMER" && PATH="$WORK/bin:$PATH" ERASER_API_TOKEN='sentinel-eraser-token' FAKE_CURL_MODE="$mode" FAKE_CURL_TRACE="$WORK/curl.trace" bash "$SCRIPT" --payload-file "$payload" 2>&1)"; rc=$?
    RUN_OUTPUT="$output"; RUN_RC="$rc"
}

run success .mefisto/pipeline/tmp/payload.json
[ "$(grep -c -- '--url "$ENDPOINT"' "$SCRIPT")" -eq 1 ] && grep -q -- '--request POST' "$SCRIPT" && grep -q -- '--connect-timeout 5' "$SCRIPT" && grep -q -- '--max-time 60' "$SCRIPT" && grep -q -- '--data-binary "@$payload"' "$SCRIPT" && grep -q -- '--config -' "$SCRIPT" && pass 'usa endpoint fijo, POST, timeout y payload como datos' || fail 'contrato de transporte incompleto'
[ "$RUN_RC" -eq 0 ] && printf '%s' "$RUN_OUTPUT" | jq -e '.imageUrl and .createEraserFileUrl and (has("ignored") | not)' >/dev/null && pass 'exito devuelve solo los enlaces requeridos' || fail "exito devuelve enlaces sanitizados: $RUN_OUTPUT"
trace="$(< "$WORK/curl.trace")"
[ "$trace" = 'channel=config endpoint=fixed payload=data-binary' ] && [ ! -e "$WORK/consumer/.mefisto/pipeline/tmp"/*token* ] && ! printf '%s' "$RUN_OUTPUT" | grep -q 'sentinel-eraser-token' && ! grep -R -q 'sentinel-eraser-token' "$WORK/consumer" "$WORK/curl.trace" 2>/dev/null && pass 'token usa el canal de header sin aparecer en salida ni archivos de trabajo' || fail "token expuesto fuera del canal de header: $trace"

env -u ERASER_API_TOKEN bash -c 'cd "$1" && bash "$2" --payload-file .mefisto/pipeline/tmp/payload.json' _ "$CONSUMER" "$SCRIPT" >"$WORK/missing.out" 2>&1; missing_rc=$?
[ "$missing_rc" -ne 0 ] && grep -q 'falta ERASER_API_TOKEN' "$WORK/missing.out" && pass 'token ausente aborta antes de red' || fail 'token ausente no aborta correctamente'

printf '%s\n' '{"elements":[]}' > "$CONSUMER/.mefisto/pipeline/tmp/invalid.json"
run success .mefisto/pipeline/tmp/invalid.json
[ "$RUN_RC" -ne 0 ] && printf '%s' "$RUN_OUTPUT" | grep -q 'contrato esperado' && pass 'payload invalido aborta antes de red' || fail 'payload invalido no aborta correctamente'

for mode in http timeout incomplete; do
    run "$mode" .mefisto/pipeline/tmp/payload.json
    [ "$RUN_RC" -ne 0 ] && ! printf '%s' "$RUN_OUTPUT" | grep -q 'sentinel-eraser-token' && pass "$mode produce diagnostico sanitizado" || fail "$mode no falla de forma sanitizada"
done

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
