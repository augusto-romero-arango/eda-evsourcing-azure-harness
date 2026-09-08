#!/usr/bin/env bash
set -u
case "$1" in
    root) printf '%s\n' 'dist/alpha' ;;
    path) printf 'artefactos/%s\n' "$(basename "$2")" ;;
    render) printf '%s\nalpha:%s\n' "$3" "$(basename "$2")" ;;
    *) exit 1 ;;
esac
