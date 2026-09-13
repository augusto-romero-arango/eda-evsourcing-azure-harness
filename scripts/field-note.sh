#!/usr/bin/env bash
# field-note.sh -- Entrega idempotente y recuperable de la field note de
# cierre del planner publicado, mas el delta opcional del glosario de
# lenguaje ubicuo del consumidor (issue #1296).
#
# Extrae a un pipeline Bash ejecutable y probado la secuencia mecanica de
# worktree/commit/push/PR que hasta ahora vivia como ~120 lineas de prosa
# shell en el epilogo de agents/planner.md (lineas 1099-1216 antes de este
# issue) -- una secuencia mecanica que el modelo debia reinterpretar al final
# de una conversacion larga, con el riesgo real de crear la rama documental
# en el checkout principal si el contexto se compactaba antes de llegar ahi.
#
# Porta el DISENO ya validado en src/internal/scripts/mefisto-field-note.sh
# (issues #1295/#1299: worktree aislado, commit reusado/amendado, push
# --force-with-lease, PR creado/reutilizado/reabierto segun estado,
# limpieza y verificacion final del checkout principal) como implementacion
# PROPIA -- MEF-ADR-0019 prohibe que el lado publicado lea codigo del interno,
# asi que ningun archivo se comparte entre ambos.
#
# A diferencia del interno, agrega el delta OPCIONAL del glosario de lenguaje
# ubicuo del consumidor (--glossary/--glossary-path): valida que el YAML sigue
# siendo valido tras aplicar el delta -- con el primer validador que YA este
# en el PATH del consumidor, sin instalar nada -- y aborta antes de stagearlo
# si no valida o si no hay ningun validador disponible.
#
# Uso:
#   scripts/field-note.sh --session-id <id> --timestamp <YYYY-MM-DD-HHMM> \
#       --field-note <archivo-local> \
#       [--glossary-path <docs/ddd/ubiquitous-language.yaml|docs/eda/ubiquitous-language.yaml> \
#        --glossary <archivo-local>]
#
# --field-note y --glossary son RUTAS LOCALES (fuera del repo -- p. ej. un
# archivo temporal) con el contenido YA REDACTADO. El delta del glosario debe
# haberse reaplicado termino por termino sobre la version leida de
# 'origin/<rama por defecto>' (o de la rama documental de esta sesion, en un
# reintento) -- NUNCA copiando la version del checkout principal, que puede
# haber quedado desactualizada frente a origin durante la conversacion. Ese
# contenido ya fusionado es lo que este script espera recibir en --glossary;
# el no aplica ningun merge por su cuenta.
#
# Exit code: 0 si la entrega completo (PR creado, reutilizado, reabierto o ya
# mergeado), 1 en cualquier fallo -- el mensaje de error identifica el ultimo
# checkpoint confirmado (worktree/commit/push/pr) y una accion concreta de
# recuperacion.

set -uo pipefail

# Guard publicado (CA-4, MEF-ADR-0019): este script es del lado publicado y
# solo aplica al consumidor -- primero que cualquier otra cosa, mismo orden
# que el resto de scripts/*.sh publicados (ver scripts/seed-secret.sh), para
# que invocarlo sin argumentos dentro del repo de Mefisto aborte con ESTE
# mensaje y no con el de argumentos faltantes.
_REPO_ROOT_GUARD="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
if [ -f "$_REPO_ROOT_GUARD/.claude-plugin/plugin.json" ]; then
    echo "ERROR: scripts/field-note.sh es del plugin publicado y solo aplica al consumidor." >&2
    echo "Mefisto entrega sus propias field notes con src/internal/scripts/mefisto-field-note.sh." >&2
    exit 1
fi
unset _REPO_ROOT_GUARD

usage() {
    cat >&2 <<'EOF'
Uso: field-note.sh --session-id <id> --timestamp <YYYY-MM-DD-HHMM> --field-note <archivo-local> [--glossary-path <ruta-repo> --glossary <archivo-local>]

Entrega, en un worktree aislado del checkout principal, la field note de
cierre del planner (y opcionalmente el delta ya fusionado del glosario de
lenguaje ubicuo) via un PR idempotente contra la rama por defecto del repo.
EOF
}

