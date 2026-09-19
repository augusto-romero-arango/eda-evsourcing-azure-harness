#!/usr/bin/env bash
# Fixture de regresion (issue #1499): declara MANY_ASSETS_COUNT assets (>= 150
# por defecto) para probar que la deteccion de colisiones no vuelve a ser
# cuadratica con jq. Todos los assets apuntan a la misma fuente fixture.
set -u
COUNT="${MANY_ASSETS_COUNT:-160}"
case "$1" in
    root) printf '%s\n' 'dist/many' ;;
    path) printf 'artefactos/%s\n' "$(basename "$2")" ;;
    render) printf '%s\nmany:%s\n' "$3" "$(basename "$2")" ;;
    assets)
        printf '['
        i=1
        while [ "$i" -le "$COUNT" ]; do
            [ "$i" -eq 1 ] || printf ','
            printf '{"id":"asset-%d","source":"src/published/assets/config.txt","destination":"generated/asset-%d.txt","mode":"0644"}' "$i" "$i"
            i=$((i + 1))
        done
        printf ']\n'
        ;;
    render-asset) printf 'renderizado:%s\n' "$(cat "$3")" ;;
    *) exit 1 ;;
esac
