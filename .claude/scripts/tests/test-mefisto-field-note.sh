#!/usr/bin/env bash
# test-mefisto-field-note.sh -- Tests del pipeline de entrega idempotente y
# recuperable de field notes (issues #1295/#1299).
#
# Cubre:
#   [pre] mefisto-field-note.sh vive en src/internal/scripts/ con sintaxis
#         bash valida; su shim en .claude/scripts/ sigue la plantilla exacta
#         de exec de 3 lineas (R4) y reenvia de verdad; el gate de
#         neutralidad (mefisto-neutrality-gate.sh) sale 0 sobre el repo real.
#   [A]   Validacion de argumentos (CA-1): --agent/--session-id con '/', '..'
#         o espacios, --timestamp mal formado y argumentos faltantes abortan
#         (exit != 0) SIN tocar git -- ni worktree ni rama se crean.
#   [B]   Guard de regresion estatico (CA-4): el script canonico nunca invoca
#         'git switch'/'git add'/'git commit' contra MEFISTO_REPO_ROOT.
#   [C]   Primera entrega end-to-end (CA-2/CA-3/CA-4) sobre un repo Git
#         temporal con checkout principal SUCIO, un remote BARE real y un
#         'gh' controlado que emite ruido en stderr incluso al tener exito
#         (como el gh real): se confirma la llamada real a 'gh pr create' (el
#         defecto original -- @tsv emitiendo tabuladores para el PR nulo, que
#         '[ -n "$PR_DATA" ]' tomaba como PR existente -- queda corregido),
#         unico path entregado (docs/bitacora/field-notes/...), URL de PR sin
#         ruido de stderr pegado, checkout principal sin cambios (ref/sha/
#         status identicos, incluido el archivo sucio preexistente) y
#         worktree temporal limpiado.
#   [D]   Reintento tras push exitoso (CA-1): 'gh pr create' falla una vez
#         (simula el proceso muerto justo despues del push); la segunda
#         invocacion con los MISMOS flags reutiliza la rama y el commit (un
#         solo commit en todo el remote bare) y crea el PR una unica vez.
#   [E]   PR abierto preexistente se reutiliza sin llamar a 'gh pr create'
#         (CA-2).
#   [F]   PR cerrado SIN merge se reabre via 'gh pr reopen' (CA-2).
#   [G]   PR ya MERGEADO se considera entregado: no llama ni a 'gh pr create'
#         ni a 'gh pr reopen' (CA-2, distingue de un CLOSED sin merge).
#   [H]   Un fallo recuperable por checkpoint (CA-3): worktree (fetch remoto
#         roto), commit (gpg.program invalido), push (hook pre-receive que
#         rechaza 'docs/*'), consulta-pr ('gh pr list' con exit 1),
#         reapertura-pr ('gh pr reopen' con exit 1) y creacion-pr
#         ('gh pr create' con exit 1). Cada uno verifica exit != 0, mensaje
#         con el checkpoint confirmado y una accion concreta, y que el
#         checkout principal (CA-4) sigue intacto pese al abort.
#
# Uso: .claude/scripts/tests/test-mefisto-field-note.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

CANON="$REPO_ROOT/src/internal/scripts/mefisto-field-note.sh"
SHIM="$REPO_ROOT/.claude/scripts/mefisto-field-note.sh"
CANON_LIB="$REPO_ROOT/src/internal/scripts/lib/_mefisto-common.sh"
CANON_STATE_LIB="$REPO_ROOT/src/internal/scripts/lib/mefisto-state.sh"
CANON_RUNTIME="$REPO_ROOT/src/runtime"
GATE="$REPO_ROOT/src/internal/scripts/mefisto-neutrality-gate.sh"

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

SAFE_SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
REPO_SLUG="acme/mefisto-fake"

# --- Helpers compartidos por los bloques C..H -------------------------------

# new_repo <prefijo>
#
# Crea bajo $TMP/<prefijo> un checkout principal ($REPO_MAIN) con el script
# canonico + sus libs copiados adentro, y un remote bare real ($REPO_BARE) ya
# con 'main' empujado. Deja ambas rutas en variables globales (no en un
# subshell) para que cada bloque las use tal cual.
new_repo() {
    local prefix="$1"
    REPO_MAIN="$TMP/$prefix/main-checkout"
    REPO_BARE="$TMP/$prefix/origin.git"
    mkdir -p "$REPO_MAIN"
    git init -q "$REPO_MAIN"
    git -C "$REPO_MAIN" symbolic-ref HEAD refs/heads/main
    git -C "$REPO_MAIN" config user.email "test@mefisto.local"
    git -C "$REPO_MAIN" config user.name "Mefisto Test"

    mkdir -p "$REPO_MAIN/.claude-plugin" "$REPO_MAIN/src/internal/scripts/lib"
    cat > "$REPO_MAIN/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "mefisto",
  "version": "0.0.0"
}
EOF
    # Espeja el .gitignore real (.mefisto/ ignorado): sin esto, el worktree
    # scratch bajo .mefisto/pipeline/summaries/ que un fallo preserva a
    # proposito (CA-3) aparece como untracked en el checkout principal
    # SINTETICO y dispara un falso positivo de CA-4 que el repo real nunca ve.
    echo ".mefisto/" > "$REPO_MAIN/.gitignore"
    cp "$CANON_LIB" "$REPO_MAIN/src/internal/scripts/lib/_mefisto-common.sh"
    cp "$CANON_STATE_LIB" "$REPO_MAIN/src/internal/scripts/lib/mefisto-state.sh"
    cp -R "$CANON_RUNTIME" "$REPO_MAIN/src/runtime"
    cp "$CANON" "$REPO_MAIN/src/internal/scripts/mefisto-field-note.sh"
    chmod +x "$REPO_MAIN/src/internal/scripts/mefisto-field-note.sh"

    git -C "$REPO_MAIN" add .
    git -C "$REPO_MAIN" commit -q -m "base"

    git init -q --bare "$REPO_BARE"
    git -C "$REPO_MAIN" remote add origin "$REPO_BARE"
    git -C "$REPO_MAIN" push -q origin main
}

# run_field_note <fakebin> <agent> <timestamp> <session_id> <content> <out> <err>
#
# Invoca el script canonico dentro de $REPO_MAIN con PATH restringido a
# <fakebin>:$SAFE_SYSTEM_PATH (solo el stub de 'gh' controlado por el test mas
# el sistema base -- ningun 'gh' real instalado en la maquina interfiere).
# Imprime el exit code por stdout de la funcion (capturable con `rc=$(...)`) y
# deja stdout/stderr del script en los archivos indicados.
run_field_note() {
    local fakebin="$1" agent="$2" ts="$3" sess="$4" content="$5" out="$6" err="$7"
    (
        cd "$REPO_MAIN" && \
        printf '%s\n' "$content" | \
        env -u MEFISTO_STATE_DIR -u MEFISTO_LEGACY_STATE_DIR -u MEFISTO_REPO_ROOT \
            -u MEFISTO_PROJECT_NAME -u MEFISTO_REPO_SLUG \
            PATH="$fakebin:$SAFE_SYSTEM_PATH" \
            ./src/internal/scripts/mefisto-field-note.sh \
                --agent "$agent" --timestamp "$ts" --session-id "$sess"
    ) >"$out" 2>"$err"
    echo $?
}

