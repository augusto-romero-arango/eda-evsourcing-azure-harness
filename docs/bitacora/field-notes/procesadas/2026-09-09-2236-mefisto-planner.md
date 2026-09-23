---
fecha: 2026-09-09
hora: 22:36
sesion: mefisto-planner
tema: Refinamiento del diagnóstico canónico de onboarding
---

## Contexto

Después de publicar Mefisto v0.37.1 se creó e inicializó el consumidor privado `augusto-romero-arango/mefisto-consumer-certification`. Su primera ejecución real de `/onboard` sobre el baseline `338a40136e500fdbafdccbda69a3caad512d1a78` produjo falsos `NO VERIFICADO` para tokens explícitos del config canónico y originó el draft #1204.

## Descubrimientos

- `load_harness_config` resuelve correctamente `.mefisto/harness.config.json` y exporta `HARNESS_CONFIG_PATH`.
- `scripts/onboard-diagnose.sh` conserva en paralelo `CONFIG=".claude/harness.config.json"`; las lecturas directas de tenancy y proyecciones usan esa ruta legacy aunque la carga principal haya elegido la canónica.
- `HARNESS_SECRETS_NAMES` vacío no permite distinguir `secrets[]` ausente de un array explícitamente vacío.
- El diagnóstico reduce `projections.enabled` ausente y `false` al mismo estado informativo, aunque MEF-ADR-0034 define `false` explícito como opt-out válido.

## Decisiones

- Refinar #1204 como un único issue del lado publicado: las dos manifestaciones pertenecen al mismo componente y al mismo eje, la resolución e interpretación del config efectivo.
- Mantener el fallback legacy de lectura exigido por MEF-ADR-0053; la corrección no migra ni duplica archivos del consumidor.
- Exigir regresiones integradas para precedencia canónica, fallback legacy, `secrets: []`, tenancy POC explícita y proyecciones deshabilitadas explícitamente.
- Marcar #1204 `estado:listo`; #1180 permanece `bloqueado` y declara la nueva dependencia.

## Descartado

- Duplicar `.mefisto/harness.config.json` en `.claude/harness.config.json` dentro del consumidor: ocultaría el defecto y violaría la precedencia canónica de MEF-ADR-0053.
- Partir el arreglo por token: produciría issues artificiales sobre las mismas líneas, pruebas y semántica del diagnóstico.
- Crear fuente neutral o adaptadores nuevos: `/onboard` sigue en el catálogo publicado legacy y este cambio no migra ese comando.

## Preguntas abiertas

- Después de integrar el fix será necesaria una nueva release para repetir el onboarding desde la distribución instalada; v0.37.1 debe conservarse como evidencia del hallazgo.
- Siguen pendientes las confirmaciones operacionales para provisionar labels, backend, CI OIDC e infraestructura Azure del consumidor.

## Referencias

Issues creados: ninguno en esta sesión de refinamiento. Issue refinado: #1204. Issue bloqueado: #1180. Consumidor: `augusto-romero-arango/mefisto-consumer-certification`.