SESSION_ID=""
TIMESTAMP=""
FIELD_NOTE_SRC=""
GLOSSARY_PATH=""
GLOSSARY_SRC=""

while [ $# -gt 0 ]; do
    case "$1" in
        --session-id)
            [ $# -ge 2 ] || { echo "ERROR: --session-id requiere un valor" >&2; usage; exit 1; }
            SESSION_ID="$2"; shift 2 ;;
        --timestamp)
            [ $# -ge 2 ] || { echo "ERROR: --timestamp requiere un valor" >&2; usage; exit 1; }
            TIMESTAMP="$2"; shift 2 ;;
        --field-note)
            [ $# -ge 2 ] || { echo "ERROR: --field-note requiere un valor" >&2; usage; exit 1; }
            FIELD_NOTE_SRC="$2"; shift 2 ;;
        --glossary-path)
            [ $# -ge 2 ] || { echo "ERROR: --glossary-path requiere un valor" >&2; usage; exit 1; }
            GLOSSARY_PATH="$2"; shift 2 ;;
        --glossary)
            [ $# -ge 2 ] || { echo "ERROR: --glossary requiere un valor" >&2; usage; exit 1; }
            GLOSSARY_SRC="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "ERROR: argumento desconocido '$1'" >&2
            usage
            exit 1 ;;
    esac
done

if [ -z "$SESSION_ID" ] || [ -z "$TIMESTAMP" ] || [ -z "$FIELD_NOTE_SRC" ]; then
    echo "ERROR: --session-id, --timestamp y --field-note son obligatorios" >&2
    usage
    exit 1
fi

# --glossary y --glossary-path son un par: ninguno tiene sentido sin el otro
# (CA-2). GLOSSARY_PATH ademas se restringe a los DOS unicos destinos que
# MEF-ADR-0040 reconoce para el glosario -- nunca un path arbitrario, y nunca
# una copia nueva mientras la ruta legada siga siendo la que el planner leyo.
if [ -n "$GLOSSARY_SRC" ] || [ -n "$GLOSSARY_PATH" ]; then
    if [ -z "$GLOSSARY_SRC" ] || [ -z "$GLOSSARY_PATH" ]; then
        echo "ERROR: --glossary y --glossary-path deben pasarse juntos" >&2
        exit 1
    fi
    case "$GLOSSARY_PATH" in
        docs/ddd/ubiquitous-language.yaml|docs/eda/ubiquitous-language.yaml) ;;
        *)
            echo "ERROR: --glossary-path '$GLOSSARY_PATH' no es un destino admitido." >&2
            echo "El unico archivo de glosario admisible es docs/ddd/ubiquitous-language.yaml" >&2
            echo "(o docs/eda/ubiquitous-language.yaml como ruta legada); nunca crees una copia distinta." >&2
            exit 1
            ;;
    esac
fi

# --- Validacion de FORMA antes de tocar Git (mismo alfabeto que el interno --
# src/internal/scripts/mefisto-field-note.sh: '/', '..', espacios o
# metacaracteres de shell podrian escapar del directorio de la field note o
# inyectar argumentos en git/gh). --------------------------------------------
validate_slug() {
    local value="$1" label="$2" max="$3"
    case "$value" in
        -*)
            echo "ERROR: $label '$value' no puede empezar con '-'" >&2
            return 1
            ;;
    esac
    if [[ "$value" =~ [^A-Za-z0-9_-] ]]; then
        echo "ERROR: $label '$value' es invalido: solo se permiten letras, digitos, '-' y '_'" >&2
        return 1
    fi
    if [ "${#value}" -gt "$max" ]; then
        echo "ERROR: $label '$value' supera $max caracteres" >&2
        return 1
    fi
    return 0
}

validate_slug "$SESSION_ID" "--session-id" 120 || exit 1