# write_pr_store_gh <fakebin> <call_log> <store_file>
#
# Escribe en <fakebin>/gh un stub de 'gh' con un almacen de PRs PERSISTENTE
# (<store_file>, TSV: number|url|state|mergedAt|head|base) que 'pr list',
# 'pr create' y 'pr reopen' leen y mutan como lo haria GitHub de verdad --
# necesario para que un PR creado por una invocacion aparezca como existente
# en la siguiente (bloques D/E/F/G, que ejercitan los 3 estados de un PR de
# sesiones previas). Cada llamada a gh se anota en <call_log> para que los
# tests verifiquen cuantas veces (y con que subcomando) se invoco.
write_pr_store_gh() {
    local fakebin="$1" call_log="$2" store="$3"
    mkdir -p "$fakebin"
    : > "$store"
    cat > "$fakebin/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$call_log"

get_opt() {
    local want="\$1"; shift
    local i=1
    for a in "\$@"; do
        i=\$((i+1))
        if [ "\$a" = "\$want" ]; then
            eval "echo \\"\\\${\$i}\\""
            return 0
        fi
    done
    echo ""
}

if [ "\$1" = "repo" ] && [ "\$2" = "view" ]; then
    if printf '%s\n' "\$@" | grep -q "nameWithOwner"; then
        echo "$REPO_SLUG"
        exit 0
    fi
    if printf '%s\n' "\$@" | grep -q "defaultBranchRef"; then
        echo "aviso de gh: hay una version mas nueva disponible" >&2
        echo "main"
        exit 0
    fi
    exit 1
fi

if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
    head=\$(get_opt --head "\$@")
    base=\$(get_opt --base "\$@")
    row=\$(awk -F'\t' -v h="\$head" -v b="\$base" '\$5 == h && \$6 == b { print; exit }' "$store" 2>/dev/null)
    if [ -z "\$row" ]; then
        echo "[]"
        exit 0
    fi
    IFS=\$'\t' read -r num url state mergedat rhead rbase <<< "\$row"
    if [ "\$mergedat" = "-" ]; then mergedat_json="null"; else mergedat_json="\"\$mergedat\""; fi
    printf '[{"number":%s,"url":"%s","state":"%s","mergedAt":%s}]\n' "\$num" "\$url" "\$state" "\$mergedat_json"
    exit 0
fi

if [ "\$1" = "pr" ] && [ "\$2" = "create" ]; then
    head=\$(get_opt --head "\$@")
    base=\$(get_opt --base "\$@")
    num=\$(( \$(wc -l < "$store" 2>/dev/null || echo 0) + 1 ))
    url="https://github.com/$REPO_SLUG/pull/\$num"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "\$num" "\$url" "OPEN" "-" "\$head" "\$base" >> "$store"
    echo "Creating pull request for \$head into \$base in $REPO_SLUG" >&2
    echo "\$url"
    exit 0
fi

if [ "\$1" = "pr" ] && [ "\$2" = "reopen" ]; then
    url=""
    for a in "\$@"; do
        case "\$a" in http*) url="\$a" ;; esac
    done
    tmp="$store.tmp"
    awk -F'\t' -v u="\$url" 'BEGIN{OFS="\t"} { if (\$2 == u) { \$3 = "OPEN"; \$4 = "-" } print }' "$store" > "\$tmp" && mv "\$tmp" "$store"
    exit 0
fi

exit 1
EOF
    chmod +x "$fakebin/gh"
}

# seed_pr_store_row <store> <number> <url> <state> <merged_at> <head> <base>
#
# Precarga <store> con una fila de PR ya existente (para los bloques E/F/G,
# que no necesitan pasar por 'pr create' para llegar al estado que quieren
# probar). <merged_at> "-" representa NULL (sin merge).
seed_pr_store_row() {
    local store="$1" num="$2" url="$3" state="$4" merged_at="$5" head="$6" base="$7"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$num" "$url" "$state" "$merged_at" "$head" "$base" >> "$store"
}

# -------- Bloque pre: presencia, sintaxis, shim conforme, gate real --------

echo "[pre] mefisto-field-note.sh y su shim existen, con sintaxis valida"
for f in "$CANON" "$SHIM"; do
    if [ -f "$f" ]; then
        pass "$(basename "$f") ($f): presente"
    else
        fail "$f: ausente"
    fi
    if bash -n "$f" 2>/dev/null; then
        pass "$(basename "$f") ($f): sintaxis bash valida"
    else
        fail "$(basename "$f") ($f): sintaxis bash invalida"
    fi
done

if [ -x "$CANON" ] && [ -x "$SHIM" ]; then
    pass "canonico y shim tienen bit de ejecucion"
else
    fail "canonico o shim sin bit de ejecucion"
fi

EXPECTED_SHIM='#!/usr/bin/env bash
# Shim de compatibilidad (MEF-ADR-0049): la implementacion canonica vive en src/internal/scripts/. No editar.
exec "$(cd "$(dirname "$0")/../.." && pwd)/src/internal/scripts/$(basename "$0")" "$@"'

if printf '%s\n' "$EXPECTED_SHIM" | cmp -s - "$SHIM"; then
    pass "shim: byte a byte igual a la plantilla R4 de src/internal/scripts/README.md"
else
    fail "shim: no coincide byte a byte con la plantilla R4"
fi

# El shim reenvia de verdad: se invoca sin argumentos (camino inocuo -- solo
# imprime 'usage' y sale con error, sin tocar disco ni red) y se compara el
# exit code observado entre shim y canonico.
( cd "$REPO_ROOT" && "$SHIM" ) </dev/null >/dev/null 2>&1; SHIM_RC=$?
( cd "$REPO_ROOT" && "$CANON" ) </dev/null >/dev/null 2>&1; CANON_RC=$?
if [ "$SHIM_RC" -ne 0 ] && [ "$SHIM_RC" -eq "$CANON_RC" ]; then
    pass "shim: reenvia al canonico (ambos exit $SHIM_RC sin argumentos obligatorios)"
else
    fail "shim: shim exit $SHIM_RC, canonico exit $CANON_RC (se esperaba el mismo exit != 0 en ambos)"
fi

echo ""
echo "[pre] mefisto-neutrality-gate.sh sale 0 sobre el repo real"
if GATE_OUT=$(bash "$GATE" 2>&1); then
    pass "mefisto-neutrality-gate.sh: exit 0"
else
    fail "mefisto-neutrality-gate.sh: exit != 0 -- $GATE_OUT"
fi

# -------- Bloque A: validacion de argumentos, sin tocar git (CA-1) --------

