---
fecha: 2026-08-06
hora: 23:14
sesion: mefisto-planner
tema: politica de forma propia del read-side (inversion del draft #581 del consumidor) y su familia de issues
---

## Contexto

Sesion iniciada para revisar el draft #581, creado desde el consumidor Bitakora.ControlAsistencia,
que proponia que `ReadModels` referenciara `{Dominio}.DomainEvents` y que las vistas embebieran los
payloads de los eventos por defecto (motivado por homonimia en 2N archivos frontera del worker de
proyecciones de ese consumidor).

## Descubrimientos

- **Diagnostico sintoma-vs-enfermedad**: la homonimia del consumidor fue sintoma de vistas-espejo
  de objetos de dominio puros, nacidas sin knowledge crunching de la necesidad de lectura. Legalizar
  el embebido institucionalizaria la enfermedad. El marco decide lo contrario: la forma de la vista
  se deriva de la necesidad, nunca del evento ni del aggregate.
- **"Islas en las hojas, composicion en los procesos"**: `ReadModels` como cuarta isla (cero
  `ProjectReference`, statu quo estructural que se vuelve regla) completa la simetria de
  MEF-ADR-0039 decision 2 -- el Function App compone las tres islas de eventos; el worker compone
  `DomainEvents` + `ReadModels`, y la clase de proyeccion es el mapeo evento -> vista.
- **Naming sin sufijo de implementacion**: el read model lleva nombre valioso del lenguaje ubicuo,
  sin `View` (DDD: el nombre pertenece al dominio; el rol lo declara su ubicacion). La colision que
  el sufijo desambiguaba (`TurnoView`/`TurnoAggregateRoot` -> ambas `ObtenerTurno`) la disuelve
  mejor el termino propio.
- **Preguntas generativas, no de captura**: el crunching read-side del planner propone (persona ->
  decision -> campos -> filtros/paginacion) y el experto corrige (MEF-ADR-0008); el recorte de
  campos emerge de la entrevista, no de una pregunta aparte.
- **Precedente operacional**: `agents/projection-implementer.md` ya prohibia embeber tipos de
  `DomainEvents` en el read model -- la mitad de la politica existia; MEF-ADR-0041 la formaliza.
- **HTTP QUERY es RFC**: "The HTTP QUERY Method" (draft-ietf-httpbis-safe-method-w-body) aparece
  en el datatracker IETF como RFC publicado, Proposed Standard (rev. 14, junio 2026; numero exacto
  por confirmar). Metodo seguro e idempotente con body, relevante para filtros multiples.
- **Verificacion mecanica**: ni `coverage_classify_file` ni `detect_smoke_files` dependen del
  sufijo `View` (clasifican por contenido y por carpeta `Obtener/Listar`); los `TurnoView.cs` de
  los fixtures son cosmeticos.

## Decisiones

- La politica se fija en un **ADR nuevo (MEF-ADR-0041)** que enmienda puntualmente a
  0039/0035/0040/0006/0011 -- patron de politicas transversales (0039/0040), ancla citable unica.
- **Alcance greenfield-only**; migracion de consumidores como no-objetivo (patron 0039 decision 9).
- **Enforcement por tests de arquitectura desestimado por ahora** (pieza del draft original).
- La evidencia medida de 0034/0035 que cita `TurnoView` literal (mensajes reales de Marten) no se
  reescribe; solo ejemplos ilustrativos adoptan el naming nuevo.
- Corte en familia de issues: #581 (doctrina, raiz) -> #583 (crunching del planner + guardrail
  anti-homonimia de 3 fuentes + termino al glosario) / #584 (Agent Skill `projections`) / #588
  (agentes read-side). Orden de batch: `/mefisto-sequential 581 583 584 588`.
- Paginacion/filtros: el planner **captura** requisitos (#583); la **mecanica** (offset vs keyset,
  filtros multiples, eventual HTTP QUERY) es exploracion aparte (#587, borrador deliberado).

## Descartado

- La propuesta original del consumidor (`ReadModels -> DomainEvents` + embeber payloads):
  divergencia documentada, quedara en MEF-ADR-0041.
- Enmiendas distribuidas sin ADR nuevo (Alt 2 del issue).
- Conservar el sufijo `View` (Alt 3 del issue).
- "¿Que NO necesita ver?" como pregunta explicita del crunching: emerge de la entrevista de campos.
- Tests de arquitectura del read-side: desestimados por ahora, sin issue.

## Preguntas abiertas

- Numero exacto del RFC del metodo HTTP QUERY y su soporte end-to-end en Azure Functions isolated
  / APIM / ASP.NET Core (alcance de #587).
- Evidencia de ejecucion pendiente en el consumidor (#322/#323 de Bitakora.ControlAsistencia):
  el issue #581 lleva nota de verificacion estilo 0039.
- Registro de terminos de vista en el glosario: la mecanica exacta del YAML (¿categoria propia o
  terminos a secas?) la decidira la enmienda a 0040 en #581.

## Referencias

Issues creados: #583, #584, #587, #588. Issue reformulado: #581 (draft del consumidor -> doctrina
invertida, `estado:listo`). Promovidos a `estado:listo`: #581, #583, #584, #588. #587 queda
`estado:borrador` deliberado.