if ! [[ "$TIMESTAMP" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$ ]]; then
    echo "ERROR: --timestamp '$TIMESTAMP' es invalido: se espera el formato YYYY-MM-DD-HHMM" >&2
    exit 1
fi

if [ ! -f "$FIELD_NOTE_SRC" ]; then
    echo "ERROR: --field-note '$FIELD_NOTE_SRC' no existe o no es un archivo" >&2
    exit 1
fi
if [ -n "$GLOSSARY_SRC" ] && [ ! -f "$GLOSSARY_SRC" ]; then
    echo "ERROR: --glossary '$GLOSSARY_SRC' no existe o no es un archivo" >&2
    exit 1
fi

for dep in git gh jq; do
    command -v "$dep" >/dev/null 2>&1 || { echo "ERROR: '$dep' no esta disponible en PATH" >&2; exit 1; }
done

REPO_ROOT="$(git rev-parse --show-toplevel)"

FIELD_NOTE_CONTENT="$(cat "$FIELD_NOTE_SRC")"
if [ -z "$FIELD_NOTE_CONTENT" ]; then
    echo "ERROR: '$FIELD_NOTE_SRC' esta vacio" >&2
    exit 1
fi
GLOSSARY_CONTENT=""
if [ -n "$GLOSSARY_SRC" ]; then
    GLOSSARY_CONTENT="$(cat "$GLOSSARY_SRC")"
    if [ -z "$GLOSSARY_CONTENT" ]; then
        echo "ERROR: '$GLOSSARY_SRC' esta vacio" >&2
        exit 1
    fi
fi

# validate_yaml_file <path>
#
# Valida YAML con el primer validador que YA este en el PATH del consumidor
# (CA-3: nunca instala dependencias). Prueba, en orden, python3+PyYAML, ruby
# (YAML de su stdlib -- Psych, sin gems) y yq (mikefarah, sintaxis 'yq eval').
# Retorna 0 si valido, 1 si invalido, 2 si ningun validador esta disponible --
# el caller trata ese caso igual que un YAML invalido: no se puede confirmar
# la garantia, asi que aborta antes de stagear en vez de asumir que esta bien.
validate_yaml_file() {
    local file="$1"
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
        python3 -c '
import sys
import yaml
with open(sys.argv[1], encoding="utf-8") as f:
    yaml.safe_load(f)
' "$file" >/dev/null 2>&1
        return $?
    fi
    if command -v ruby >/dev/null 2>&1 && ruby -ryaml -e '' >/dev/null 2>&1; then
        ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]))' "$file" >/dev/null 2>&1
        return $?
    fi
    if command -v yq >/dev/null 2>&1; then
        yq eval '.' "$file" >/dev/null 2>&1
        return $?
    fi
    return 2
}

if [ -n "$GLOSSARY_SRC" ]; then
    if ! validate_yaml_file "$GLOSSARY_SRC"; then
        echo "ERROR: '$GLOSSARY_SRC' no paso la validacion YAML (o no se encontro ningun validador ya presente en PATH -- se probo python3+PyYAML, ruby y yq; este script no instala nada nuevo)." >&2
        echo "Accion de recuperacion: reformula unicamente el delta del glosario contra la version en 'origin/<rama por defecto>' y reintenta; no se toco git." >&2
        exit 1
    fi
fi

# --- Custodia del checkout principal (CA-1) ---------------------------------
#
# Estos tres valores se vuelven a medir en cleanup_and_verify, al final: deben
# coincidir exactamente. El checkout principal nunca se usa para escribir ni
# para 'git add'/'git commit' -- toda mutacion ocurre en WORKTREE_DIR, tanto en
# una entrega nueva como en una reanudada.
INITIAL_HEAD_REF="$(git -C "$REPO_ROOT" symbolic-ref -q --short HEAD || true)"
INITIAL_HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)" \
    || { echo "ERROR: no se pudo resolver HEAD del checkout principal" >&2; exit 1; }
INITIAL_STATUS="$(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all)"