echo ""
echo "[A] Validacion de argumentos (CA-1): abortan SIN tocar git"

ARGTEST_DIR="$TMP/argtest"
mkdir -p "$ARGTEST_DIR"

run_argtest() {
    # cwd SIN repo git: si la validacion tocara git antes de rechazar el
    # valor, fallaria de otra forma (p. ej. "no estas en un repositorio git")
    # en vez del mensaje de validacion esperado.
    ( cd "$ARGTEST_DIR" && printf 'contenido\n' | "$CANON" "$@" ) >"$TMP/argtest.out" 2>"$TMP/argtest.err"
    ARGTEST_RC=$?
}

run_argtest
if [ "$ARGTEST_RC" -ne 0 ] && grep -qF "son obligatorios" "$TMP/argtest.err"; then
    pass "sin argumentos: aborta (rc=$ARGTEST_RC) pidiendo los tres obligatorios"
else
    fail "sin argumentos: se esperaba abort pidiendo los obligatorios, rc=$ARGTEST_RC, stderr=$(cat "$TMP/argtest.err")"
fi

run_argtest --agent "../evil" --timestamp "2026-09-13-1530" --session-id "abc123"
if [ "$ARGTEST_RC" -ne 0 ] && grep -qF "invalido" "$TMP/argtest.err"; then
    pass "--agent con '..': aborta (rc=$ARGTEST_RC) sin tocar git"
else
    fail "--agent con '..': se esperaba abort, rc=$ARGTEST_RC, stderr=$(cat "$TMP/argtest.err")"
fi

run_argtest --agent "a/b" --timestamp "2026-09-13-1530" --session-id "abc123"
if [ "$ARGTEST_RC" -ne 0 ]; then
    pass "--agent con '/': aborta (rc=$ARGTEST_RC)"
else
    fail "--agent con '/': deberia abortar, rc=$ARGTEST_RC"
fi

run_argtest --agent "mefisto-planner" --timestamp "2026-09-13-1530" --session-id "sesion con espacios"
if [ "$ARGTEST_RC" -ne 0 ]; then
    pass "--session-id con espacios: aborta (rc=$ARGTEST_RC)"
else
    fail "--session-id con espacios: deberia abortar, rc=$ARGTEST_RC"
fi

run_argtest --agent "-mefisto-planner" --timestamp "2026-09-13-1530" --session-id "abc123"
if [ "$ARGTEST_RC" -ne 0 ]; then
    pass "--agent que empieza con '-': aborta (rc=$ARGTEST_RC)"
else
    fail "--agent que empieza con '-': deberia abortar, rc=$ARGTEST_RC"
fi

run_argtest --agent "mefisto-planner" --timestamp "13-09-2026" --session-id "abc123"
if [ "$ARGTEST_RC" -ne 0 ] && grep -qF "YYYY-MM-DD-HHMM" "$TMP/argtest.err"; then
    pass "--timestamp mal formado: aborta (rc=$ARGTEST_RC) indicando el formato esperado"
else
    fail "--timestamp mal formado: se esperaba abort, rc=$ARGTEST_RC, stderr=$(cat "$TMP/argtest.err")"
fi

if [ -z "$(find "$ARGTEST_DIR" -mindepth 1 2>/dev/null)" ]; then
    pass "ningun caso de validacion toco el sistema de archivos (directorio de prueba sigue vacio)"
else
    fail "algun caso de validacion escribio en el directorio de prueba: $(find "$ARGTEST_DIR" -mindepth 1)"
fi

# -------- Bloque B: guard de regresion estatico (CA-4) --------

echo ""
echo "[B] Guard de regresion (CA-4): el canonico nunca muta el checkout principal"

for needle in 'MEFISTO_REPO_ROOT" switch' 'MEFISTO_REPO_ROOT" add' 'MEFISTO_REPO_ROOT" commit'; do
    hits=$(grep -c "$needle" "$CANON" || true)
    if [ "$hits" -eq 0 ]; then
        pass "cero ocurrencias de '$needle' en mefisto-field-note.sh"
    else
        fail "$hits ocurrencia(s) de '$needle' en mefisto-field-note.sh"
        grep -n "$needle" "$CANON"
    fi
done

# -------- Bloque C: primera entrega end-to-end (CA-2/CA-3/CA-4) --------

echo ""
echo "[C] Primera entrega end-to-end: checkout sucio + remote bare + gh controlado"

new_repo "c"

# Checkout principal SUCIO: un cambio sin commitear que debe sobrevivir intacto.
echo "trabajo en progreso" >> "$REPO_MAIN/README-local.md"
DIRTY_STATUS_BEFORE=$(git -C "$REPO_MAIN" status --porcelain=v1 --untracked-files=all)
DIRTY_CONTENT_BEFORE=$(cat "$REPO_MAIN/README-local.md")
REF_BEFORE=$(git -C "$REPO_MAIN" symbolic-ref -q --short HEAD)
SHA_BEFORE=$(git -C "$REPO_MAIN" rev-parse HEAD)

FAKE_BIN_C="$TMP/c/bin"
mkdir -p "$FAKE_BIN_C"
GH_CALL_LOG_C="$TMP/c/gh-calls.log"
: > "$GH_CALL_LOG_C"
PR_URL_ESPERADA="https://github.com/acme/mefisto-fake/pull/123"
# El stub emite ruido en stderr AUNQUE tenga exito, igual que el gh real: `gh
# pr create` escribe "Creating pull request for ... into ..." en stderr y solo
# la URL en stdout, y cualquier subcomando puede anadir avisos (token por
# expirar, version nueva). Es deliberado: un `2>&1` en el script canonico
# convertiria DEFAULT_BRANCH y PR_URL en valores multilinea corruptos, y ese
# defecto tiene que hacer fallar esta suite, no pasar desapercibido.
cat > "$FAKE_BIN_C/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$GH_CALL_LOG_C"
if [ "\$1" = "repo" ] && [ "\$2" = "view" ]; then
    if printf '%s\n' "\$@" | grep -q "nameWithOwner"; then
        echo "acme/mefisto-fake"
        exit 0
    fi
    if printf '%s\n' "\$@" | grep -q "defaultBranchRef"; then
        echo "aviso de gh: hay una version mas nueva disponible" >&2
        echo "main"
        exit 0
    fi
    exit 1
fi
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
    echo "[]"
    exit 0
fi
if [ "\$1" = "pr" ] && [ "\$2" = "create" ]; then
    echo "Creating pull request for DOC_BRANCH into main in acme/mefisto-fake" >&2
    echo "$PR_URL_ESPERADA"
    exit 0
fi
exit 1
EOF
chmod +x "$FAKE_BIN_C/gh"

AGENT_C="mefisto-planner"
TIMESTAMP_C="2026-09-13-1530"
SESSION_ID_C="2026-09-13-1530-07-abc123def456-99999"
CONTENT_C='---
fecha: 2026-09-13
tema: prueba
---

