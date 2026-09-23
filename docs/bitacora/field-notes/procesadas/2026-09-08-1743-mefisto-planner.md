---
fecha: 2026-09-08
hora: 17:43
sesion: mefisto-planner
tema: Refinamiento de la frontera headless publicada de tooling
---

## Contexto

Se continuo el corte vertical publicado con #1062, que debe reemplazar la invocacion directa de Claude en `scripts/tooling-pipeline.sh` por el runner neutral ya certificado internamente.

## Descubrimientos

- El pipeline publicado conserva cuatro caminos directos por `claude -p`: intento inicial, sonda de hold, retry por permisos y resolucion de conflictos a traves del mismo `run_agent`.
- La clasificacion publicada sigue leyendo texto/wire format y la reanudacion inspecciona el store privado bajo `~/.claude`; el contrato comun ya expone `error.kind`, `resets_at`, `session_id` y `denials` para retirar ambos acoplamientos.
- El pipeline interno es un precedente mecanico util, pero su presupuesto corto `MAX_ATTEMPTS` para indisponibilidad de proveedor no existe en el publicado. Importarlo cambiaria comportamiento en vez de preservar la politica vigente.
- #1063 ya es dueno de la migracion de paths, metricas, readers e identidad de version. Incluir esos cambios en #1062 duplicaria alcance.
- El packager OpenCode construye exclusivamente desde `dist/opencode/`, pero el generador solo proyecta Markdown de agentes/comandos. La release activa no contiene `scripts/tmux-pipeline.sh`, `scripts/tooling-pipeline.sh` ni `src/runtime/**`; resolver correctamente `MEFISTO_PACKAGE_ROOT` no basta para ejecutar el comando.
- La clausura de `tmux-pipeline.sh --tooling` incluye la delegacion opcional a `herdr-pipeline.sh` y su `stream-watch.sh`, ademas de `_pipeline-common.sh`, el pipeline tooling y el runner/librerias de runtime.

## Decisiones

- Se creo #1120 como prerrequisito independiente y listo para materializar, mediante lista explicita, la clausura ejecutable minima en ambas distribuciones.
- #1120 no copia `scripts/` o `src/runtime/` recursivamente: excluye pipelines fuera del corte, tests, fixtures y `runtime-fake.sh` del producto.
- #1062 queda limitado a la frontera `run_agent` y su politica inmediata. Usa ids `tooling-writer`/`tooling-reviewer`, perfiles `balanced`/`deep`, el resolutor comun y los eventos neutrales.
- `provider_unavailable` y `rate_limit` conservan el hold publicado vigente; solo los denials conservan el retry unico. No se porta el retry corto interno.
- Hold/resume usa `resets_at`, `session_id` y `runtime_<id>_supports_resume`; deja de inspeccionar stores privados del runtime.
- #1062 pasa a `estado:listo` y conserva `bloqueado` por #1060 y #1120.
- Se invirtio la relacion con #1061: el pipeline no necesita al comando para neutralizarse; el comando depende ahora de #1062 y #1120, ademas de #1054.
- #1066 declara #1061 como dependencia directa, porque la inversion anterior retiro esa transitividad.

## Descartado

- Absorber el empaquetado de scripts/runtime dentro de #1062: mezclaba materializacion de distribucion con un pipeline de mas de mil lineas.
- Empaquetar todo `scripts/`: expondria bajo OpenCode pipelines aun especificos de Claude, fuera del unico corte autorizado por MEF-ADR-0053.
- Hacer depender #1062 de #1054 o #1061: la fuente del pipeline puede resolver `src/runtime` desde su propia ubicacion; localizar la distribucion y lanzar el script son responsabilidades anteriores del comando/adaptador.
- Migrar observabilidad en #1062 o exigir aqui corridas reales por runtime: pertenecen a #1063 y #1066.
- Importar la orquestacion o `_mefisto-common.sh` interna al lado publicado.

## Preguntas abiertas

- #1120 debe decidir la representacion exacta del inventario estatico y del marcador generado sin romper shebangs ni sintaxis jq.
- Los wrappers tmux/Herdr conservan superficies para otros pipelines; la distribucion minima solo garantiza el camino `--tooling`. La certificacion debe comprobar que ninguna capacidad ausente degrade en silencio.

## Referencias

Issues creados: #1120

Drafts refinados: #1062

Issues ajustados: #1061, #1066
