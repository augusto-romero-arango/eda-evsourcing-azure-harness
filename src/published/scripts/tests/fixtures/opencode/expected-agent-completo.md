---
description: "Lee, \"edita\" y ejecuta."
mode: "subagent"
permission: {"external_directory":"deny","doom_loop":"deny","lsp":"deny","todowrite":"deny","question":"deny","webfetch":"allow","websearch":"allow","skill":{"*":"deny","mefisto-projections":"allow","mefisto-comment-cleanup":"allow"},"task":"allow","list":"allow","glob":"allow","grep":"allow","bash":{"*":"deny","git *":"allow","gh *":"allow","jq *":"allow","cat *":"allow","ls":"allow","ls *":"allow","find *":"allow","grep *":"allow","sort":"allow","sort *":"allow","bash scripts/*":"allow","sh scripts/*":"allow","scripts/*":"allow","./scripts/*":"allow","${MEFISTO_PACKAGE_ROOT}/scripts/*":"allow","mkdir *":"allow","mktemp":"allow","mktemp *":"allow","rm *":"deny","curl *":"deny","ssh *":"deny","scp *":"deny","sudo *":"deny"},"edit":{"*":"allow","commands/**":"deny","skills/**":"deny","agents/**":"deny","hooks/**":"deny",".claude-plugin/**":"deny","src/published/**":"deny","src/runtime/**":"deny","dist/**":"deny","docs/adr/mef-adr-*":"deny"},"write":{"*":"allow","commands/**":"deny","skills/**":"deny","agents/**":"deny","hooks/**":"deny",".claude-plugin/**":"deny","src/published/**":"deny","src/runtime/**":"deny","dist/**":"deny","docs/adr/mef-adr-*":"deny"},"patch":{"*":"allow","commands/**":"deny","skills/**":"deny","agents/**":"deny","hooks/**":"deny",".claude-plugin/**":"deny","src/published/**":"deny","src/runtime/**":"deny","dist/**":"deny","docs/adr/mef-adr-*":"deny"},"read":{"*":"allow",".env":"deny",".env.*":"deny","**/.env":"deny","**/.env.*":"deny","**/auth.json":"deny","**/.aws/**":"deny","**/.ssh/**":"deny"}}
---
<!-- GENERADO por prueba desde fixture. No editar a mano. -->
Antes de ejecutar este body, usa la tool nativa `skill` para cargar, en este orden: `mefisto-projections`, `mefisto-comment-cleanup`. Si una carga es denegada o falla, detén la ejecución.
```bash
mefisto_opencode_data_root() {
    if [ -n "${XDG_DATA_HOME:-}" ]; then printf '%s/mefisto\n' "$XDG_DATA_HOME"
    elif [ "$(uname -s)" = Darwin ]; then printf '%s/Library/Application Support/mefisto\n' "$HOME"
    else printf '%s/.local/share/mefisto\n' "$HOME"; fi
}
mefisto_opencode_launcher="$(mefisto_opencode_data_root)/active/bin/mefisto-opencode"
if [ ! -f "$mefisto_opencode_launcher" ] || [ -L "$mefisto_opencode_launcher" ] || [ ! -x "$mefisto_opencode_launcher" ]; then
    printf '%s\n' 'ERROR OpenCode: no hay una release activa valida; instale o active la release OpenCode.' >&2; exit 1
fi
MEFISTO_PACKAGE_ROOT="$("$mefisto_opencode_launcher" package-root)" || {
    printf '%s\n' 'ERROR OpenCode: no se pudo resolver la release activa; instale o active la release OpenCode.' >&2; exit 1;
}
case "$MEFISTO_PACKAGE_ROOT" in
    /*) ;;
    *) printf '%s\n' 'ERROR OpenCode: la release activa no devolvio una raiz absoluta; reinstale o active la release OpenCode.' >&2; exit 1 ;;
esac
MEFISTO_PACKAGE_ROOT="$(cd "$MEFISTO_PACKAGE_ROOT" 2>/dev/null && pwd -P)" || {
    printf '%s\n' 'ERROR OpenCode: la release activa no existe; reinstale o active la release OpenCode.' >&2; exit 1;
}
export MEFISTO_PACKAGE_ROOT
```
Antes de continuar, aborta si existe `src/internal/scripts/generate-internal-adapters.sh`: ese directorio es el repositorio de Mefisto, no un consumidor.
Rutas: .mefisto/harness.config.json y ${MEFISTO_PACKAGE_ROOT}.
.mefisto/pipeline/logs/con-espacio.log
Ejecuta "${MEFISTO_PACKAGE_ROOT}/scripts/prueba.sh" "$ARGUMENTS con espacios" ahora.
Consulta /mefisto:otra-orden.