## Contexto
Prueba de entrega aislada.'

C_RC=$(run_field_note "$FAKE_BIN_C" "$AGENT_C" "$TIMESTAMP_C" "$SESSION_ID_C" "$CONTENT_C" "$TMP/c-stdout" "$TMP/c-stderr")

if [ "$C_RC" -eq 0 ]; then
    pass "primera entrega: exit 0"
else
    fail "primera entrega: exit $C_RC. stdout=$(cat "$TMP/c-stdout") stderr=$(cat "$TMP/c-stderr")"
fi

# Regresion de contaminacion por stderr: con `2>&1` en el `gh pr create` del
# canonico, esta linea traeria pegado el "Creating pull request for ..." del
# stub. Y si el `gh repo view --json defaultBranchRef` lo fusionara, el aviso
# se habria colado en DEFAULT_BRANCH y la entrega entera habria abortado en el
# `git fetch origin "<aviso>...main"` de mas arriba.
REPORTED_PR_LINE=$(grep '^PR: ' "$TMP/c-stdout" || true)
if [ "$REPORTED_PR_LINE" = "PR: $PR_URL_ESPERADA" ]; then
    pass "la URL reportada es exactamente la de stdout de gh, sin ruido de stderr"
else
    fail "URL de PR contaminada o ausente: se esperaba 'PR: $PR_URL_ESPERADA', se obtuvo '$REPORTED_PR_LINE'. stdout completo: $(cat "$TMP/c-stdout")"
fi

if grep -qE '^pr create ' "$GH_CALL_LOG_C"; then
    pass "CA-3: 'gh pr create' SI se ejecuto (defecto de @tsv/tabuladores corregido)"
else
    fail "CA-3: 'gh pr create' nunca se ejecuto. Llamadas a gh: $(cat "$GH_CALL_LOG_C")"
fi

DOC_BRANCH_C="docs/${AGENT_C}-field-note-${SESSION_ID_C}"
FIELD_NOTE_REL_C="docs/bitacora/field-notes/${TIMESTAMP_C}-${AGENT_C}.md"

if git --git-dir="$REPO_BARE" show-ref --verify --quiet "refs/heads/$DOC_BRANCH_C"; then
    pass "CA-3: la rama '$DOC_BRANCH_C' fue empujada al remote bare"
else
    fail "CA-3: la rama '$DOC_BRANCH_C' NO existe en el remote bare"
fi

CHANGED_PATHS_C=$(git --git-dir="$REPO_BARE" diff --name-only main "$DOC_BRANCH_C" 2>/dev/null)
if [ "$CHANGED_PATHS_C" = "$FIELD_NOTE_REL_C" ]; then
    pass "CA-2: unico path entregado: '$FIELD_NOTE_REL_C'"
else
    fail "CA-2: se esperaba solo '$FIELD_NOTE_REL_C', se obtuvo: $CHANGED_PATHS_C"
fi

if git --git-dir="$REPO_BARE" cat-file -e "$DOC_BRANCH_C:$FIELD_NOTE_REL_C" 2>/dev/null; then
    pass "CA-2: la field note existe en el commit empujado al remote bare"
else
    fail "CA-2: la field note no existe en '$DOC_BRANCH_C:$FIELD_NOTE_REL_C' del remote bare"
fi

REF_AFTER=$(git -C "$REPO_MAIN" symbolic-ref -q --short HEAD)
SHA_AFTER=$(git -C "$REPO_MAIN" rev-parse HEAD)
STATUS_AFTER=$(git -C "$REPO_MAIN" status --porcelain=v1 --untracked-files=all)
CONTENT_AFTER=$(cat "$REPO_MAIN/README-local.md")

if [ "$REF_AFTER" = "$REF_BEFORE" ] && [ "$SHA_AFTER" = "$SHA_BEFORE" ] && [ "$STATUS_AFTER" = "$DIRTY_STATUS_BEFORE" ]; then
    pass "CA-4: el checkout principal quedo identico (ref/sha/status) al medido antes de la entrega"
else
    fail "CA-4: el checkout principal cambio. ref: '$REF_BEFORE'->'$REF_AFTER', sha: '$SHA_BEFORE'->'$SHA_AFTER', status: '$DIRTY_STATUS_BEFORE' -> '$STATUS_AFTER'"
fi

if [ "$CONTENT_AFTER" = "$DIRTY_CONTENT_BEFORE" ]; then
    pass "CA-4: el archivo sucio preexistente conserva su contenido"
else
    fail "CA-4: el archivo sucio preexistente cambio de contenido"
fi

WORKTREE_LIST_AFTER=$(git -C "$REPO_MAIN" worktree list)
if ! printf '%s\n' "$WORKTREE_LIST_AFTER" | grep -q "field-note-"; then
    pass "CA-4: el worktree temporal fue limpiado"
else
    fail "CA-4: quedo un worktree temporal registrado: $WORKTREE_LIST_AFTER"
fi

# -------- Bloque D: reintento tras push exitoso, sin PR aun (CA-1) --------

echo ""
echo "[D] Reintento tras push exitoso: reusa rama/commit, crea el PR una sola vez"

new_repo "d"

FAKE_BIN_D_FAIL="$TMP/d/bin-fail"
FAKE_BIN_D_OK="$TMP/d/bin-ok"
GH_CALL_LOG_D1="$TMP/d/gh-calls-1.log"
GH_CALL_LOG_D2="$TMP/d/gh-calls-2.log"
STORE_D="$TMP/d/pr-store.tsv"
: > "$GH_CALL_LOG_D1"
: > "$GH_CALL_LOG_D2"

write_pr_store_gh "$FAKE_BIN_D_OK" "$GH_CALL_LOG_D2" "$STORE_D"

# Primera corrida: mismo store, pero 'gh pr create' falla (simula el proceso
# muerto justo despues de empujar la rama, antes de que el PR exista).
mkdir -p "$FAKE_BIN_D_FAIL"
cp "$FAKE_BIN_D_OK/gh" "$FAKE_BIN_D_FAIL/gh"
cat > "$FAKE_BIN_D_FAIL/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$GH_CALL_LOG_D1"
if [ "\$1" = "repo" ] && [ "\$2" = "view" ]; then
    if printf '%s\n' "\$@" | grep -q "nameWithOwner"; then echo "$REPO_SLUG"; exit 0; fi
    if printf '%s\n' "\$@" | grep -q "defaultBranchRef"; then echo "main"; exit 0; fi
    exit 1
fi
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then echo "[]"; exit 0; fi
if [ "\$1" = "pr" ] && [ "\$2" = "create" ]; then echo "gh: fallo simulado de red" >&2; exit 1; fi
exit 1
EOF
chmod +x "$FAKE_BIN_D_FAIL/gh"

AGENT_D="mefisto-planner"
TIMESTAMP_D="2026-09-13-1600"
SESSION_ID_D="2026-09-13-1600-01-retry-11111"
CONTENT_D='---
fecha: 2026-09-13
tema: retry
---
## Contexto
Prueba de reintento tras push.'

