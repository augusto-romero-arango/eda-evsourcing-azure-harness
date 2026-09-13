---
fecha: 2026-09-12
hora: 13:50
sesion: mefisto-planner
tema: Release v0.37.11 para continuar la certificacion del consumidor
---

## Contexto
Con el baseline del consumidor desplegado y los defectos de OpenTelemetry y zona PostgreSQL corregidos en `main`, se solicito publicar una release patch antes de continuar con la certificacion multi-runtime #1180/#1181.

## Descubrimientos
- Desde `v0.37.10`, `main` acumulaba cinco merges: #1244, #1249, #1250, #1252 y #1253.
- Los fragmentos de changelog cubrian #1242, #1245, #1246, #1247 y #1251, incluido el fragmento de indice para la enmienda de MEF-ADR-0003.
- El pipeline canonico completo supero el gate de neutralidad, consolido los fragmentos, regenero identidad/manifiestos Claude, empaqueto OpenCode y verifico su checksum antes de publicar.
- El commit etiquetado es `07b4be654de7693f36e3aa1b8e376c9009b2665e`; su padre unico y commit fuente declarado es `3689c72b89c62a123a4d47e7d34ac193b4594098`.

## Decisiones
- Publicar un bump patch `0.37.10 -> 0.37.11`; los cambios corrigen defectos sin introducir una capacidad incompatible.
- Usar el encadenamiento por defecto de `/mefisto-release`: prepare, PR, squash merge, sync verificado y publish.
- Considerar `v0.37.11` la candidata que deben instalar tanto Claude Code como OpenCode antes de ejecutar #1180.
- #1248 no bloquea esta release ni la certificacion de tooling; sigue como mejora independiente del CI de PR para dominios.

## Descartado
- Continuar #1180 sobre `v0.37.10`: no contiene las correcciones ya verificadas durante la construccion del baseline.
- Usar `--prepare-only`: el usuario autorizo expresamente completar el release y el pipeline soporta el encadenamiento fail-loud.
- Incluir #1248 en el release por anticipado: permanece abierto y no es dependencia de #1180/#1181.

## Preguntas abiertas
- Actualizar el consumidor a `v0.37.11` en ambos runtimes y ejecutar `/mefisto:onboard` antes del preflight de #1180.
- Completar #1248 en un ciclo posterior y portar su workflow a consumidores ya scaffoldeados.

## Referencias
PR de release: #1254
Release: https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/releases/tag/v0.37.11
Asset OpenCode: `mefisto-opencode-v0.37.11.tar.gz`
Checksum OpenCode: `mefisto-opencode-v0.37.11.tar.gz.sha256`
Issues incluidos: #1242, #1245, #1246, #1247, #1251
