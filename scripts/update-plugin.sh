#!/usr/bin/env bash
# update-plugin.sh -- actualiza el plugin Mefisto desde el consumidor (issue #531).
#
# Reemplaza el flujo manual de 4 pasos (UI de /plugin, reescribir .plugin-root a mano,
# podar el cache de versiones viejas, /reload-plugins) por 1 comando + el reload final
# (el reload no es automatizable desde dentro de la sesion: lo declara el propio CLI,
# "restart required to apply").
#
# Dos modos, dos invocaciones -- commands/upgrade.md las encadena con la confirmacion
# del usuario en medio:
#
#   scripts/update-plugin.sh
#     Modo ACTUALIZAR (nunca borra nada):
#       1. Detecta el directorio del marketplace que provee 'mefisto' en el cache
#          (~/.claude/plugins/cache/<marketplace>/mefisto/), sin hardcodear el nombre:
#          lo deriva del .plugin-root cargado y, si eso no alcanza, por glob sobre el
#          cache -- asi funciona igual en un fork publicado bajo otro marketplace
#          (repoSlug).
#       2. Actualiza catalogo y plugin sin interaccion ('claude plugin marketplace
#          update <detectado>' + 'claude plugin update mefisto --scope user').
#       3. Reescribe .claude/pipeline/.plugin-root a la version mas reciente del cache,
#          para que un pipeline headless que arranque antes del /reload-plugins ya
#          resuelva la version nueva (mismo archivo que escribe el hook SessionStart;
#          reescribirlo aqui es idempotente -- el hook lo reconfirma al proximo arranque).
#       4. Imprime el delta de CHANGELOG.md entre la version cargada y la nueva.
#       5. Reporta que versiones del cache quedarian podables. NO borra ninguna.
#
#   scripts/update-plugin.sh --prune [--loaded <version>]
#     Modo PODA: la unica operacion destructiva del script, y solo tras la confirmacion
#     explicita del usuario que pide commands/upgrade.md (CA-4). NO vuelve a llamar al
#     CLI: la actualizacion ya la hizo la invocacion anterior, y repetirla podria mover
#     la version destino a mitad del ciclo.
#
# Como se sabe que version tiene cargada la sesion activa -- el invariante de CA-4: la
# poda NUNCA la borra, porque si el skill en ejecucion se borra a si mismo la sesion
# rompe a mitad de camino:
#
#   - .plugin-root NO sirve por si solo: el modo actualizar lo reescribe a la version
#     nueva (paso 3), asi que desde ese momento ya no describe lo que la sesion tiene
#     cargado en memoria, sino lo que resolvera el proximo proceso.
#   - Fuente primaria: --loaded <version>, que commands/upgrade.md copia de la linea
#     "Version cargada en esta sesion:" que imprimio la invocacion de actualizacion
#     (mismo patron con el que commands/onboard.md pasa SUBSCRIPTION_ID entre bloques).
#   - Fuente secundaria: .claude/pipeline/.plugin-root.previous, que el modo actualizar
#     escribe UNA sola vez por sesion -- nunca lo sobreescribe si ya existe -- copiando
#     el .plugin-root previo al paso 3. Lo borra el hook SessionStart del plugin, no
#     este script: mientras la sesion siga viva sigue describiendo la version que cargo,
#     asi que dos corridas de /mefisto:upgrade en la misma sesion (el camino que el
#     propio skill sugiere cuando el usuario declina podar) siguen protegiendola.
#   - Si ninguna de las dos resuelve nada, se protegen las DOS versiones mas nuevas del
#     cache (la nueva y la N-1, que en el caso normal es la que la sesion cargo) y se
#     avisa que la version cargada se infirio.
#   - En todos los casos se protege ADEMAS la version a la que apunta .plugin-root en
#     ese momento: si el marker quedo desactualizado (p. ej. una sesion con un hook
#     viejo que no lo limpia), el peor caso es conservar una version de mas, nunca
#     borrar la cargada.
#
# La poda deja siempre {version nueva, version cargada}; la N-1 que sobreviva cae en el
# siguiente /mefisto:upgrade, como documenta el issue #531.
#
# Uso:
#   scripts/update-plugin.sh                        # actualiza y reporta podables (no borra)
#   scripts/update-plugin.sh --prune [--loaded X]   # borra las podables (tras confirmar)
#
# Exit code: 0 si el modo pedido corrio completo; 1 si el guard cwd != Mefisto aborta,
# si falta el CLI 'claude', si no hay 'mefisto' en el cache, o si el CLI fallo.