D1_RC=$(run_field_note "$FAKE_BIN_D_FAIL" "$AGENT_D" "$TIMESTAMP_D" "$SESSION_ID_D" "$CONTENT_D" "$TMP/d1-stdout" "$TMP/d1-stderr")
if [ "$D1_RC" -ne 0 ] && grep -qF "creacion-pr" "$TMP/d1-stderr" && grep -qF "Ultimo checkpoint confirmado: push" "$TMP/d1-stderr"; then
    pass "primer intento: aborta en creacion-pr con checkpoint 'push' confirmado"
else
    fail "primer intento: se esperaba abort en creacion-pr con checkpoint push, rc=$D1_RC, stderr=$(cat "$TMP/d1-stderr")"
fi

DOC_BRANCH_D="docs/${AGENT_D}-field-note-${SESSION_ID_D}"
if git --git-dir="$REPO_BARE" show-ref --verify --quiet "refs/heads/$DOC_BRANCH_D"; then
    pass "primer intento: la rama '$DOC_BRANCH_D' quedo empujada en origin pese al fallo del PR"
else
    fail "primer intento: la rama '$DOC_BRANCH_D' no llego a origin"
fi

D2_RC=$(run_field_note "$FAKE_BIN_D_OK" "$AGENT_D" "$TIMESTAMP_D" "$SESSION_ID_D" "$CONTENT_D" "$TMP/d2-stdout" "$TMP/d2-stderr")
if [ "$D2_RC" -eq 0 ]; then
    pass "segundo intento (mismos flags): exit 0"
else
    fail "segundo intento: exit $D2_RC. stdout=$(cat "$TMP/d2-stdout") stderr=$(cat "$TMP/d2-stderr")"
fi

if grep -qF "Commit ya existente" "$TMP/d2-stdout"; then
    pass "CA-1: el segundo intento reutilizo el commit existente (no creo uno nuevo)"
else
    fail "CA-1: el segundo intento no reporto reuso de commit. stdout: $(cat "$TMP/d2-stdout")"
fi

BARE_COMMIT_COUNT_D=$(git --git-dir="$REPO_BARE" rev-list --count "$DOC_BRANCH_D")
MAIN_COMMIT_COUNT_D=$(git --git-dir="$REPO_BARE" rev-list --count main)
EXPECTED_D=$((MAIN_COMMIT_COUNT_D + 1))
if [ "$BARE_COMMIT_COUNT_D" -eq "$EXPECTED_D" ]; then
    pass "CA-1: '$DOC_BRANCH_D' tiene exactamente un commit sobre main (no se duplico)"
else
    fail "CA-1: se esperaban $EXPECTED_D commits en '$DOC_BRANCH_D', hay $BARE_COMMIT_COUNT_D"
fi

PR_CREATE_CALLS_D=$(grep -cE '^pr create ' "$GH_CALL_LOG_D2" || true)
if [ "$PR_CREATE_CALLS_D" -eq 1 ]; then
    pass "CA-1: 'gh pr create' se llamo exactamente una vez en el segundo intento"
else
    fail "CA-1: se esperaba 1 llamada a 'gh pr create' en el segundo intento, hubo $PR_CREATE_CALLS_D"
fi

# -------- Bloque E: PR abierto preexistente se reutiliza (CA-2) --------

echo ""
echo "[E] PR abierto preexistente: se reutiliza sin llamar a 'gh pr create'"

new_repo "e"
FAKE_BIN_E="$TMP/e/bin"
GH_CALL_LOG_E="$TMP/e/gh-calls.log"
STORE_E="$TMP/e/pr-store.tsv"
: > "$GH_CALL_LOG_E"
write_pr_store_gh "$FAKE_BIN_E" "$GH_CALL_LOG_E" "$STORE_E"

AGENT_E="mefisto-planner"
TIMESTAMP_E="2026-09-13-1700"
SESSION_ID_E="2026-09-13-1700-01-open-22222"
DOC_BRANCH_E="docs/${AGENT_E}-field-note-${SESSION_ID_E}"
FIELD_NOTE_REL_E="docs/bitacora/field-notes/${TIMESTAMP_E}-${AGENT_E}.md"
CONTENT_E='## Contexto
PR abierto preexistente.'

# Rama ya commiteada y empujada de una "sesion previa" (se arma a mano, sin
# pasar por el script, para no depender de que 'gh' ya sepa nada del PR).
git -C "$REPO_MAIN" worktree add -q -b "$DOC_BRANCH_E" "$TMP/e/prep-wt" origin/main
mkdir -p "$(dirname "$TMP/e/prep-wt/$FIELD_NOTE_REL_E")"
printf '%s\n' "$CONTENT_E" > "$TMP/e/prep-wt/$FIELD_NOTE_REL_E"
git -C "$TMP/e/prep-wt" add -- "$FIELD_NOTE_REL_E"
git -C "$TMP/e/prep-wt" commit -q -m "docs(bitacora): agregar field note de $AGENT_E"
git -C "$TMP/e/prep-wt" push -q -u origin "$DOC_BRANCH_E"
git -C "$REPO_MAIN" worktree remove "$TMP/e/prep-wt"

PR_URL_E="https://github.com/$REPO_SLUG/pull/7"
seed_pr_store_row "$STORE_E" 7 "$PR_URL_E" "OPEN" "-" "$DOC_BRANCH_E" "main"

E_RC=$(run_field_note "$FAKE_BIN_E" "$AGENT_E" "$TIMESTAMP_E" "$SESSION_ID_E" "$CONTENT_E" "$TMP/e-stdout" "$TMP/e-stderr")
if [ "$E_RC" -eq 0 ]; then
    pass "PR abierto: exit 0"
else
    fail "PR abierto: exit $E_RC. stdout=$(cat "$TMP/e-stdout") stderr=$(cat "$TMP/e-stderr")"
fi

if grep -qF "PR ya existente reutilizado" "$TMP/e-stdout"; then
    pass "CA-2: reporta PR abierto reutilizado"
else
    fail "CA-2: no reporto reuso de PR abierto. stdout: $(cat "$TMP/e-stdout")"
fi

if grep -q '^PR: '"$PR_URL_E"'$' "$TMP/e-stdout"; then
    pass "CA-2: la URL reportada es la del PR abierto preexistente"
else
    fail "CA-2: URL de PR incorrecta. stdout: $(cat "$TMP/e-stdout")"
fi

if grep -qE '^pr create ' "$GH_CALL_LOG_E"; then
    fail "CA-2: 'gh pr create' NO deberia haberse llamado con un PR abierto ya existente"
else
    pass "CA-2: 'gh pr create' no se llamo (PR abierto reutilizado)"
fi

# -------- Bloque F: PR cerrado SIN merge se reabre (CA-2) --------

echo ""
echo "[F] PR cerrado sin merge: se reabre via 'gh pr reopen'"

