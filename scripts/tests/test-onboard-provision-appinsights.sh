#!/usr/bin/env bash
# test-onboard-provision-appinsights.sh -- provision de .mefisto/appinsights.env (issue #2387), con 'az' falso.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/onboard-provision-appinsights.sh"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq no instalado"; exit 0; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# az falso: controlado por FAKE_AZ_LOGIN, FAKE_RG, FAKE_AI, FAKE_SB, FAKE_FUNCS (listas separadas por espacio).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/az" <<'AZ'
#!/usr/bin/env bash
case "$1 $2" in
    "account show") [ "${FAKE_AZ_LOGIN:-1}" = "1" ]; exit $? ;;
    "group show") [ "$4" = "${FAKE_RG:-}" ]; exit $? ;;
    "resource list")
        case "$*" in
            *Microsoft.Insights/components*) list="${FAKE_AI:-}" ;;
            *Microsoft.ServiceBus/namespaces*) list="${FAKE_SB:-}" ;;
            *Microsoft.Web/sites*) list="${FAKE_FUNCS:-}" ;;
            *) list="" ;;
        esac
        for n in $list; do echo "$n"; done; exit 0 ;;
esac
exit 1
AZ
chmod +x "$TMP/bin/az"

make_repo() {
    local repo="$1"; mkdir -p "$repo/.mefisto"; (cd "$repo" && git init -q)
    cat > "$repo/.mefisto/harness.config.json" <<'JSON'
{"projectName":"Proyecto","namespacePrefix":"Empresa.Proyecto","solutionFile":"Proyecto.slnx","domainLabels":["ventas"],"infraResourceGroupPrefix":"rg-proy","boundedContext":{"name":"Principal","domains":["ventas"]}}
JSON
}
run() { local repo="$1"; shift; (cd "$repo" && PATH="$TMP/bin:$PATH" MEFISTO_RUNTIME=claude bash "$SCRIPT" "$@") 2>&1; }
export FAKE_AZ_LOGIN=1 FAKE_RG="rg-proy-dev" FAKE_AI="appi-proy" FAKE_SB="sb-proy" FAKE_FUNCS="func-ventas-x func-cobros-x"

echo "[P-1] preview (y sin flags) no escribe e imprime las cinco claves"
R="$TMP/r1"; make_repo "$R"
for args in "--preview" ""; do
    OUT=$(run "$R" $args); RC=$?
    if [ "$RC" -eq 0 ] && [ ! -e "$R/.mefisto/appinsights.env" ] \
        && printf '%s\n' "$OUT" | grep -Fxq 'APPINSIGHTS_APP=appi-proy' \
        && printf '%s\n' "$OUT" | grep -Fxq 'APPINSIGHTS_RG=rg-proy-dev' \
        && printf '%s\n' "$OUT" | grep -Fxq 'SERVICEBUS_NAMESPACE=sb-proy' \
        && printf '%s\n' "$OUT" | grep -Fxq 'SERVICEBUS_RG=rg-proy-dev' \
        && printf '%s\n' "$OUT" | grep -Fxq 'FUNCTIONAPP_NAMES=func-cobros-x,func-ventas-x'; then
        pass "preview '${args:-<sin flags>}' imprime claves ordenadas y no escribe"
    else fail "preview '${args:-<sin flags>}' (rc=$RC): $OUT"; fi
done

echo "[P-2] apply crea el archivo y no sobrescribe"
OUT=$(run "$R" --apply); RC=$?
F="$R/.mefisto/appinsights.env"
if [ "$RC" -eq 0 ] && [ "$(grep -c '^[A-Z_]*=' "$F")" -eq 5 ] && grep -Fxq 'FUNCTIONAPP_NAMES=func-cobros-x,func-ventas-x' "$F" && head -1 "$F" | grep -q '^#'; then pass "apply escribe cabecera y cinco claves"; else fail "apply (rc=$RC): $OUT"; fi
BEFORE=$(cksum "$F"); OUT=$(run "$R" --apply); RC=$?
if [ "$RC" -ne 0 ] && [ "$BEFORE" = "$(cksum "$F")" ] && printf '%s' "$OUT" | grep -Fq 'a mano'; then pass "apply sobre archivo existente falla sin tocarlo"; else fail "apply existente (rc=$RC): $OUT"; fi

