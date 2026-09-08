#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MODELS="$ROOT/src/runtime/lib/mefisto-models.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

LIBS="$TMP/libs"; mkdir -p "$LIBS"
cat > "$LIBS/runtime-alpha.sh" <<'EOF'
runtime_alpha_default_model() { case "$1" in fast) printf '%s' 'alpha default' ;; balanced|deep) printf '%s' '' ;; *) return 1 ;; esac; }
EOF
cat > "$LIBS/runtime-nodefault.sh" <<'EOF'
runtime_nodefault_is_available() { return 0; }
EOF
MEFISTO_RUNTIME_LIB_DIR="$LIBS"
source "$MODELS"

MAPPING="$TMP/models.json"
cat > "$MAPPING" <<'EOF'
{
  "alpha": {
    "profiles": { "fast": "profile model", "balanced": "balanced model" },
    "agents": { "writer": "agent model with spaces" }
  }
}
EOF

mefisto_resolve_model alpha writer fast 'explicit model with spaces' "$MAPPING" >/dev/null && [ "$MEFISTO_RESOLVED_MODEL" = 'explicit model with spaces' ] && pass || fail "override explicito"
mefisto_resolve_model alpha writer fast '' "$MAPPING" >/dev/null && [ "$MEFISTO_RESOLVED_MODEL" = 'agent model with spaces' ] && pass || fail "mapping por agente"
mefisto_resolve_model alpha reviewer fast '' "$MAPPING" >/dev/null && [ "$MEFISTO_RESOLVED_MODEL" = 'profile model' ] && pass || fail "mapping por perfil"
mefisto_resolve_model alpha reviewer deep '' "$MAPPING" >/dev/null && [ "$MEFISTO_RESOLVED_MODEL" = '' ] && pass || fail "herencia cuando default vacio"
mefisto_resolve_model alpha reviewer fast '' "$TMP/inexistente.json" >/dev/null && [ "$MEFISTO_RESOLVED_MODEL" = 'alpha default' ] && pass || fail "mapping inexistente equivale a ausencia"
mefisto_resolve_model alpha reviewer fast >/dev/null && [ "$MEFISTO_RESOLVED_MODEL" = 'alpha default' ] && pass || fail "mapping omitido equivale a ausencia"
mefisto_resolve_model nodefault writer deep >/dev/null && [ "$MEFISTO_RESOLVED_MODEL" = '' ] && pass || fail "adaptador sin default hereda"

printf '{' > "$TMP/invalido.json"
if mefisto_resolve_model alpha writer fast '' "$TMP/invalido.json" >/dev/null; then fail "JSON invalido debe fallar"; else case "$MEFISTO_MODELS_ERROR" in "$TMP/invalido.json":*JSON*) pass ;; *) fail "error JSON incluye archivo" ;; esac; fi
printf '{"alpha":{"profiles":{"slow":"x"}}}' > "$TMP/forma.json"
if mefisto_resolve_model alpha writer fast '' "$TMP/forma.json" >/dev/null; then fail "forma invalida debe fallar"; else case "$MEFISTO_MODELS_ERROR" in "$TMP/forma.json":*alpha.profiles.slow*) pass ;; *) fail "forma incluye campo" ;; esac; fi
if mefisto_resolve_model alpha writer unknown >/dev/null; then fail "perfil invalido debe fallar"; else pass; fi
if mefisto_resolve_model 'bad-id' writer fast >/dev/null; then fail "runtime invalido debe fallar"; else pass; fi
if mefisto_resolve_model missing writer fast >/dev/null; then fail "adaptador inexistente debe fallar"; else case "$MEFISTO_MODELS_ERROR" in *missing*"$LIBS/runtime-missing.sh"*) pass ;; *) fail "adaptador inexistente incluye ruta" ;; esac; fi

# El fake no depende del cwd ni de estado interno y puede heredar o configurarse.
MEFISTO_RUNTIME_LIB_DIR="$ROOT/src/runtime/lib"
source "$MODELS"
unset MEFISTO_FAKE_DEFAULT_MODEL
(cd "$TMP" && mefisto_resolve_model fake writer balanced >/dev/null) && [ "$MEFISTO_RESOLVED_MODEL" = '' ] && pass || fail "fake hereda sin default"
MEFISTO_FAKE_DEFAULT_MODEL='fake model with spaces'
mefisto_resolve_model fake writer balanced >/dev/null && [ "$MEFISTO_RESOLVED_MODEL" = 'fake model with spaces' ] && pass || fail "fake configurable"

echo "RESULTADO modelos comunes: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