new_repo "f"
FAKE_BIN_F="$TMP/f/bin"
GH_CALL_LOG_F="$TMP/f/gh-calls.log"
STORE_F="$TMP/f/pr-store.tsv"
: > "$GH_CALL_LOG_F"
write_pr_store_gh "$FAKE_BIN_F" "$GH_CALL_LOG_F" "$STORE_F"

AGENT_F="mefisto-planner"
TIMESTAMP_F="2026-09-13-1800"
SESSION_ID_F="2026-09-13-1800-01-closed-33333"
DOC_BRANCH_F="docs/${AGENT_F}-field-note-${SESSION_ID_F}"
FIELD_NOTE_REL_F="docs/bitacora/field-notes/${TIMESTAMP_F}-${AGENT_F}.md"
CONTENT_F='## Contexto
PR cerrado sin merge.'

git -C "$REPO_MAIN" worktree add -q -b "$DOC_BRANCH_F" "$TMP/f/prep-wt" origin/main
mkdir -p "$(dirname "$TMP/f/prep-wt/$FIELD_NOTE_REL_F")"
printf '%s\n' "$CONTENT_F" > "$TMP/f/prep-wt/$FIELD_NOTE_REL_F"
git -C "$TMP/f/prep-wt" add -- "$FIELD_NOTE_REL_F"
git -C "$TMP/f/prep-wt" commit -q -m "docs(bitacora): agregar field note de $AGENT_F"
git -C "$TMP/f/prep-wt" push -q -u origin "$DOC_BRANCH_F"
git -C "$REPO_MAIN" worktree remove "$TMP/f/prep-wt"

PR_URL_F="https://github.com/$REPO_SLUG/pull/8"
seed_pr_store_row "$STORE_F" 8 "$PR_URL_F" "CLOSED" "-" "$DOC_BRANCH_F" "main"

F_RC=$(run_field_note "$FAKE_BIN_F" "$AGENT_F" "$TIMESTAMP_F" "$SESSION_ID_F" "$CONTENT_F" "$TMP/f-stdout" "$TMP/f-stderr")
if [ "$F_RC" -eq 0 ]; then
    pass "PR cerrado sin merge: exit 0"
else
    fail "PR cerrado sin merge: exit $F_RC. stdout=$(cat "$TMP/f-stdout") stderr=$(cat "$TMP/f-stderr")"
fi

if grep -qE '^pr reopen ' "$GH_CALL_LOG_F"; then
    pass "CA-2: 'gh pr reopen' se llamo para el PR cerrado sin merge"
else
    fail "CA-2: 'gh pr reopen' nunca se llamo. Llamadas: $(cat "$GH_CALL_LOG_F")"
fi

if grep -qF "reabierto" "$TMP/f-stdout"; then
    pass "CA-2: reporta la reapertura del PR"
else
    fail "CA-2: no reporto la reapertura. stdout: $(cat "$TMP/f-stdout")"
fi

STORE_STATE_F=$(awk -F'\t' -v u="$PR_URL_F" '$2==u {print $3}' "$STORE_F")
if [ "$STORE_STATE_F" = "OPEN" ]; then
    pass "CA-2: el PR quedo en estado OPEN tras la reapertura"
else
    fail "CA-2: el PR deberia quedar OPEN tras reabrirse, quedo '$STORE_STATE_F'"
fi

# -------- Bloque G: PR ya MERGEADO se considera entregado (CA-2) --------

echo ""
echo "[G] PR ya mergeado: se considera entregado, sin 'gh pr create' ni 'gh pr reopen'"

new_repo "g"
FAKE_BIN_G="$TMP/g/bin"
GH_CALL_LOG_G="$TMP/g/gh-calls.log"
STORE_G="$TMP/g/pr-store.tsv"
: > "$GH_CALL_LOG_G"
write_pr_store_gh "$FAKE_BIN_G" "$GH_CALL_LOG_G" "$STORE_G"

AGENT_G="mefisto-planner"
TIMESTAMP_G="2026-09-13-1900"
SESSION_ID_G="2026-09-13-1900-01-merged-44444"
DOC_BRANCH_G="docs/${AGENT_G}-field-note-${SESSION_ID_G}"
FIELD_NOTE_REL_G="docs/bitacora/field-notes/${TIMESTAMP_G}-${AGENT_G}.md"
CONTENT_G='## Contexto
PR ya mergeado.'

git -C "$REPO_MAIN" worktree add -q -b "$DOC_BRANCH_G" "$TMP/g/prep-wt" origin/main
mkdir -p "$(dirname "$TMP/g/prep-wt/$FIELD_NOTE_REL_G")"
printf '%s\n' "$CONTENT_G" > "$TMP/g/prep-wt/$FIELD_NOTE_REL_G"
git -C "$TMP/g/prep-wt" add -- "$FIELD_NOTE_REL_G"
git -C "$TMP/g/prep-wt" commit -q -m "docs(bitacora): agregar field note de $AGENT_G"
git -C "$TMP/g/prep-wt" push -q -u origin "$DOC_BRANCH_G"
git -C "$REPO_MAIN" worktree remove "$TMP/g/prep-wt"

PR_URL_G="https://github.com/$REPO_SLUG/pull/9"
seed_pr_store_row "$STORE_G" 9 "$PR_URL_G" "MERGED" "2026-09-13T19:30:00Z" "$DOC_BRANCH_G" "main"

G_RC=$(run_field_note "$FAKE_BIN_G" "$AGENT_G" "$TIMESTAMP_G" "$SESSION_ID_G" "$CONTENT_G" "$TMP/g-stdout" "$TMP/g-stderr")
if [ "$G_RC" -eq 0 ]; then
    pass "PR mergeado: exit 0"
else
    fail "PR mergeado: exit $G_RC. stdout=$(cat "$TMP/g-stdout") stderr=$(cat "$TMP/g-stderr")"
fi

if grep -qF "mergeado" "$TMP/g-stdout"; then
    pass "CA-2: reporta que el PR ya fue mergeado/entregado"
else
    fail "CA-2: no reporto el estado mergeado. stdout: $(cat "$TMP/g-stdout")"
fi

if grep -qE '^pr create ' "$GH_CALL_LOG_G"; then
    fail "CA-2: 'gh pr create' NO deberia haberse llamado con un PR ya mergeado"
else
    pass "CA-2: 'gh pr create' no se llamo (PR ya mergeado)"
fi

if grep -qE '^pr reopen ' "$GH_CALL_LOG_G"; then
    fail "CA-2: 'gh pr reopen' NO deberia haberse llamado con un PR ya mergeado (MERGED != CLOSED sin merge)"
else
    pass "CA-2: 'gh pr reopen' no se llamo (MERGED se distingue de CLOSED sin merge)"
fi

# -------- Bloque H: un fallo recuperable por checkpoint (CA-3) --------

echo ""
echo "[H] Un fallo recuperable por checkpoint, con accion concreta (CA-3)"