echo "[P-3] fallas sin escribir"
R="$TMP/r3"; make_repo "$R"
check_fail() { # nombre patron args...
    local name="$1" pat="$2"; shift 2
    local OUT RC; OUT=$(run "$R" "$@"); RC=$?
    if [ "$RC" -ne 0 ] && [ ! -e "$R/.mefisto/appinsights.env" ] && printf '%s' "$OUT" | grep -Fq -- "$pat"; then pass "$name"; else fail "$name (rc=$RC): $OUT"; fi
}
FAKE_AZ_LOGIN=0 check_fail "sin sesion de az" "sesion activa" --apply
FAKE_RG="otro" check_fail "sin resource group" "no se encontro el resource group" --apply
FAKE_AI="" check_fail "cero App Insights" "ningun App Insights" --apply
FAKE_SB="" check_fail "cero namespaces" "ningun namespace" --apply
FAKE_AI="appi-a appi-b" check_fail "ambiguedad de App Insights lista candidatos" "- appi-b" --apply
FAKE_SB="sb-a sb-b" check_fail "ambiguedad de namespace lista candidatos" "- sb-b" --apply
FAKE_AI="appi-a appi-b" check_fail "flag fuera de candidatos" "no esta entre los candidatos" --apply --appinsights-app appi-z
# sin az en PATH: solo git y jq enlazados sobre el PATH base del sistema.
mkdir -p "$TMP/noaz"
for b in git jq; do ln -sf "$(command -v "$b")" "$TMP/noaz/$b"; done
if [ -x /usr/bin/az ] || [ -x /bin/az ]; then
    pass "sin az: omitido (az del sistema en el PATH base)"
else
    OUT=$(cd "$R" && PATH="$TMP/noaz:/usr/bin:/bin" bash "$SCRIPT" --apply 2>&1); RC=$?
    if [ "$RC" -ne 0 ] && [ ! -e "$R/.mefisto/appinsights.env" ] && printf '%s' "$OUT" | grep -Fq "'az' no esta instalado"; then
        pass "sin az aborta nombrando la causa y sin escribir"
    else fail "sin az (rc=$RC): $OUT"; fi
fi

echo "[P-4] flag valido desambigua y cero Function Apps no aborta"
OUT=$(FAKE_AI="appi-a appi-b" FAKE_FUNCS="" run "$R" --apply --appinsights-app appi-b); RC=$?
if [ "$RC" -eq 0 ] && grep -Fxq 'APPINSIGHTS_APP=appi-b' "$R/.mefisto/appinsights.env" && grep -Fxq 'FUNCTIONAPP_NAMES=' "$R/.mefisto/appinsights.env" && printf '%s' "$OUT" | grep -Fq 'AVISO'; then pass "flag elegido y FUNCTIONAPP_NAMES vacio con aviso"; else fail "desambiguacion (rc=$RC): $OUT"; fi

echo "[P-5] --env y guard de Mefisto"
R="$TMP/r5"; make_repo "$R"
OUT=$(FAKE_RG="rg-proy-qa" run "$R" --env qa); RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Fq 'APPINSIGHTS_RG=rg-proy-qa'; then pass "--env resuelve el RG del entorno"; else fail "--env (rc=$RC): $OUT"; fi
R="$TMP/mef"; make_repo "$R"; mkdir -p "$R/.claude-plugin"; echo '{}' > "$R/.claude-plugin/plugin.json"
OUT=$(run "$R" --preview); RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -Fq 'solo aplica al consumidor'; then pass "guard cwd != Mefisto"; else fail "guard (rc=$RC): $OUT"; fi

echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
