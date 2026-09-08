#!/usr/bin/env bash
set -u
case "$1" in
    root) printf '%s\n' 'dist/assets' ;;
    path) printf 'artefactos/%s\n' "$(basename "$2")" ;;
    render) printf '%s\nasset-adapter:%s\n' "$3" "$(basename "$2")" ;;
    assets)
        case "${FIXTURE_ASSETS:-normal}" in
            normal) printf '%s\n' '[{"id":"config","source":"src/published/assets/config.txt","destination":"runtime/config.json","mode":"0644"},{"id":"launcher","source":"src/published/assets/launcher.txt","destination":"bin/launcher","mode":"0755"}]' ;;
            colision) printf '%s\n' '[{"id":"colision","source":"src/published/assets/config.txt","destination":"artefactos/valida con espacios.md","mode":"0644"}]' ;;
            duplicado) printf '%s\n' '[{"id":"repetido","source":"src/published/assets/config.txt","destination":"uno","mode":"0644"},{"id":"repetido","source":"src/published/assets/launcher.txt","destination":"dos","mode":"0644"}]' ;;
            mismo-destino) printf '%s\n' '[{"id":"uno","source":"src/published/assets/config.txt","destination":"repetido","mode":"0644"},{"id":"dos","source":"src/published/assets/launcher.txt","destination":"repetido","mode":"0644"}]' ;;
            inseguro) printf '%s\n' '[{"id":"inseguro","source":"../secret","destination":"x","mode":"0644"}]' ;;
            destino-inseguro) printf '%s\n' '[{"id":"inseguro","source":"src/published/assets/config.txt","destination":"../x","mode":"0644"}]' ;;
            ausente) printf '%s\n' '[{"id":"ausente","source":"src/published/assets/no-existe","destination":"x","mode":"0644"}]' ;;
            modo) printf '%s\n' '[{"id":"modo","source":"src/published/assets/config.txt","destination":"x","mode":"0600"}]' ;;
            fallar) printf '%s\n' 'fallo al enumerar assets' >&2; exit 1 ;;
        esac ;;
    render-asset)
        case "${FIXTURE_ASSETS:-normal}:$2" in render-fallar:*) exit 1 ;; *) printf 'renderizado:%s\n' "$(cat "$3")" ;; esac ;;
    *) exit 1 ;;
esac