set -uo pipefail

PLUGIN_ROOT_FILE=".claude/pipeline/.plugin-root"
MARKER_FILE=".claude/pipeline/.plugin-root.previous"

usage() {
    echo "Uso: $0 [--prune [--loaded <version>]]" >&2
    echo "  (sin flags)        actualiza marketplace + plugin, reescribe .plugin-root, imprime el" >&2
    echo "                     delta de CHANGELOG y reporta versiones podables del cache (sin borrar)." >&2
    echo "  --prune            borra las versiones podables (solo tras confirmar con el usuario, CA-4)." >&2
    echo "  --loaded <version> version que la sesion activa tiene cargada; la poda nunca la borra." >&2
}

# _version_de_ruta <ruta-a-un-directorio-de-version>
#
# Extrae la version de una ruta del cache (.../mefisto/0.19.0), tolerando el slash
# final que dejan los globs 'ls -d .../*/'. Cadena vacia -> cadena vacia.
_version_de_ruta() {
    local ruta="${1%/}"
    [ -z "$ruta" ] && return 0
    basename "$ruta"
}

# _marketplace_dir <plugin_root_cargado> <cache_root>
#
# Imprime el directorio '<cache_root>/<marketplace>/mefisto' (CA-2: sin hardcodear
# 'augusto-romero-arango-harness', para que un fork publicado bajo otro nombre de
# marketplace funcione igual). Prefiere derivarlo del .plugin-root cargado -- que ya
# apunta dentro del cache y desambigua sin adivinar -- y cae al glob si eso no alcanza.
# Con mas de un candidato avisa por stderr y usa el primero. Retorna 1 si no hay ninguno.
_marketplace_dir() {
    local cargado="${1%/}" cache_root="${2%/}" candidatos n dir

    if [ -n "$cargado" ]; then
        case "$cargado" in
            "$cache_root"/*/mefisto/*)
                dir=$(dirname "$cargado")
                if [ "$(basename "$dir")" = "mefisto" ] && [ -d "$dir" ]; then
                    printf '%s\n' "$dir"
                    return 0
                fi
                ;;
        esac
    fi

    candidatos=$(ls -d "$cache_root"/*/mefisto 2>/dev/null | sort) || true
    [ -z "$candidatos" ] && return 1
    n=$(printf '%s\n' "$candidatos" | grep -c .)
    if [ "$n" -gt 1 ]; then
        echo "ADVERTENCIA: hay $n marketplaces con 'mefisto' en el cache; se usa el primero." >&2
        printf '%s\n' "$candidatos" | sed 's/^/  - /' >&2
    fi
    printf '%s\n' "$candidatos" | head -1
}