WORKTREE_DIR=""
WORKTREE_REGISTERED=0
CLEANUP_DONE=0
LAST_CHECKPOINT="inicio"

# recovery_abort <paso> <accion>
#
# Aborta identificando el PASO que fallo y una ACCION concreta de recuperacion
# (nunca un "reintenta" generico) -- mismo contrato que el interno.
recovery_abort() {
    local paso="$1" accion="$2"
    echo "ERROR: fallo en el paso '$paso' de la entrega de la field note (sesion '$SESSION_ID')" >&2
    echo "Ultimo checkpoint confirmado: $LAST_CHECKPOINT" >&2
    echo "Accion de recuperacion: $accion" >&2
    exit 1
}

# cleanup_and_verify -- trap EXIT
#
# Corre pase lo que pase. Limpia el worktree SOLO si esta registrado y su
# status quedo limpio (un commit fallido, o una field note todavia sin
# confirmar en DOC_BRANCH, se conserva a proposito -- no perder la unica copia
# recuperable). Verifica despues que ref, SHA y status del checkout principal
# coincidan EXACTAMENTE con los medidos al arrancar; si no, fuerza exit 1
# aunque el resto del script haya completado bien.
cleanup_and_verify() {
    local exit_code=$?
    [ "$CLEANUP_DONE" -eq 1 ] && return "$exit_code"
    CLEANUP_DONE=1

    if [ -n "$WORKTREE_DIR" ] && [ "$WORKTREE_REGISTERED" -eq 1 ] && [ -d "$WORKTREE_DIR" ]; then
        local wt_status
        wt_status="$(git -C "$WORKTREE_DIR" status --porcelain=v1 --untracked-files=all 2>/dev/null || true)"
        if [ -z "$wt_status" ]; then
            git -C "$REPO_ROOT" worktree remove "$WORKTREE_DIR" >/dev/null 2>&1 || true
        else
            echo "AVISO: el worktree '$WORKTREE_DIR' conserva cambios sin commitear; no se elimina. Status:" >&2
            printf '%s\n' "$wt_status" >&2
        fi
    elif [ -n "$WORKTREE_DIR" ] && [ -d "$WORKTREE_DIR" ]; then
        rmdir "$WORKTREE_DIR" 2>/dev/null || true
    fi

    local current_ref current_sha current_status
    current_ref="$(git -C "$REPO_ROOT" symbolic-ref -q --short HEAD || true)"
    current_sha="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
    current_status="$(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all 2>/dev/null || true)"

    if [ "$current_ref" != "$INITIAL_HEAD_REF" ] || [ "$current_sha" != "$INITIAL_HEAD_SHA" ] || [ "$current_status" != "$INITIAL_STATUS" ]; then
        echo "ERROR: el checkout principal cambio durante la entrega de la field note (invariante CA-1 violado)" >&2
        echo "  ref:    inicial='$INITIAL_HEAD_REF' actual='$current_ref'" >&2
        echo "  sha:    inicial='$INITIAL_HEAD_SHA' actual='$current_sha'" >&2
        echo "  status: inicial='$INITIAL_STATUS' actual='$current_status'" >&2
        exit_code=1
    fi

    exit "$exit_code"
}
trap cleanup_and_verify EXIT

# --- Resolver repo y rama predeterminada ------------------------------------
REPO_SLUG="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"

DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')"
GH_REPO_VIEW_RC=$?
if [ "$GH_REPO_VIEW_RC" -ne 0 ] || [ -z "$DEFAULT_BRANCH" ] || [ "$DEFAULT_BRANCH" = "null" ]; then
    echo "ERROR: no se pudo resolver la rama predeterminada del repo via 'gh repo view' (rc=$GH_REPO_VIEW_RC); revisa 'gh auth status'" >&2
    exit 1
fi

FIELD_NOTE_REL="docs/bitacora/field-notes/${TIMESTAMP}-planner.md"
DOC_BRANCH="docs/planner-field-notes-${SESSION_ID}"

