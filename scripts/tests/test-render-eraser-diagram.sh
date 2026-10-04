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
CONSUMER="$WORK/consumer"; mkdir -p "$CONSUMER/.mefisto/pipeline/tmp" "$WORK/bin" "$WORK/outside"
CONSUMER="$(cd -P "$CONSUMER" && pwd)"
git -C "$CONSUMER" init -q
cp "$FIXTURE" "$CONSUMER/.mefisto/pipeline/tmp/payload.json"
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
sentinel='sentinel-eraser-token'
[ -z "${ERASER_API_TOKEN+x}" ] || { printf 'token-heredado\n' > "$FAKE_CURL_TRACE"; exit 89; }
expected=(
  --disable --silent --show-error --fail --proto '=https'
  --connect-timeout 5 --max-time 60 --max-redirs 0
  --request POST --url 'https://app.eraser.io/api/render/elements'
  --header 'Content-Type: application/json' --header 'X-Skill-Source: mefisto'
  --data-binary "@$EXPECTED_PAYLOAD" --config -
)
[ "$#" -eq "${#expected[@]}" ] || { printf 'argc:%s/%s\n' "$#" "${#expected[@]}" > "$FAKE_CURL_TRACE"; exit 90; }
actual=("$@")
for index in "${!expected[@]}"; do
  case "${actual[$index]}" in *"$sentinel"*) printf 'token-en-argv\n' > "$FAKE_CURL_TRACE"; exit 91 ;; esac
  [ "${actual[$index]}" = "${expected[$index]}" ] || { printf 'argv-distinto:%s\n' "$index" > "$FAKE_CURL_TRACE"; exit 93; }
done
config="$(cat)"
expected_config="header = \"Authorization: Bearer $sentinel\""
[ "$config" = "$expected_config" ] || { printf 'config-invalida\n' > "$FAKE_CURL_TRACE"; exit 92; }
jq -S . "${EXPECTED_PAYLOAD}" > "${FAKE_CURL_TRACE}.actual-payload"
jq -S . "${EXPECTED_FIXTURE}" > "${FAKE_CURL_TRACE}.expected-payload"
cmp -s "${FAKE_CURL_TRACE}.actual-payload" "${FAKE_CURL_TRACE}.expected-payload" || { printf 'payload-distinto\n' > "$FAKE_CURL_TRACE"; exit 94; }
calls=0; [ ! -f "$FAKE_CURL_CALLS" ] || calls="$(< "$FAKE_CURL_CALLS")"
printf '%s\n' "$((calls + 1))" > "$FAKE_CURL_CALLS"
printf '%s\n' 'channel=config endpoint=fixed payload=data-binary redirects=disabled' > "$FAKE_CURL_TRACE"
case "${FAKE_CURL_MODE:-success}" in
  success) printf '%s\n' '{"imageUrl":"https://image.example/diagram.png","createEraserFileUrl":"https://app.eraser.io/file/1","ignored":"private"}' ;;
  http) printf '%s\n' '{"providerError":"raw-sensitive-body"}'; exit 22 ;;
  timeout) printf '%s\n' 'raw-sensitive-transport-error' >&2; exit 28 ;;
  incomplete) printf '%s\n' '{"imageUrl":"https://image.example/diagram.png","providerDetail":"raw-sensitive-body"}' ;;
esac
EOF
chmod +x "$WORK/bin/curl"
run() {
    local mode="$1" payload="$2" expected_fixture="${3:-$FIXTURE}" output rc
    output="$(cd "$CONSUMER" && PATH="$WORK/bin:$PATH" ERASER_API_TOKEN='sentinel-eraser-token' FAKE_CURL_MODE="$mode" FAKE_CURL_TRACE="$WORK/curl.trace" FAKE_CURL_CALLS="$WORK/curl.calls" EXPECTED_PAYLOAD="$CONSUMER/.mefisto/pipeline/tmp/payload.json" EXPECTED_FIXTURE="$expected_fixture" bash "$SCRIPT" --payload-file "$payload" 2>&1)"; rc=$?
    RUN_OUTPUT="$output"; RUN_RC="$rc"
}
curl_calls() { if [ -f "$WORK/curl.calls" ]; then printf '%s' "$(< "$WORK/curl.calls")"; else printf '0'; fi; }

