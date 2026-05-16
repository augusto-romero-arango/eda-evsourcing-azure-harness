Versiona y publica el plugin Mefisto siguiendo SemVer y Keep a Changelog. Comunicate en **espanol**.

**Alcance**: solo opera sobre el propio repo de Mefisto. No tiene equivalente publicado (el versionado del plugin es un artefacto de empaquetado del harness, no del marco arquitectonico).

## Entrada

Los argumentos estan en: $ARGUMENTS

Formas validas:
- `patch` -- bumpea `Z` en `X.Y.Z` (fase prepare)
- `minor` -- bumpea `Y` y resetea `Z` (fase prepare)
- `major` -- bumpea `X` y resetea `Y.Z` (fase prepare)
- *(sin argumentos)* -- detecta automaticamente la fase publish (tag + GitHub Release)

## Proceso

### 0. Verificar que estas en el repo de Mefisto

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git"; exit 1;
}
[ -f "$REPO_ROOT/.claude-plugin/plugin.json" ] || {
    echo "ERROR: este skill solo se ejecuta en el repo de Mefisto."
    echo "Abre el repo del plugin (eda-evsourcing-azure-harness) y reintenta."
    exit 1
}
```

### 1. Delegar al pipeline

```bash
./.claude/scripts/mefisto-release.sh $ARGUMENTS
```

El script detecta solo en que fase estamos:

- **Fase prepare** (`plugin.json.version == ultimo tag`): valida el argumento `patch|minor|major`, calcula la siguiente version segun SemVer, comprueba que `[Unreleased]` del `CHANGELOG.md` no esta vacio, crea la rama `release/vX.Y.Z`, mueve el bloque `[Unreleased]` a una seccion versionada con fecha UTC, actualiza los links de comparacion al pie, bumpea `.claude-plugin/plugin.json` con `jq`, commitea, pushea y abre el PR contra `main` con titulo `chore(release): vX.Y.Z`.
- **Fase publish** (`plugin.json.version > ultimo tag`): valida que estamos en `main`, working tree limpio, al dia con `origin/main` y `gh` autenticado; extrae las notas de la seccion versionada del CHANGELOG; crea el tag anotado `vX.Y.Z`; pushea el tag; crea el GitHub Release con esas notas.

No implementes nada tu mismo. Lanza el script y reporta el resultado.

## Flujo de extremo a extremo

```
/mefisto-release minor          # fase prepare -> abre PR release/vX.Y+1.0
/mefisto-merge <pr>             # mergea el PR a main (squash + delete-branch)
git pull --ff-only              # actualiza main local
/mefisto-release                # fase publish -> tag + GitHub Release
```

## Reglas

- **Nunca commitear directo a `main`**: la fase prepare siempre pasa por PR (`release/vX.Y.Z`). Esta es la unica excepcion permitida al contrato del repo y se respeta igualmente.
- **No bypasses**: si el script aborta por `[Unreleased]` vacio, falta de tag previo, `gh` no autenticado, working tree sucio o desfase con `origin/main`, no intentes saltartelo. Resuelve la precondicion y reintenta.
- **No tocar `.claude-plugin/marketplace.json`**: no lleva campo `version`.
- **No incluir el header `## [X.Y.Z] - ...`** en las notas del GitHub Release. Solo las subsecciones (`### Added`, `### Changed`, etc.) del bloque.
- **Idempotencia**: si el tag `vX.Y.Z` o el GitHub Release ya existen, el script aborta sin tocar nada.

## Reporte esperado

- **Tras prepare**: imprime el numero del PR creado y la siguiente instruccion (`/mefisto-merge <pr>` + `git pull --ff-only` + `/mefisto-release`).
- **Tras publish**: imprime la URL del release publicado y un resumen `vPREV -> vX.Y.Z`.
