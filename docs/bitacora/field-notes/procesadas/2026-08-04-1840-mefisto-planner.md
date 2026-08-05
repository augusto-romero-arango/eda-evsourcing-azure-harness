---
fecha: 2026-08-04
hora: 18:40
sesion: mefisto-planner
tema: refinamiento del draft #499 (formato de la conversion Guid->string del stream key)
---

## Contexto
El draft #499 nacio al refinar #483: el marco fija `StreamIdentity.AsString` y el formato de
`Guid.ToString()` es parte del contrato de datos sin estar fijado en ninguna parte. Traia cinco
preguntas abiertas explicitas (sede, alcance, politica del borde HTTP, verificacion Postgres,
guardrail). Sesion de refinamiento pregunta por pregunta hasta `estado:listo`.

## Descubrimientos
- Existen **dos clases de identidad de stream** que toda doctrina de formato debe tolerar:
  la que nace Guid y la natural compuesta (`EmpleadoId:Fecha` via `ComputarStreamId`). El usuario
  lo levanto como restriccion dura antes de cerrar el guardrail.
- **Principio unificador** que subsume el caso Guid: la representacion string se produce en un
  unico punto por aggregate (Guid -> `ToString()` sin argumentos; compuesta -> `ComputarStreamId`,
  que internamente aplica el mismo canon a sus componentes). Para claves compuestas la coherencia
  es por construccion, no por regla de formato.
- El tipado `Guid` del parametro de ruta en el GET implementa la normalizacion del borde a costo
  cero: el model binding tolera mayusculas y variantes, y `400` queda solo para texto no-Guid.

## Decisiones
1. **Sede**: ADR nuevo `MEF-ADR-0037` (par simetrico de MEF-ADR-0036). Descartadas la seccion en
   MEF-ADR-0012 y torcer MEF-ADR-0036.
2. **Borde HTTP**: normalizar (ley de Postel via tipado), no rechazar lo no canonico.
3. **Verificacion de sensibilidad a mayusculas en Postgres**: por via documental como CA del ADR;
   si no hay fuente, se declara no verificada. Sin verificacion empirica desde el harness.
4. **Guardrail**: sin helper de runtime (Rule of Three, MEF-ADR-0018; ademas viviria en el NuGet
   externo, fuera del harness). Guardrail = 3 chequeos del reviewer + doctrina en agentes.
5. **Desglose**: 4 issues -- #499 (el ADR, refinado en sitio preservando su seccion Origen) +
   #501 (implementer, write-side) + #502 (skill projections + projection-implementer, read-side) +
   #503 (reviewer). Los tres de propagacion dependen de #499 y llevan `bloqueado`.

## Descartado
- Helper del marco tipo `StreamKey.De(Guid)`: abstraccion sin tres casos, y fuera de alcance.
- Politica de rechazo (`400` a todo lo no canonico): hostil al cliente sin ganancia para el marco.
- Verificacion empirica contra Postgres/Marten desde el pipeline de tooling: no hay entorno.

## Preguntas abiertas
- El slug exacto del archivo del ADR (`mef-adr-0037-identidad-stream-representacion-string.md`
  es sugerencia; el writer puede ajustarlo manteniendo el patron).
- Si `projection-implementer` ya precarga el skill `projections` via frontmatter `skills:` --
  CA-3 de #502 lo deja como verificacion del writer.

## Referencias
Issues creados: #501, #502, #503. Refinado: #499 (borrador -> listo).
Orden de batch: 499 -> 501, 502, 503 (estos tres en cualquier orden entre si).