run success .mefisto/pipeline/tmp/payload.json
[ "$(curl_calls)" -eq 1 ] && pass 'hace un unico POST con endpoint, payload, timeouts y redirects acotados' || fail 'invocacion de transporte inesperada'
[ "$RUN_RC" -eq 0 ] && printf '%s' "$RUN_OUTPUT" | jq -e '.imageUrl and .createEraserFileUrl and (has("ignored") | not)' >/dev/null && pass 'exito devuelve solo los enlaces requeridos' || fail "exito devuelve enlaces sanitizados: $RUN_OUTPUT"
trace="$(< "$WORK/curl.trace")"
[ "$trace" = 'channel=config endpoint=fixed payload=data-binary redirects=disabled' ] && [ ! -e "$WORK/consumer/.mefisto/pipeline/tmp"/*token* ] && ! printf '%s' "$RUN_OUTPUT" | grep -q 'sentinel-eraser-token' && ! grep -R -q 'sentinel-eraser-token' "$WORK/consumer" "$WORK/curl.trace"* 2>/dev/null && pass 'token usa stdin/config sin aparecer en argv, salida ni archivos de trabajo' || fail "token expuesto fuera del canal de header: $trace"

calls_before="$(curl_calls)"
env -u ERASER_API_TOKEN PATH="$WORK/bin:$PATH" FAKE_CURL_MODE=success FAKE_CURL_TRACE="$WORK/curl.trace" FAKE_CURL_CALLS="$WORK/curl.calls" EXPECTED_PAYLOAD="$CONSUMER/.mefisto/pipeline/tmp/payload.json" EXPECTED_FIXTURE="$FIXTURE" bash -c 'cd "$1" && bash "$2" --payload-file .mefisto/pipeline/tmp/payload.json' _ "$CONSUMER" "$SCRIPT" >"$WORK/missing.out" 2>&1; missing_rc=$?
[ "$missing_rc" -ne 0 ] && grep -q 'falta ERASER_API_TOKEN' "$WORK/missing.out" && [ "$(curl_calls)" = "$calls_before" ] && pass 'token ausente aborta antes de red' || fail 'token ausente no aborta correctamente'

printf '%s\n' '{"elements":[]}' > "$CONSUMER/.mefisto/pipeline/tmp/invalid.json"
run success .mefisto/pipeline/tmp/invalid.json
[ "$RUN_RC" -ne 0 ] && printf '%s' "$RUN_OUTPUT" | grep -q 'contrato esperado' && [ "$(curl_calls)" = "$calls_before" ] && pass 'payload invalido aborta antes de red' || fail 'payload invalido no aborta correctamente'

cp "$FIXTURE" "$WORK/outside/payload.json"
ln -s "$WORK/outside/payload.json" "$CONSUMER/.mefisto/pipeline/tmp/linked.json"
run success .mefisto/pipeline/tmp/linked.json
[ "$RUN_RC" -ne 0 ] && [ "$(curl_calls)" = "$calls_before" ] && pass 'rechaza un payload symlink antes de red' || fail 'siguio un payload symlink'
ln -s "$WORK/outside" "$CONSUMER/.mefisto/pipeline/tmp/escaped"
run success .mefisto/pipeline/tmp/escaped/payload.json
[ "$RUN_RC" -ne 0 ] && [ "$(curl_calls)" = "$calls_before" ] && pass 'rechaza un directorio symlink que escapa del arbol temporal' || fail 'siguio un directorio symlink fuera del arbol temporal'

for diagram_type in sequence-diagram cloud-architecture-diagram flowchart-diagram entity-relationship-diagram bpmn-diagram; do
    jq --arg type "$diagram_type" '.elements[0].diagramType = $type' "$FIXTURE" > "$CONSUMER/.mefisto/pipeline/tmp/payload.json"
    run success .mefisto/pipeline/tmp/payload.json "$CONSUMER/.mefisto/pipeline/tmp/payload.json"
    [ "$RUN_RC" -eq 0 ] && pass "acepta $diagram_type" || fail "rechaza $diagram_type: $RUN_OUTPUT"
done

for mode in http timeout incomplete; do
    cp "$FIXTURE" "$CONSUMER/.mefisto/pipeline/tmp/payload.json"
    run "$mode" .mefisto/pipeline/tmp/payload.json
    [ "$RUN_RC" -ne 0 ] && ! printf '%s' "$RUN_OUTPUT" | grep -Eq 'sentinel-eraser-token|raw-sensitive' && pass "$mode produce diagnostico sanitizado" || fail "$mode no falla de forma sanitizada: $RUN_OUTPUT"
done

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
