---
fecha: 2026-09-09
hora: 19:14
sesion: mefisto-planner
tema: Refinamiento de instalación y discovery multi-runtime
---

## Contexto

Se refinó #1180, segundo eslabón del gate consumidor multi-runtime, para precisar qué debe existir antes de instalar una release real y qué evidencia pertenece a instalación/discovery en vez de a la corrida E2E de #1181.

## Descubrimientos

- #1179 sigue abierto, v0.37.0 continúa siendo la última release y `augusto-romero-arango/mefisto-consumer-certification` todavía no existe.
- `/onboard` comprueba configuración, directivas, labels, CI OIDC, secretos declarados y otros aspectos Azure. Un resultado completamente verde implica un consumidor sustancialmente más amplio que el fixture mínimo requerido por `/mefisto:tooling`.
- El usuario eligió explícitamente un consumidor completo, con CI OIDC, recursos Azure, secretos e infraestructura, no un baseline mínimo de tooling.
- MEF-ADR-0053 distingue el commit fuente funcional del commit squash etiquetado. Ambos adaptadores declaran el primero en sus manifiestos.
- Los Agent Skills conservan `projections`/`comment-cleanup` en Claude y se adaptan como `mefisto-projections`/`mefisto-comment-cleanup` en OpenCode.
- `tooling-writer` y `tooling-reviewer` solo declaran capacidades `read`, `edit` y `shell`; Skills/MCP se certifican por discovery, no ampliando sus permisos.
- La raíz canónica que los hooks registran es `.mefisto/pipeline/.plugin-root`; Claude mantiene además el mirror legacy autorizado.
- Una dependencia abierta impide lanzar un issue, pero no completar su Definition of Ready: el estado correcto es `estado:listo` junto con `bloqueado`.

## Decisiones

- Mantener el aprovisionamiento completo fuera de #1180: pertenece al repo consumidor y debe planearse allí con el planner publicado, sin gestión cross-repo desde el planner interno.
- Exigir como preflight URL/SHA del baseline, `/mefisto:onboard` `LISTO` sin salvedades, CI verde e infraestructura dedicada verificable, sin persistir IDs sensibles ni valores de secretos.
- Exigir que `/mefisto-release patch` corra después de integrar #1179 y que la evidencia use el tag real, no `latest` ni la candidata v0.37.1 anticipada.
- Retirar los smokes destructivos de runtime ausente/deriva del alcance real; #1180 certifica el camino alineado y deja esos estados a las suites existentes.
- Mantener seis CAs homogéneos: baseline, release, instalación Claude, instalación OpenCode, discovery y diagnóstico/evidencia.
- Marcar #1180 como `estado:listo` y conservar `bloqueado`: el body ya decide contexto, componente, ADRs, dependencias y verificaciones; el protocolo, la release y el consumidor completo producen inputs de ejecución, no decisiones de planeación.

## Descartado

- Dejar #1180 en `estado:borrador` únicamente porque sus dependencias o referencias operacionales todavía no se materializaron.
- Convertir #1180 en el aprovisionador de Azure/CI del consumidor; mezclaría repositorios, componentes y una tarea de varias horas.
- Usar un baseline mínimo que permitiera `NO VERIFICADO` en Azure/CI.
- Desactivar instalaciones globales reales para reproducir estados negativos ya cubiertos por tests.
- Forzar Agent Skills o MCP dentro de los agentes tooling.

## Preguntas abiertas

- Plan e issues propios con los que el consumidor completo será creado y provisionado desde su repo.
- Tag, commit fuente, checksum y URLs de la primera release certificable posterior a v0.37.0.
- SHA baseline y enlaces de evidencia de onboarding/CI/infraestructura del consumidor.

## Referencias

Issue refinado: #1180

Dependencias y sucesores: #1179, #1181, #1066
