# src/internal/scripts/ -- Scripts canonicos internos de Mefisto

Layout canonico para los pipelines internos de Mefisto que son Bash + git +
`gh` + `jq` (MEF-ADR-0049 decision 2, issue #851): sin dependencia de ninguna
variable ni CLI de Claude Code. Analogo interno a `scripts/` (publicado), pero
de uso exclusivo del propio plugin -- no lo instala ningun proyecto
consumidor.

`.claude/scripts/` sigue siendo la superficie **estable** de invocacion
(`{{mefisto:run}}`, ver `src/internal/contract/README.md`): cada script que se
traslada aqui deja en su lugar un shim de compatibilidad de tres lineas, nunca
un `git mv` a secas que rompa a quien lo invoque por la ruta vieja.

## Plantilla del shim de compatibilidad

Literal, sin variaciones -- cada shim de `.claude/scripts/*.sh` que reenvia a
un script ya migrado tiene exactamente esta forma (3 lineas, resuelve la raiz
del repo desde su propio `$0`, nunca hardcodeada):

```bash
#!/usr/bin/env bash
# Shim de compatibilidad (MEF-ADR-0049): la implementacion canonica vive en src/internal/scripts/. No editar.
exec "$(cd "$(dirname "$0")/../.." && pwd)/src/internal/scripts/$(basename "$0")" "$@"
```

Reenvia `"$@"` y el exit code tal cual (via `exec`, sin logica propia). El
issue #873 verificara que todo `.claude/scripts/*.sh` sea, o bien un shim
conforme a esta plantilla, o bien un script explicitamente listado como
todavia-no-migrado.

Los shims se escriben **a mano**, copiando la plantilla; no los emite
`generate-internal-adapters.sh`. Es la excepcion deliberada al "los
adaptadores nunca se editan a mano" de MEF-ADR-0049 decision 2 -- esa regla
gobierna `.claude/{agents,commands}/`, que si son salida del generador --:
tres lineas identicas para todos, sin un solo campo que derive de la fuente
neutral, no justifican una etapa de generacion; lo que si hace falta es un
gate que verifique la conformidad, y ese es el trabajo de #873.

## Precedente: mefisto-release.sh (issue #864)

Primer script trasladado. Su unica referencia a `.claude/scripts/` es el
`source` de `_mefisto-common.sh` (issue #856), resuelto via `MEFISTO_REPO_ROOT`
-- nunca via `dirname "$0"`, porque el script ya no vive en ese directorio.
Es transitorio: cuando `_mefisto-common.sh` se traslade a
`src/internal/scripts/lib/` (issue #869), ese `source` pasa a resolverse igual
que el resto de la libreria (relativo al propio archivo).

## Deuda conocida: `python3` en el resumen del CHANGELOG

`mefisto-release.sh` usa `python3` en 6 puntos (extraccion y reescritura de
secciones del CHANGELOG, resumen de categorias del body del PR de release) --
preexistente a esta migracion, deliberadamente fuera de alcance del issue
#864. Es la unica dependencia de este directorio fuera del toolchain
bash + jq + git + gh; sustituirla por `awk`/`jq` es trabajo de un issue futuro.
