---
fecha: 2026-09-12
hora: 18:31
sesion: mefisto-planner
tema: publicación de la candidata multi-runtime v0.37.12
---

## Contexto

Después de reabrir #1180/#1181 y constatar que `v0.37.11` precedía las implementaciones de bootstrap, estado, exclusión y upgrade OpenCode, se solicitó publicar una release patch candidata para repetir la certificación operativa.

## Descubrimientos

- El flujo canónico `/mefisto-release patch` pudo ejecutarse desde `main` limpio y sincronizado; no había otro PR funcional abierto, solo el PR acumulativo de field notes #1243.
- La fuente funcional capturada por la release fue `e70e079a504a2e294a7877b51879e8160ea1fdcd`, que contiene los PRs #1259 y #1263-#1268.
- El PR mecánico de release fue #1269 y se integró por squash como `9a4ede84a11accfb25cd5e85ab6c39803c4af0c6`.
- El commit etiquetado tiene como padre único el commit fuente, conforme a MEF-ADR-0053.
- GitHub publicó el tarball OpenCode con SHA-256 `9792f461b9d9e2214fdfb3633a4b539236149332e5709ad88f593da8880e2b89` y su asset `.sha256` compañero.

## Decisiones

- Publicar patch `v0.37.12` mediante el encadenamiento automático prepare → merge → sync → publish; no usar `--prepare-only` ni editar metadata manualmente.
- Fijar `v0.37.12` como candidata concreta para repetir #1180 y #1181.
- Actualizar #1066 para sustituir el prerrequisito de release pendiente por la identidad concreta de `v0.37.12`; el issue conserva `estado:borrador`/`bloqueado` únicamente por la evidencia `PASA` aún ausente.
- Registrar en #1180 la identidad y assets, aclarando que publicar la candidata no equivale a certificarla y que el consumidor debe descargar/verificar el checksum real.

## Descartado

- Reutilizar `v0.37.11`: no contiene #1256/#1257/#1260/#1261/#1258.
- Preparar o modificar una rama de release manualmente: `/mefisto-release` es la única autoridad para CHANGELOG, metadata, tag y assets.
- Inferir `PASA` de la relación correcta tag/padre o de la existencia de assets: #1180/#1181 todavía deben ejecutar el protocolo real.

## Preguntas abiertas

- Evidencia sanitizada de instalación/discovery de `v0.37.12` en el consumidor (#1180).
- Evidencia de las dos corridas Herdr/tooling bajo Claude y OpenCode (#1181).

## Referencias

Release: https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/releases/tag/v0.37.12

PR de release: #1269.

Issues actualizados: #1066, #1180.

Fuentes: `src/internal/scripts/mefisto-release.sh`, `mefisto-manifest.json`, `src/published/release-identity.json`, MEF-ADR-0031 y MEF-ADR-0053.
