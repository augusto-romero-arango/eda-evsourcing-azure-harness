---
fecha: 2026-10-04
hora: "20:32"
sesion: mefisto-planner
tema: Refino del fallo de prepare de OpenCode en release
---

## Contexto
Refinar #1953 tras el fallo de publish de v0.41.0 posterior al merge del PR #1952.

## Descubrimientos
`prepare_metadata` ya genera ambas distribuciones; el stage omite tres salidas OpenCode de identidad y `validate_publish_delta` no las permite. El `--check` reproduce la divergencia sin alterar el checkout. El gate del packager aborta antes de tag/release.

## Decisiones
#1953 queda listo como bug de pipeline interno, con allowlist limitada a los tres archivos e indicaciones de prueba aislada, rollback y preservación de la relación padre/commit fuente de MEF-ADR-0053.

## Descartado
No editar `dist/opencode` a mano ni habilitar todo `dist/opencode/*` en el delta de release; no prometer que el fix de próximos prepare publica retrospectivamente v0.41.0.

## Preguntas abiertas
Recuperación de v0.41.0 ya mergeada sin violar el vínculo padre directo entre identidad y commit etiquetado: requiere plan separado.

## Referencias
Issues refinados: #1953 (Incluir assets OpenCode de identidad en prepare de /mefisto-release). PR observado: #1952.
