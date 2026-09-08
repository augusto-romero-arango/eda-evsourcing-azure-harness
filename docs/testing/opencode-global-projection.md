# Proyección global OpenCode desde `active` (issue #1091)

## Entorno y fuentes

| Item | Valor |
|---|---|
| Fecha de verificación | 2026-09-08 |
| OpenCode mínimo probado | `1.18.29` |
| Shell | Bash 3.2 (macOS/Linux) |
| Configuración | [OpenCode Config](https://opencode.ai/docs/config/) |
| Discovery | [Commands](https://opencode.ai/docs/commands/), [Agents](https://opencode.ai/docs/agents/), [Skills](https://opencode.ai/docs/skills/) y [Plugins](https://opencode.ai/docs/plugins/) |

La documentación oficial declara los directorios globales bajo `<config>` para
esas capacidades. La sesión de descubrimiento se ejecutó con OpenCode `1.18.29`;
`<config>` se resolvió como `${XDG_CONFIG_HOME:-$HOME/.config}/opencode`, y como
`$OPENCODE_CONFIG_DIR` cuando este override estaba presente, sin excepción para
macOS. No se leyó `auth.json` ni otro auth store (MEF-ADR-0025).

## Procedimiento reproducible

```bash
export HOME="$(mktemp -d)"
export XDG_DATA_HOME="$HOME/data"
export XDG_CONFIG_HOME="$HOME/config"
M='<raíz-de-datos>/mefisto/active/bin/mefisto-opencode'
"$M" project
opencode agent list | grep mefisto-
opencode run --command 'mefisto:tooling' --auto --format json \
  'Responde solo PROYECCION_OK sin usar herramientas'
"$M" deactivate
```

Salida relevante de la sesión de 2026-09-08:

```text
Proyeccion OpenCode activa en .../config/opencode (release 1.2.3).
mefisto-writer
PROYECCION_OK
Proyeccion Mefisto retirada; la configuracion ajena permanece intacta.
```

El nombre del comando no se obtuvo de un listado de archivos: la invocación
`opencode run --command` hizo que OpenCode lo resolviera y ejecutara en una
sesión real. La misma ejecución comprobó `project` dos veces, cambió `active` de `1.2.3` a
`2.0.0`, y verificó que el comando descubierto leyera el contenido `2.0.0` a
través del enlace estable. Un archivo propio con el mismo nombre abortó con
`ERROR: conflicto:` sin modificación. `deactivate` retiró enlaces y su ledger,
pero conservó `opencode.json` y el comando propio; si Mefisto había creado un
directorio vacío, lo retiró.

La automatización reproducible de estos casos, incluidos `HOME`,
`XDG_CONFIG_HOME` y `OPENCODE_CONFIG_DIR` temporales, es
`scripts/tests/test-project-opencode-release.sh`. Esa prueba valida además los
directorios anidados de Skills, la restauración exacta de directorios previos,
el rechazo de un ledger ajeno y los fallbacks de configuración. La evidencia no considera la
mera presencia de archivos suficiente: registra el descubrimiento en una sesión
OpenCode y ejecuta la prueba aislada del mecanismo (MEF-ADR-0031).