git -C "$REPO_ROOT" fetch origin "$DEFAULT_BRANCH" \
    || recovery_abort "worktree" "'git fetch origin $DEFAULT_BRANCH' fallo; verifica conectividad de red y credenciales de git, luego reintenta con los mismos --session-id/--timestamp."

# --- Localizar rama/worktree preexistentes de esta sesion -------------------
find_worktree_path_for_branch() {
    local branch="$1"
    git -C "$REPO_ROOT" worktree list --porcelain | awk -v want="refs/heads/$branch" '
        /^worktree / { wt = substr($0, 10) }
        /^branch / { if ($2 == want) { print wt; exit } }
    '
}

# DOC_BRANCH checkouteada en el CHECKOUT PRINCIPAL es el unico estado previo
# que no se reanuda (CA-1): reanudar ahi violaria el aislamiento del checkout
# principal. Se aborta ANTES de tocar nada; la recuperacion la ejecuta una
# persona, porque puede haber trabajo sin commitear encima.
if [ -n "$INITIAL_HEAD_REF" ] && [ "$INITIAL_HEAD_REF" = "$DOC_BRANCH" ]; then
    recovery_abort "worktree" "La rama documental '$DOC_BRANCH' esta checkouteada en el CHECKOUT PRINCIPAL ('$REPO_ROOT'); reanudar ahi violaria su aislamiento. Cambia ese checkout a su rama de trabajo habitual ('git -C $REPO_ROOT switch <rama>', preservando lo que tengas sin commitear) y reintenta con los mismos --session-id/--timestamp."
fi

EXISTING_WT_PATH="$(find_worktree_path_for_branch "$DOC_BRANCH")"
if [ -n "$EXISTING_WT_PATH" ] && [ ! -d "$EXISTING_WT_PATH" ]; then
    git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
    EXISTING_WT_PATH=""
fi

BRANCH_EXISTS_LOCAL=0
git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$DOC_BRANCH" && BRANCH_EXISTS_LOCAL=1

REMOTE_DOC_BRANCH_EXISTS=0
git -C "$REPO_ROOT" fetch origin "refs/heads/$DOC_BRANCH:refs/remotes/origin/$DOC_BRANCH" >/dev/null 2>&1 \
    && REMOTE_DOC_BRANCH_EXISTS=1

if [ -n "$EXISTING_WT_PATH" ]; then
    WORKTREE_DIR="$EXISTING_WT_PATH"
    echo "Worktree existente de una entrega previa de esta sesion reutilizado: $WORKTREE_DIR"
elif [ "$BRANCH_EXISTS_LOCAL" -eq 1 ]; then
    WORKTREE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/planner-field-note-${SESSION_ID}.XXXXXX")" \
        || { echo "ERROR: no se pudo crear el directorio temporal del worktree" >&2; exit 1; }
    git -C "$REPO_ROOT" worktree add "$WORKTREE_DIR" "$DOC_BRANCH" \
        || recovery_abort "worktree" "La rama '$DOC_BRANCH' ya existe localmente pero 'git worktree add' fallo; revisa 'git -C $REPO_ROOT worktree list' y 'git -C $REPO_ROOT branch -vv', corre 'git -C $REPO_ROOT worktree prune' si hay entradas huerfanas y reintenta con los mismos flags."
elif [ "$REMOTE_DOC_BRANCH_EXISTS" -eq 1 ]; then
    WORKTREE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/planner-field-note-${SESSION_ID}.XXXXXX")" \
        || { echo "ERROR: no se pudo crear el directorio temporal del worktree" >&2; exit 1; }
    git -C "$REPO_ROOT" worktree add -b "$DOC_BRANCH" "$WORKTREE_DIR" "origin/$DOC_BRANCH" \
        || recovery_abort "worktree" "La rama '$DOC_BRANCH' existe en origin pero no localmente y 'git worktree add' fallo; verifica conectividad de red y reintenta con los mismos flags."