assert_main_untouched() {
    local label="$1" main_dir="$2" ref_before="$3" sha_before="$4" status_before="$5"
    local ref_after sha_after status_after
    ref_after=$(git -C "$main_dir" symbolic-ref -q --short HEAD)
    sha_after=$(git -C "$main_dir" rev-parse HEAD)
    status_after=$(git -C "$main_dir" status --porcelain=v1 --untracked-files=all)
    if [ "$ref_after" = "$ref_before" ] && [ "$sha_after" = "$sha_before" ] && [ "$status_after" = "$status_before" ]; then
        pass "$label: CA-4 se mantiene (checkout principal intacto pese al abort)"
    else
        fail "$label: CA-4 violado tras el abort. ref: '$ref_before'->'$ref_after', sha: '$sha_before'->'$sha_after'"
    fi
}

# H1: checkpoint 'worktree' -- el fetch de origin/main falla (remote roto).
new_repo "h1"
REF_H1=$(git -C "$REPO_MAIN" symbolic-ref -q --short HEAD)
SHA_H1=$(git -C "$REPO_MAIN" rev-parse HEAD)
STATUS_H1=$(git -C "$REPO_MAIN" status --porcelain=v1 --untracked-files=all)
git -C "$REPO_MAIN" remote set-url origin "$TMP/h1/no-existe.git"
FAKE_BIN_H1="$TMP/h1/bin"
write_pr_store_gh "$FAKE_BIN_H1" "$TMP/h1/gh-calls.log" "$TMP/h1/pr-store.tsv"
H1_RC=$(run_field_note "$FAKE_BIN_H1" "mefisto-planner" "2026-09-13-2000" "2026-09-13-2000-01-h1-55501" "contenido h1" "$TMP/h1-stdout" "$TMP/h1-stderr")
if [ "$H1_RC" -ne 0 ] && grep -qF "Ultimo checkpoint confirmado: inicio" "$TMP/h1-stderr" && grep -qF "Accion de recuperacion:" "$TMP/h1-stderr"; then
    pass "H1 (worktree/fetch roto): aborta con checkpoint 'inicio' y accion concreta"
else
    fail "H1 (worktree/fetch roto): stderr inesperado: $(cat "$TMP/h1-stderr")"
fi
assert_main_untouched "H1" "$REPO_MAIN" "$REF_H1" "$SHA_H1" "$STATUS_H1"

# H2: checkpoint 'commit' -- gpg.program invalido fuerza el fallo de 'git commit'.
new_repo "h2"
REF_H2=$(git -C "$REPO_MAIN" symbolic-ref -q --short HEAD)
SHA_H2=$(git -C "$REPO_MAIN" rev-parse HEAD)
STATUS_H2=$(git -C "$REPO_MAIN" status --porcelain=v1 --untracked-files=all)
git -C "$REPO_MAIN" config commit.gpgsign true
git -C "$REPO_MAIN" config gpg.program "$TMP/h2/no-existe-gpg"
FAKE_BIN_H2="$TMP/h2/bin"
write_pr_store_gh "$FAKE_BIN_H2" "$TMP/h2/gh-calls.log" "$TMP/h2/pr-store.tsv"
H2_RC=$(run_field_note "$FAKE_BIN_H2" "mefisto-planner" "2026-09-13-2000" "2026-09-13-2000-01-h2-55502" "contenido h2" "$TMP/h2-stdout" "$TMP/h2-stderr")
if [ "$H2_RC" -ne 0 ] && grep -qF "fallo en el paso 'commit'" "$TMP/h2-stderr" && grep -qF "Ultimo checkpoint confirmado: worktree" "$TMP/h2-stderr"; then
    pass "H2 (commit/gpg roto): aborta con checkpoint 'worktree' confirmado y paso 'commit' identificado"
else
    fail "H2 (commit/gpg roto): stderr inesperado: $(cat "$TMP/h2-stderr")"
fi
assert_main_untouched "H2" "$REPO_MAIN" "$REF_H2" "$SHA_H2" "$STATUS_H2"

