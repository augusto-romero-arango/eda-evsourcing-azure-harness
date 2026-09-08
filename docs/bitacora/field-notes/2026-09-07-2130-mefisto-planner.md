---
fecha: 2026-09-07
hora: 21:30
sesion: mefisto-planner
tema: Refinamiento de la reconexión interna al núcleo común de runtime
---

## Contexto

Se solicitó refinar el issue #1046, que ya estaba marcado `estado:listo`, para revalidarlo contra el código actual y las extracciones de #1045 y #1072.

## Descubrimientos

- `src/internal/scripts/mefisto-tooling-pipeline.sh` todavía carga runtime, modelos y runner desde `src/internal/scripts/`; esa es la causa concreta que #1046 debe corregir después de las extracciones.
- La regresión interna ya está repartida entre `test-tooling-runtime-neutral.sh`, `test-mefisto-stage-models.sh`, `test-agent-hold.sh`, `test-agent-resume.sh` y `test-tooling-state-paths.sh`; no hace falta inventar un smoke con proveedores reales para una reconexión mecánica.
- Los permisos/frontmatter de agentes, el scope y `noninteractive-system.md` son política interna y no deben migrar a `src/runtime/`.

## Decisiones

- Se conservó #1046 como un solo issue de pipeline interno, con seis criterios homogéneos de reconexión y regresión.
- Se reemplazó la alternativa ambigua "smoke real o fixture equivalente" por fixtures reproducibles sin proveedor ni PR reales.
- Se declararon #1045 y #1072 como dependencias y #1062 como bloqueo descendente explícito.
- Se ampliaron los ADRs aplicables con MEF-ADR-0019 y MEF-ADR-0031, además de MEF-ADR-0049/0050/0051/0053.

## Descartado

- No se creó un issue adicional de certificación: la certificación distribuible real pertenece al corte vertical publicado gobernado por MEF-ADR-0053.
- No se propuso mover scope, permisos, prompts ni orquestación Git/PR al núcleo común.

## Preguntas abiertas

Ninguna para el Definition of Ready. #1046 permanece bloqueado mientras #1045 y #1072 sigan abiertos.

## Referencias

Issues creados: ninguno.

Drafts refinados: #1046 — Reconectar el tooling interno al núcleo común de runtime.