else
    WORKTREE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/planner-field-note-${SESSION_ID}.XXXXXX")" \
        || { echo "ERROR: no se pudo crear el directorio temporal del worktree" >&2; exit 1; }
    git -C "$REPO_ROOT" worktree add -b "$DOC_BRANCH" "$WORKTREE_DIR" "origin/$DEFAULT_BRANCH" \
        || recovery_abort "worktree" "Esta es la primera entrega de la sesion y 'git worktree add' fallo; revisa que 'origin/$DEFAULT_BRANCH' exista (git -C $REPO_ROOT fetch origin $DEFAULT_BRANCH) y reintenta."
fi
WORKTREE_REGISTERED=1
LAST_CHECKPOINT="worktree"

# --- Escribir y validar exclusivamente los paths esperados (CA-1/CA-2) ------
FIELD_NOTE_ABS="$WORKTREE_DIR/$FIELD_NOTE_REL"
mkdir -p "$(dirname "$FIELD_NOTE_ABS")" \
    || recovery_abort "worktree" "No se pudo crear el directorio de '$FIELD_NOTE_REL' dentro de '$WORKTREE_DIR'; revisa permisos de disco y reintenta."
printf '%s\n' "$FIELD_NOTE_CONTENT" > "$FIELD_NOTE_ABS" \
    || recovery_abort "worktree" "No se pudo escribir '$FIELD_NOTE_ABS'; revisa espacio/permisos de disco y reintenta."
git -C "$WORKTREE_DIR" add -- "$FIELD_NOTE_REL" \
    || recovery_abort "worktree" "'git add' de la field note fallo en '$WORKTREE_DIR'; revisa 'git -C $WORKTREE_DIR status' y reintenta."

if [ -n "$GLOSSARY_SRC" ]; then
    GLOSSARY_ABS="$WORKTREE_DIR/$GLOSSARY_PATH"
    mkdir -p "$(dirname "$GLOSSARY_ABS")" \
        || recovery_abort "worktree" "No se pudo crear el directorio de '$GLOSSARY_PATH' dentro de '$WORKTREE_DIR'; revisa permisos de disco y reintenta."
    printf '%s\n' "$GLOSSARY_CONTENT" > "$GLOSSARY_ABS" \
        || recovery_abort "worktree" "No se pudo escribir '$GLOSSARY_ABS'; revisa espacio/permisos de disco y reintenta."

    # CA-3: se valida el archivo YA ESCRITO en el worktree documental --el
    # mismo que se va a stagear-- ANTES del 'git add' que lo staging.
    if ! validate_yaml_file "$GLOSSARY_ABS"; then
        recovery_abort "worktree" "'$GLOSSARY_PATH' dejo de ser YAML valido tras escribir el delta en '$WORKTREE_DIR' (o no se encontro ningun validador ya presente en PATH). No se stageo nada. Reformula unicamente el delta del glosario contra la version en 'origin/$DEFAULT_BRANCH' y reintenta con los mismos --session-id/--timestamp."
    fi

    git -C "$WORKTREE_DIR" add -- "$GLOSSARY_PATH" \
        || recovery_abort "worktree" "'git add' del glosario fallo en '$WORKTREE_DIR'; revisa 'git -C $WORKTREE_DIR status' y reintenta."
fi

# CA-2: el indice tiene que coincidir EXACTAMENTE con la field note y, solo
# cuando aplica, el glosario -- cualquier otro path aborta sin commitear nada.
WORKTREE_STATUS="$(git -C "$WORKTREE_DIR" status --porcelain=v1 --untracked-files=all)"
OTHER_PATHS="$WORKTREE_STATUS"
for expected_rel in "$FIELD_NOTE_REL" ${GLOSSARY_PATH:+"$GLOSSARY_PATH"}; do
    OTHER_PATHS="$(printf '%s\n' "$OTHER_PATHS" | grep -vxF "A  $expected_rel" | grep -vxF "M  $expected_rel" || true)"