# H3: checkpoint 'push' -- hook pre-receive del remote bare rechaza 'docs/*'.
new_repo "h3"
REF_H3=$(git -C "$REPO_MAIN" symbolic-ref -q --short HEAD)
SHA_H3=$(git -C "$REPO_MAIN" rev-parse HEAD)
STATUS_H3=$(git -C "$REPO_MAIN" status --porcelain=v1 --untracked-files=all)
cat > "$REPO_BARE/hooks/pre-receive" <<'EOF'
#!/usr/bin/env bash
while read -r old new ref; do
    case "$ref" in
        refs/heads/docs/*) echo "rechazado: rama documental deshabilitada" >&2; exit 1 ;;
    esac
done
exit 0
EOF
chmod +x "$REPO_BARE/hooks/pre-receive"
FAKE_BIN_H3="$TMP/h3/bin"
write_pr_store_gh "$FAKE_BIN_H3" "$TMP/h3/gh-calls.log" "$TMP/h3/pr-store.tsv"
H3_RC=$(run_field_note "$FAKE_BIN_H3" "mefisto-planner" "2026-09-13-2000" "2026-09-13-2000-01-h3-55503" "contenido h3" "$TMP/h3-stdout" "$TMP/h3-stderr")
if [ "$H3_RC" -ne 0 ] && grep -qF "fallo en el paso 'push'" "$TMP/h3-stderr" && grep -qF "Ultimo checkpoint confirmado: commit" "$TMP/h3-stderr"; then
    pass "H3 (push rechazado por hook): aborta con checkpoint 'commit' confirmado y paso 'push' identificado"
else
    fail "H3 (push rechazado por hook): stderr inesperado: $(cat "$TMP/h3-stderr")"
fi
assert_main_untouched "H3" "$REPO_MAIN" "$REF_H3" "$SHA_H3" "$STATUS_H3"

# H4: checkpoint 'consulta-pr' -- 'gh pr list' falla tras un push exitoso.
new_repo "h4"
REF_H4=$(git -C "$REPO_MAIN" symbolic-ref -q --short HEAD)
SHA_H4=$(git -C "$REPO_MAIN" rev-parse HEAD)
STATUS_H4=$(git -C "$REPO_MAIN" status --porcelain=v1 --untracked-files=all)
FAKE_BIN_H4="$TMP/h4/bin"
mkdir -p "$FAKE_BIN_H4"
cat > "$FAKE_BIN_H4/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$TMP/h4/gh-calls.log"
if [ "\$1" = "repo" ] && [ "\$2" = "view" ]; then
    if printf '%s\n' "\$@" | grep -q "nameWithOwner"; then echo "$REPO_SLUG"; exit 0; fi
    if printf '%s\n' "\$@" | grep -q "defaultBranchRef"; then echo "main"; exit 0; fi
    exit 1
fi
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then echo "gh: fallo simulado de red" >&2; exit 1; fi
exit 1
EOF
chmod +x "$FAKE_BIN_H4/gh"
H4_RC=$(run_field_note "$FAKE_BIN_H4" "mefisto-planner" "2026-09-13-2000" "2026-09-13-2000-01-h4-55504" "contenido h4" "$TMP/h4-stdout" "$TMP/h4-stderr")
if [ "$H4_RC" -ne 0 ] && grep -qF "fallo en el paso 'consulta-pr'" "$TMP/h4-stderr" && grep -qF "Ultimo checkpoint confirmado: push" "$TMP/h4-stderr"; then
    pass "H4 (consulta-pr rota): aborta con checkpoint 'push' confirmado y paso 'consulta-pr' identificado"
else
    fail "H4 (consulta-pr rota): stderr inesperado: $(cat "$TMP/h4-stderr")"
fi
DOC_BRANCH_H4="docs/mefisto-planner-field-note-2026-09-13-2000-01-h4-55504"
if git --git-dir="$REPO_BARE" show-ref --verify --quiet "refs/heads/$DOC_BRANCH_H4"; then
    pass "H4: la rama quedo empujada en origin (el commit no se perdio pese al fallo de consulta)"
else
    fail "H4: la rama no llego a origin"
fi
assert_main_untouched "H4" "$REPO_MAIN" "$REF_H4" "$SHA_H4" "$STATUS_H4"

# H5: checkpoint 'reapertura-pr' -- PR cerrado sin merge, 'gh pr reopen' falla.
new_repo "h5"
REF_H5=$(git -C "$REPO_MAIN" symbolic-ref -q --short HEAD)
SHA_H5=$(git -C "$REPO_MAIN" rev-parse HEAD)
STATUS_H5=$(git -C "$REPO_MAIN" status --porcelain=v1 --untracked-files=all)
AGENT_H5="mefisto-planner"
TIMESTAMP_H5="2026-09-13-2000"
SESSION_ID_H5="2026-09-13-2000-01-h5-55505"
DOC_BRANCH_H5="docs/${AGENT_H5}-field-note-${SESSION_ID_H5}"
FIELD_NOTE_REL_H5="docs/bitacora/field-notes/${TIMESTAMP_H5}-${AGENT_H5}.md"
git -C "$REPO_MAIN" worktree add -q -b "$DOC_BRANCH_H5" "$TMP/h5/prep-wt" origin/main
mkdir -p "$(dirname "$TMP/h5/prep-wt/$FIELD_NOTE_REL_H5")"
printf '%s\n' "contenido h5" > "$TMP/h5/prep-wt/$FIELD_NOTE_REL_H5"
git -C "$TMP/h5/prep-wt" add -- "$FIELD_NOTE_REL_H5"
git -C "$TMP/h5/prep-wt" commit -q -m "docs(bitacora): agregar field note de $AGENT_H5"
git -C "$TMP/h5/prep-wt" push -q -u origin "$DOC_BRANCH_H5"
git -C "$REPO_MAIN" worktree remove "$TMP/h5/prep-wt"
PR_URL_H5="https://github.com/$REPO_SLUG/pull/10"
FAKE_BIN_H5="$TMP/h5/bin"
mkdir -p "$FAKE_BIN_H5"
cat > "$FAKE_BIN_H5/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$TMP/h5/gh-calls.log"
if [ "\$1" = "repo" ] && [ "\$2" = "view" ]; then
    if printf '%s\n' "\$@" | grep -q "nameWithOwner"; then echo "$REPO_SLUG"; exit 0; fi
    if printf '%s\n' "\$@" | grep -q "defaultBranchRef"; then echo "main"; exit 0; fi
    exit 1
fi
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
    printf '[{"number":10,"url":"%s","state":"CLOSED","mergedAt":null}]\n' "$PR_URL_H5"
    exit 0
fi
if [ "\$1" = "pr" ] && [ "\$2" = "reopen" ]; then echo "gh: fallo simulado al reabrir" >&2; exit 1; fi
exit 1
EOF
chmod +x "$FAKE_BIN_H5/gh"
H5_RC=$(run_field_note "$FAKE_BIN_H5" "$AGENT_H5" "$TIMESTAMP_H5" "$SESSION_ID_H5" "contenido h5" "$TMP/h5-stdout" "$TMP/h5-stderr")
if [ "$H5_RC" -ne 0 ] && grep -qF "fallo en el paso 'reapertura-pr'" "$TMP/h5-stderr" && grep -qF "Ultimo checkpoint confirmado: push" "$TMP/h5-stderr"; then
    pass "H5 (reapertura-pr rota): aborta con checkpoint 'push' confirmado y paso 'reapertura-pr' identificado"
else
    fail "H5 (reapertura-pr rota): stderr inesperado: $(cat "$TMP/h5-stderr")"
fi
assert_main_untouched "H5" "$REPO_MAIN" "$REF_H5" "$SHA_H5" "$STATUS_H5"

# H6: checkpoint 'creacion-pr' -- sin PR previo, 'gh pr create' falla.
new_repo "h6"
REF_H6=$(git -C "$REPO_MAIN" symbolic-ref -q --short HEAD)
SHA_H6=$(git -C "$REPO_MAIN" rev-parse HEAD)
STATUS_H6=$(git -C "$REPO_MAIN" status --porcelain=v1 --untracked-files=all)
FAKE_BIN_H6="$TMP/h6/bin"
mkdir -p "$FAKE_BIN_H6"
cat > "$FAKE_BIN_H6/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$TMP/h6/gh-calls.log"
if [ "\$1" = "repo" ] && [ "\$2" = "view" ]; then
    if printf '%s\n' "\$@" | grep -q "nameWithOwner"; then echo "$REPO_SLUG"; exit 0; fi
    if printf '%s\n' "\$@" | grep -q "defaultBranchRef"; then echo "main"; exit 0; fi
    exit 1
fi
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then echo "[]"; exit 0; fi
if [ "\$1" = "pr" ] && [ "\$2" = "create" ]; then echo "gh: fallo simulado al crear" >&2; exit 1; fi
exit 1
EOF
chmod +x "$FAKE_BIN_H6/gh"
H6_RC=$(run_field_note "$FAKE_BIN_H6" "mefisto-planner" "2026-09-13-2000" "2026-09-13-2000-01-h6-55506" "contenido h6" "$TMP/h6-stdout" "$TMP/h6-stderr")
if [ "$H6_RC" -ne 0 ] && grep -qF "fallo en el paso 'creacion-pr'" "$TMP/h6-stderr" && grep -qF "Ultimo checkpoint confirmado: push" "$TMP/h6-stderr"; then
    pass "H6 (creacion-pr rota): aborta con checkpoint 'push' confirmado y paso 'creacion-pr' identificado"
else
    fail "H6 (creacion-pr rota): stderr inesperado: $(cat "$TMP/h6-stderr")"
fi
assert_main_untouched "H6" "$REPO_MAIN" "$REF_H6" "$SHA_H6" "$STATUS_H6"

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
