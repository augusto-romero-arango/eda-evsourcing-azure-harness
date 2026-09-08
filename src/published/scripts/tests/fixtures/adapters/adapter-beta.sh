#!/usr/bin/env bash
set -u
case "$1" in
    root) printf '%s\n' 'dist/beta' ;;
    path) printf 'artefactos/%s\n' "$(basename "$2")" ;;
    render)
        case "$2" in *fallar*) echo 'fallo fixture beta' >&2; exit 1 ;; esac
        printf '%s\nbeta:%s\n' "$3" "$(basename "$2")" ;;
    *) exit 1 ;;
esac