done
OTHER_PATHS="$(printf '%s\n' "$OTHER_PATHS" | grep -v '^$' || true)"
if [ -n "$OTHER_PATHS" ]; then
    echo "ERROR: el worktree documental contiene cambios fuera de los paths esperados ('$FIELD_NOTE_REL'${GLOSSARY_PATH:+, '$GLOSSARY_PATH'}):" >&2
    printf '%s\n' "$OTHER_PATHS" >&2
    exit 1
fi

# --- Commit: crear, reusar o amend ------------------------------------------
HEAD_HAS_FIELD_NOTE=0
git -C "$WORKTREE_DIR" cat-file -e "HEAD:$FIELD_NOTE_REL" 2>/dev/null && HEAD_HAS_FIELD_NOTE=1

# HEAD_IS_BASE distingue "HEAD es el commit de esta sesion" de "HEAD sigue
# siendo la punta de la rama base" (una entrega previa de esta sesion se
# mergeo y su rama se borro en origin: el worktree nace de origin/<default>,
# que YA trae la field note). Amendar ahi reescribiria un commit ajeno.
HEAD_IS_BASE=0
git -C "$WORKTREE_DIR" merge-base --is-ancestor HEAD "origin/$DEFAULT_BRANCH" 2>/dev/null && HEAD_IS_BASE=1

if git -C "$WORKTREE_DIR" diff --cached --quiet; then
    if [ "$HEAD_HAS_FIELD_NOTE" -eq 1 ] && [ "$HEAD_IS_BASE" -eq 1 ]; then
        echo "Commit ya existente reutilizado: la field note ya esta en '$DEFAULT_BRANCH' con este mismo contenido (entrega previa ya mergeada)"
    elif [ "$HEAD_HAS_FIELD_NOTE" -eq 1 ]; then
        echo "Commit ya existente de esta sesion reutilizado (contenido identico, no se creo uno nuevo)"
    else
        recovery_abort "commit" "El worktree en '$WORKTREE_DIR' quedo sin cambios staged pero HEAD tampoco tiene '$FIELD_NOTE_REL' -- estado inconsistente. Inspecciona 'git -C $WORKTREE_DIR log --oneline' y 'git -C $WORKTREE_DIR status' a mano antes de reintentar."
    fi
else
    if [ "$HEAD_HAS_FIELD_NOTE" -eq 1 ] && [ "$HEAD_IS_BASE" -eq 0 ]; then
        git -C "$WORKTREE_DIR" commit --amend --no-edit \
            || recovery_abort "commit" "'git commit --amend' fallo en '$WORKTREE_DIR' al actualizar el contenido de una entrega previa; revisa 'git -C $WORKTREE_DIR status' (el commit anterior sigue intacto) y reintenta."
        echo "Commit existente de esta sesion actualizado via --amend (el contenido cambio respecto al intento anterior)"
    else
        git -C "$WORKTREE_DIR" commit -m "docs(bitacora): agregar field note del planner" \
            || recovery_abort "commit" "'git commit' del worktree documental fallo en '$WORKTREE_DIR'; revisa 'git -C $WORKTREE_DIR status' (los archivos siguen staged) y reintenta."
    fi
fi
COMMIT_SHA="$(git -C "$WORKTREE_DIR" rev-parse HEAD)"
LAST_CHECKPOINT="commit"

# --- Push --------------------------------------------------------------------
#
# --force-with-lease es idempotente en el camino feliz (si origin ya tiene
# exactamente este commit, es un no-op) y necesario en el camino de amend (el
# SHA local cambio respecto al ya empujado). Seguro porque DOC_BRANCH es una
# rama documental de un solo dueno (esta sesion).
git -C "$WORKTREE_DIR" push --force-with-lease -u origin "$DOC_BRANCH" \
    || recovery_abort "push" "'git push --force-with-lease' de '$DOC_BRANCH' fallo; el commit $COMMIT_SHA sigue disponible localmente en '$WORKTREE_DIR' (o reanudable con los mismos --session-id/--timestamp). Revisa conectividad de red, permisos del remoto y reintenta."
LAST_CHECKPOINT="push"

