---
fecha: 2026-09-07
hora: 22:02
sesion: mefisto-planner
tema: Refinamiento del resolutor de harness.config #1049
---

## Contexto

Se solicito refinar el issue #1049, creado durante el desglose de la distribucion
multi-runtime publicada. El issue ya estaba marcado `estado:listo`, pero conservaba el label
`bloqueado` aunque su dependencia #1042 estaba cerrada y solo contemplaba migrar la lectura del
config.

## Descubrimientos

- `load_harness_config` y `upsert_harness_secret` comparten hoy el default
  `.claude/harness.config.json` en `scripts/_pipeline-common.sh`.
- Migrar solo `load_harness_config` dejaba un estado incoherente: un consumidor con config
  canonico podia cargar tokens y fallar despues cuando `/seed-secret` intentara escribir en la
  ruta legacy.
- El test existente `scripts/tests/test-harness-config.sh` ya cubre tanto la carga como el
  upsert, por lo que ambos comportamientos forman un corte homogeneo sobre un solo componente.
- MEF-ADR-0053, no MEF-ADR-0049, es la fuente directa de la decision sobre
  `.mefisto/harness.config.json`: lectura legacy indefinida y escritura solo canonica.

## Decisiones

- Por confirmacion del usuario, #1049 incluye tambien `upsert_harness_secret`.
- El resolutor tendra modos explicitos `read|write`: lectura canonica-primero con fallback y
  escritura exclusivamente canonica.
- `load_harness_config` exportara `HARNESS_CONFIG_PATH` para que migraciones posteriores no
  recompongan rutas inline.
- La validacion de JSON ocurrira antes de exportar tokens o reemplazar el archivo.
- #1049 queda sin dependencias abiertas y bloquea explicitamente #1051, #1061 y #1062.
- Se retiro el label `bloqueado`; se conservaron `tipo:tooling` y `estado:listo`.

## Descartado

- Migrar unicamente el lector y abrir otro issue para el escritor: separaba dos defaults del
  mismo archivo y dejaba temporalmente roto el flujo de escritura sobre un consumidor canonico.
- Migrar en #1049 todas las referencias inline de scripts, comandos y agentes: excede el
  componente principal y pertenece a los issues posteriores del rollout.
- Copiar o fusionar automaticamente el config legacy: contradice MEF-ADR-0053 y mutaria un
  archivo versionado sin decision explicita del consumidor.

## Preguntas abiertas

Ninguna para implementar #1049.

## Referencias

Issue refinado: #1049 "Resolver harness.config bajo .mefisto con fallback legacy".

ADRs: MEF-ADR-0019, MEF-ADR-0050 y MEF-ADR-0053.