# _versiones_del_cache <dir_mefisto>
#
# Versiones presentes en el cache, una por linea, en orden ascendente de version.
_versiones_del_cache() {
    ls -d "${1%/}"/*/ 2>/dev/null | xargs -n1 basename 2>/dev/null | sort -V
}

# _protegidas <version_nueva> <version_cargada|""> <version_en_plugin_root|"">
#   stdin: todas las versiones del cache, una por linea (orden ascendente)
#   stdout: las versiones que la poda debe conservar, una por linea, sin duplicados
#
# Sin version cargada conocida infiere la N-1 (la mas nueva distinta de la nueva): es la
# que la sesion cargo en el caso normal, y protegerla de mas es preferible a borrar la
# que la sesion esta ejecutando.
_protegidas() {
    local nueva="$1" cargada="$2" en_root="$3" todas
    todas=$(cat)
    if [ -z "$cargada" ]; then
        cargada=$(printf '%s\n' "$todas" | grep -v '^$' | grep -vxF "$nueva" | tail -1)
    fi
    printf '%s\n%s\n%s\n' "$nueva" "$cargada" "$en_root" | grep -v '^$' | sort -u
}

# _podables <protegida> [<protegida> ...]
#   stdin: todas las versiones del cache, una por linea
#   stdout: las versiones a borrar (diferencia de conjuntos), en el orden de entrada
_podables() {
    local v
    while IFS= read -r v; do
        [ -z "$v" ] && continue
        case " $* " in
            *" $v "*) continue ;;
        esac
        printf '%s\n' "$v"
    done
}

# _delta_changelog <archivo_changelog> <version_cargada> <version_nueva>
#
# Imprime las entradas de CHANGELOG.md publicadas despues de <version_cargada>: arranca
# en el primer encabezado '## [' y corta al llegar al de la version cargada. Si ese
# encabezado no existe en el archivo (version cargada rara o CHANGELOG reescrito), no
# vuelca el historico completo: avisa y muestra solo la seccion mas reciente.
_delta_changelog() {
    local archivo="$1" cargada="$2" nueva="$3"

    if grep -Fq "## [$cargada]" "$archivo"; then
        echo "--- Delta de CHANGELOG.md ($cargada -> $nueva) ---"
        awk -v old_marker="## [$cargada]" '
            $0 ~ /^## \[/ { started = 1 }
            started && index($0, old_marker) == 1 { exit }
            started { print }
        ' "$archivo"
        echo "--- fin del delta ---"
        return 0
    fi

    echo "ADVERTENCIA: $archivo no tiene un encabezado '## [$cargada]'; no se puede acotar el delta."
    echo "--- Seccion mas reciente de CHANGELOG.md ---"
    awk '
        /^## \[/ { secciones++ }
        secciones >= 2 { exit }
        secciones >= 1 { print }
    ' "$archivo"
    echo "--- fin de la seccion ---"
}

main() {
    # Guard defensivo (cwd != Mefisto): este script es del lado publicado y solo aplica
    # al consumidor (MEF-ADR-0019). La segunda linea usa el fraseo canonico del resto de
    # los scripts publicados porque es lo que verifica el bloque C2 de
    # scripts/tests/test-guards.sh, que EJECUTA cada script dentro de Mefisto y exige
    # exit 1 mas ese mensaje.
    local repo_top
    repo_top=$(git rev-parse --show-toplevel 2>/dev/null) || {
        echo "ERROR: no estas en un repositorio git" >&2
        return 1
    }
    if [ -f "$repo_top/.claude-plugin/plugin.json" ]; then
        echo "ERROR: /mefisto:upgrade no aplica al repo de Mefisto." >&2
        echo "       scripts/update-plugin.sh es del plugin publicado y solo aplica al consumidor." >&2
        echo "       Mefisto se actualiza a si mismo por su propio flujo de release (/mefisto-release)." >&2
        return 1
    fi

    local prune=false loaded_cli=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --prune) prune=true; shift ;;
            --loaded)
                if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                    echo "ERROR: --loaded requiere una version (p. ej. --loaded 0.19.0)" >&2
                    usage
                    return 1
                fi
                loaded_cli="$2"; shift 2 ;;
            -h|--help) usage; return 0 ;;
            *) echo "ERROR: argumento desconocido '$1'" >&2; usage; return 1 ;;
        esac
    done

    # Overridable por entorno para que los tests puedan apuntar a un cache de mentira.
    local cache_root="${MEFISTO_CACHE_ROOT:-$HOME/.claude/plugins/cache}"

    local plugin_root_actual mefisto_cache_dir marketplace_name
    plugin_root_actual=$(cat "$PLUGIN_ROOT_FILE" 2>/dev/null) || true

    mefisto_cache_dir=$(_marketplace_dir "$plugin_root_actual" "$cache_root") || {
        echo "ERROR: no se encontro ningun 'mefisto' en el cache de plugins ($cache_root/*/mefisto)." >&2
        echo "       Verifica que el plugin este instalado (claude plugin install mefisto@<marketplace> --scope user)." >&2
        return 1
    }
    marketplace_name=$(basename "$(dirname "$mefisto_cache_dir")")

    # --- Version cargada en esta sesion: --loaded > marker > inferida ------------------
    local loaded_version="" origen_cargada=""
    if [ -n "$loaded_cli" ]; then
        loaded_version="$loaded_cli"
        origen_cargada="--loaded"
    elif [ -s "$MARKER_FILE" ]; then
        loaded_version=$(_version_de_ruta "$(cat "$MARKER_FILE" 2>/dev/null)")
        origen_cargada="$MARKER_FILE"
    elif [ -n "$plugin_root_actual" ] && [ "$prune" = false ]; then
        # Primera corrida de la sesion: .plugin-root todavia describe lo que la sesion
        # cargo (lo escribio el hook SessionStart), asi que es la fuente correcta.
        loaded_version=$(_version_de_ruta "$plugin_root_actual")
        origen_cargada="$PLUGIN_ROOT_FILE"
    fi

    echo "Marketplace detectado: $marketplace_name"
    if [ -n "$loaded_version" ]; then
        echo "Version cargada en esta sesion: $loaded_version (fuente: $origen_cargada)"
    else
        echo "ADVERTENCIA: no se pudo determinar la version cargada en esta sesion."
        echo "             Se protegera de la poda la version N-1 del cache por precaucion."
    fi
    echo ""

    if [ "$prune" = false ]; then
        # Marker de sesion: se escribe UNA vez (nunca se sobreescribe) para que la
        # invocacion --prune de este ciclo -- y cualquier corrida posterior de la misma
        # sesion -- siga viendo la version cargada aunque el paso 3 ya movio
        # .plugin-root. Lo limpia el hook SessionStart del plugin, no este script.
        if [ ! -s "$MARKER_FILE" ] && [ -n "$plugin_root_actual" ]; then
            mkdir -p .claude/pipeline
            printf '%s' "$plugin_root_actual" > "$MARKER_FILE"
        fi

        if ! command -v claude >/dev/null 2>&1; then
            echo "ERROR: el CLI 'claude' no esta en el PATH. Requerido para actualizar el plugin." >&2
            return 1
        fi

        echo "Actualizando el catalogo del marketplace ($marketplace_name)..."
        if ! claude plugin marketplace update "$marketplace_name"; then
            echo "ERROR: 'claude plugin marketplace update $marketplace_name' fallo." >&2
            echo "       Sin refrescar el catalogo, el update no veria la version nueva." >&2
            echo "       Revisa el acceso al repo del marketplace y reintenta." >&2
            return 1
        fi

        echo ""
        echo "Actualizando el plugin mefisto (scope user)..."
        if ! claude plugin update mefisto --scope user; then
            echo "ERROR: 'claude plugin update mefisto --scope user' fallo." >&2
            echo "       No se toco .plugin-root ni el cache; reintenta tras resolver la causa." >&2
            return 1
        fi
        echo ""
    fi

    # --- Version mas reciente del cache (CA-3) ----------------------------------------
    local new_version_dir new_version
    new_version_dir=$(ls -d "$mefisto_cache_dir"/*/ 2>/dev/null | sort -V | tail -1) || true
    if [ -z "$new_version_dir" ]; then
        echo "ERROR: no se encontro ninguna version de mefisto en $mefisto_cache_dir." >&2
        return 1
    fi
    new_version_dir="${new_version_dir%/}"
    new_version=$(basename "$new_version_dir")

    if [ "$prune" = false ]; then
        mkdir -p .claude/pipeline
        if printf '%s' "$new_version_dir" > "$PLUGIN_ROOT_FILE"; then
            echo "OK: $PLUGIN_ROOT_FILE -> $new_version_dir"
        else
            echo "ERROR: no se pudo escribir $PLUGIN_ROOT_FILE." >&2
            return 1
        fi
        plugin_root_actual="$new_version_dir"
        echo ""

        # --- Delta de CHANGELOG.md entre la version cargada y la nueva (CA-5) ---------
        local changelog_file="$new_version_dir/CHANGELOG.md"
        if [ "$loaded_version" = "$new_version" ]; then
            echo "Ya estabas en la version mas reciente ($new_version); no hay delta que mostrar."
        elif [ -n "$loaded_version" ] && [ -f "$changelog_file" ]; then
            _delta_changelog "$changelog_file" "$loaded_version" "$new_version"
        else
            echo "ADVERTENCIA: no se pudo calcular el delta de CHANGELOG (version cargada desconocida o CHANGELOG.md ausente)."
        fi
        echo ""
    fi

    # --- Poda del cache, conservando {version nueva, version cargada} (CA-4) ----------
    local todas protegidas podables
    todas=$(_versiones_del_cache "$mefisto_cache_dir")
    protegidas=$(printf '%s\n' "$todas" | _protegidas "$new_version" "$loaded_version" "$(_version_de_ruta "$plugin_root_actual")")
    # shellcheck disable=SC2086  # $protegidas son versiones sin espacios: se quieren como argumentos separados
    podables=$(printf '%s\n' "$todas" | _podables $protegidas)

    echo "Versiones conservadas: $(printf '%s' "$protegidas" | tr '\n' ' ')"
    if [ -z "$podables" ]; then
        echo "Cache limpio: no hay versiones podables."
    elif [ "$prune" = true ]; then
        echo "Borrando versiones podables del cache (--prune)..."
        local v destino
        while IFS= read -r v; do
            [ -z "$v" ] && continue
            destino="${mefisto_cache_dir%/}/$v"
            # Doble chequeo antes de un rm -rf: el destino debe ser un directorio de
            # version dentro del cache de mefisto, nunca una ruta armada a medias.
            case "$destino" in
                */mefisto/"$v")
                    if [ -d "$destino" ]; then
                        rm -rf "$destino" && echo "  borrada: $v" || echo "  FALLO al borrar: $v"
                    else
                        echo "  omitida (ya no existe): $v"
                    fi
                    ;;
                *) echo "  omitida (ruta inesperada): $destino" ;;
            esac
        done <<< "$podables"
        echo ""
        echo "El marker de sesion ($MARKER_FILE) se conserva: lo limpia el hook SessionStart"
        echo "del plugin en el proximo arranque. Mientras esta sesion viva, protege la version cargada."
    else
        echo "Versiones podables en el cache (ni la cargada en esta sesion ni la nueva):"
        printf '%s\n' "$podables" | sed 's/^/  - /'
        echo ""
        echo "No se borro nada. Pide confirmacion al usuario y, si acepta, vuelve a correr:"
        if [ -n "$loaded_version" ]; then
            echo "  $0 --prune --loaded $loaded_version"
        else
            echo "  $0 --prune"
        fi
    fi
    echo ""

    echo "Version destino: $new_version."
    echo "Corre /reload-plugins (o reinicia la sesion) para activar la version $new_version."
}

# Sourceable (scripts/tests/test-update-plugin.sh la sourcea para testear _protegidas(),
# _podables() y _marketplace_dir() sin invocar el CLI 'claude' ni tocar el cache real) y a
# la vez ejecutable directo, mismo patron que scripts/onboard-diagnose.sh.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
    exit $?
fi