# --- Consultar y resolver el PR ----------------------------------------------
#
# jq evalua la LONGITUD del array antes de indexar (`empty` sobre '[]'): sin
# esto, '.[0] | [...] | @tsv' sobre una lista vacia emite tabuladores para el
# elemento nulo, indistinguibles en bash de "hay datos" (el defecto original
# del issue #1298 que motivo esta forma en el interno).
query_pr_for_branch() {
    local args=(pr list --head "$DOC_BRANCH" --base "$DEFAULT_BRANCH" --state all --json number,url,state,mergedAt)
    [ -n "$REPO_SLUG" ] && args+=(--repo "$REPO_SLUG")
    gh "${args[@]}"
}

PR_LIST_JSON="$(query_pr_for_branch)"
PR_LIST_RC=$?
if [ "$PR_LIST_RC" -ne 0 ]; then
    recovery_abort "consulta-pr" "'gh pr list' fallo para '$DOC_BRANCH'; la rama y el commit $COMMIT_SHA ya estan en origin (no se perdio nada). Revisa 'gh auth status' y reintenta con los mismos flags."
fi

PR_INFO="$(printf '%s' "$PR_LIST_JSON" | jq -c 'if length > 0 then .[0] else empty end' 2>/dev/null)"

if [ -z "$PR_INFO" ]; then
    PR_CREATE_ARGS=(pr create --base "$DEFAULT_BRANCH" --head "$DOC_BRANCH" \
        --title "docs(bitacora): field notes del planner" \
        --body "Entrega aislada de la field note del planner de la sesión ${SESSION_ID}. No incluye cambios preexistentes.")
    [ -n "$REPO_SLUG" ] && PR_CREATE_ARGS+=(--repo "$REPO_SLUG")
    PR_URL="$(gh "${PR_CREATE_ARGS[@]}")" \
        || recovery_abort "creacion-pr" "'gh pr create' fallo; la rama '$DOC_BRANCH' con el commit $COMMIT_SHA ya esta empujada a origin. Revisa 'gh auth status' y reintenta con los mismos flags -- la proxima corrida encontrara la rama ya lista y solo reintentara el PR."
    echo "PR creado (no existia ninguno para '$DOC_BRANCH')"
else
    PR_STATE="$(printf '%s' "$PR_INFO" | jq -r '.state')"
    PR_MERGED_AT="$(printf '%s' "$PR_INFO" | jq -r '.mergedAt')"
    PR_URL="$(printf '%s' "$PR_INFO" | jq -r '.url')"
    PR_NUMBER="$(printf '%s' "$PR_INFO" | jq -r '.number')"

    if [ "$PR_STATE" = "MERGED" ] || { [ -n "$PR_MERGED_AT" ] && [ "$PR_MERGED_AT" != "null" ]; }; then
        echo "PR ya mergeado: la field note de esta sesion ya fue entregada ($PR_URL)"
    elif [ "$PR_STATE" = "OPEN" ]; then
        echo "PR ya existente reutilizado (no se llamo a 'gh pr create')"
    else
        PR_REOPEN_ARGS=(pr reopen "$PR_NUMBER")
        [ -n "$REPO_SLUG" ] && PR_REOPEN_ARGS+=(--repo "$REPO_SLUG")
        gh "${PR_REOPEN_ARGS[@]}" \
            || recovery_abort "reapertura-pr" "El PR $PR_URL de '$DOC_BRANCH' esta cerrado sin merge y 'gh pr reopen' fallo; la rama y el commit $COMMIT_SHA siguen intactos en origin. Reabrelo a mano en GitHub, o revisa 'gh auth status' y reintenta."
        echo "PR cerrado sin merge fue reabierto: $PR_URL"
    fi
fi
LAST_CHECKPOINT="pr"

echo "Field note: $FIELD_NOTE_REL"
[ -n "$GLOSSARY_PATH" ] && echo "Glosario: $GLOSSARY_PATH"
echo "Rama: $DOC_BRANCH"
echo "Commit: $COMMIT_SHA"
echo "PR: $PR_URL"
