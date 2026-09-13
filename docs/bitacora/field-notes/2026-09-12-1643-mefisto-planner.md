---
fecha: 2026-09-12
hora: 16:43
sesion: mefisto-planner
tema: refinamiento bloqueado del veredicto multi-runtime
---

## Contexto

Se pidió refinar #1066 después de cerrar las implementaciones de bootstrap, estado, exclusión y upgrade OpenCode, y después del cierre aparente de #1180/#1181. El objetivo era llevar el veredicto del corte vertical a `estado:listo`.

## Descubrimientos

- El cierre de #1180 por el PR #1267 fue administrativo/documental: el propio PR afirma que no ejecutó instalaciones ni consultas al consumidor y que la certificación real seguía pendiente.
- El cierre de #1181 por el PR #1268 también fue administrativo/documental: el reviewer dejó CA-1 a CA-6 pendientes, sin fixtures, Herdr ni invocaciones reales de `/mefisto:tooling`.
- `docs/testing/opencode-consumer-cutover.md` conserva esos hechos: no existe expediente #1180 con veredicto `PASA`; no se crearon fixtures ni se ejecutaron las dos corridas de #1181.
- `v0.37.11` existe con ambos assets OpenCode y commit fuente `3689c72b89c62a123a4d47e7d34ac193b4594098`, pero precede las implementaciones #1257/#1260/#1261/#1258 integradas por los PRs #1263-#1266. No sirve como candidata para repetir la certificación de la nueva UX.
- El commit `main` observado después de esas implementaciones y de los PRs documentales fue `e70e079a504a2e294a7877b51879e8160ea1fdcd`; el tag concreto de la próxima candidata todavía no existe.
- Cerrar #1066 con `NO PASA` desbloquearía #1262 por estado GitHub aunque el gate hubiera fallado; por eso #1066 solo puede cerrarse con `PASA` y debe permanecer abierto/bloqueado ante un gap.

## Decisiones

- Reabrir #1180 y #1181 con comentarios que explican la diferencia entre entrega documental y certificación operativa.
- Restaurar `bloqueado` en #1181, que depende de un expediente #1180 `PASA`.
- Mantener #1066 como `estado:borrador` y agregar `bloqueado`; no cumple Definition of Ready todavía.
- Actualizar el body de #1066 con el estado real, la identidad histórica de `v0.37.11`, los PRs ya integrados y el requisito de una release candidata posterior a #1258.
- Fijar en CA-4/CA-6 que un resultado `NO PASA` conserva #1066 abierto/bloqueado y que solo `PASA` permite cerrarlo y retirar el bloqueo de #1262.
- La siguiente secuencia operacional es publicar una release patch desde el `main` actual, repetir #1180 hasta `PASA`, repetir #1181 hasta `PASA` y solo entonces completar el refinamiento de #1066.

## Descartado

- Marcar #1066 como listo basándose únicamente en que #1180/#1181 figuraban `CLOSED`: contradice la evidencia de sus PRs y MEF-ADR-0031.
- Tratar la existencia de `v0.37.11` como prueba de instalación/alineación: MEF-ADR-0053 exige operaciones reales sobre el consumidor.
- Usar `v0.37.11` para repetir: no contiene las implementaciones cuyo comportamiento se quiere certificar.
- Emitir y cerrar ahora un veredicto `NO PASA`: desbloquearía nominalmente la migración posterior aunque el gate siga fallido.

## Preguntas abiertas

- Tag, commit etiquetado, commit fuente y checksum concretos de la próxima release candidata.
- URLs, hashes y evidencia sanitizada del expediente #1180 `PASA`.
- Issues/PRs fixture y evidencia Herdr/tooling de #1181 `PASA`.

## Referencias

Issues actualizados: #1066, #1180, #1181.

PRs auditados: #1267, #1268.

Fuentes: `docs/testing/opencode-consumer-cutover.md`, `README.md`, `mefisto-manifest.json`, MEF-ADR-0019, MEF-ADR-0025, MEF-ADR-0031, MEF-ADR-0049, MEF-ADR-0050 y MEF-ADR-0053.
