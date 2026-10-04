#!/usr/bin/env bash
# Contrato ejecutable de las validaciones Terraform locales normalizadas (#1840).
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

make_terraform_double() {
    mkdir -p "$WORK/bin"
cat > "$WORK/bin/terraform" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s' "$PWD" "$#" >> "$TERRAFORM_LOG"
printf '|%s' "$@" >> "$TERRAFORM_LOG"
printf '\n' >> "$TERRAFORM_LOG"
EOF
    chmod +x "$WORK/bin/terraform"
}

source_body() {
    awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$1"
}

run_triplet() {
    local label="$1" source="$2" env="$3" body line command caller log expected count failed_env
    body="$(source_body "$source")"
    log="$WORK/$label.log"
    caller="$WORK/repo con espacios"
    mkdir -p "$caller/infra/environments/$env"
    expected="$caller/infra/environments/$env"
    : > "$log"

    while IFS= read -r line; do
        case "$line" in
            '(cd "infra/environments/'*' && terraform '*')')
                command="${line//<env>/$env}"
                if (cd "$caller" && ENV="$env" TERRAFORM_LOG="$log" PATH="$WORK/bin:$PATH" bash -c "$command" && [ "$PWD" = "$caller" ]); then
                    pass "$label ejecuta $line y conserva el cwd del caller"
                else
                    fail "$label no preserva la ejecucion aislada de $line"
                fi
                ;;
        esac
    done <<< "$body"

    count="$(wc -l < "$log" | tr -d ' ')"
    [ "$count" = 3 ] && pass "$label invoca Terraform tres veces" || fail "$label no invoco Terraform tres veces"
    if [ "$count" = 3 ] && while IFS='|' read -r cwd argv; do [ "$cwd" = "$expected" ]; done < "$log"; then
        pass "$label ejecuta Terraform desde el entorno con espacios"
    else
        fail "$label no preserva el cwd efectivo del entorno"
    fi
    if [ "$(sed -n '1p' "$log" | cut -d'|' -f2-)" = '3|fmt|-recursive|../..' ] && \
       [ "$(sed -n '2p' "$log" | cut -d'|' -f2-)" = '2|init|-backend=false' ] && \
       [ "$(sed -n '3p' "$log" | cut -d'|' -f2-)" = '1|validate' ]; then
        pass "$label conserva argv de fmt, init y validate"
    else
        fail "$label altero argv de Terraform"
    fi

    failed_env='entorno ausente con espacios'
    : > "$log"
    while IFS= read -r line; do
        case "$line" in
            '(cd "infra/environments/'*' && terraform '*')')
                command="${line//<env>/$failed_env}"
                if (cd "$caller" && ENV="$failed_env" TERRAFORM_LOG="$log" PATH="$WORK/bin:$PATH" bash -c "$command" 2>/dev/null); then
                    fail "$label permite ejecutar Terraform tras un cd fallido"
                else
                    pass "$label bloquea Terraform tras el cd fallido de $line"
                fi
                ;;
        esac
    done <<< "$body"
    if [ ! -s "$log" ]; then
        pass "$label no invoca Terraform ante ningun cd fallido"
    else
        fail "$label invoco Terraform despues de un cd fallido"
    fi
}

echo '[fuentes] cwd y argv con doble Terraform'
make_terraform_double
run_triplet seed-secret "$REPO_ROOT/src/published/commands/seed-secret.md" 'dev con espacios'
run_triplet infra-base "$REPO_ROOT/src/published/agents/infra-base-scaffolder.md" 'dev con espacios'
run_triplet apim "$REPO_ROOT/src/published/agents/apim-gateway-scaffolder.md" 'dev con espacios'

echo '[adaptadores] las proyecciones conservan solo la equivalencia de invocacion'
if "$GENERATOR" --check >/dev/null; then pass 'adaptadores publicados regenerados'; else fail 'adaptadores publicados divergen'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
