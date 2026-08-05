---
fecha: 2026-08-04
hora: 20:38
sesion: mefisto-planner
tema: refinamiento de #463 (doctrina de sampling) con evidencia de campo de Bitakora.ControlAsistencia
---

## Contexto

El usuario pidio primero el orden de batch de los pendientes (respuesta: 499 -> 501 -> 502 -> 503,
el batch de MEF-ADR-0037), y luego retomar el draft #463 (sampling de telemetria) moldeandolo con
la evidencia de los PRs #311 y #312 del consumidor Bitakora.ControlAsistencia (issues #308/#309),
mergeados hoy mismo, que resolvieron el problema en campo con verificacion por decompilacion,
reproduccion en runtime y mutation testing.

## Descubrimientos

- **El alcance del draft se quedaba corto**: no era solo "sampling" sino "control de volumen de
  telemetria". La evidencia agrego una dimension que el draft ni tenia: el durability agent de
  Wolverine (`FetchCountsAsync` cada 5s) es el 56% del polling write-side y se apaga en origen.
- **Gotcha del exporter (falla silenciosa de dos meses)**: `UseAzureMonitorExporter()` pisa
  cualquier `SetSampler` previo con `RateLimitedSampler(5/s)`. El fix es un segundo
  `.WithTracing(...)` encadenado despues del exporter.
- **Pregunta abierta del draft respondida empiricamente**: `ParentBasedSampler` en el worker NO es
  ornamental — es el mecanismo por el que el `Drop` del span raiz del daemon hace que el hijo
  Npgsql ni se instancie.
- **Guardrail determinista posible**: reflection sobre `TracerProviderSdk.Sampler` (internal) +
  `Sampler.Description` (publica, embebe el ratio). El borde critico es el default (la variable no
  esta declarada en ningun ambiente).
- **Gotchas heredables a los scaffolders**: el callback de `AgregarWolverineParaComandosServerless`
  corre antes de que CritterStack fije `Mode = Solo` (la bandera de metricas sobrevive, `Mode` no);
  `WolverineOptions` es `IAsyncDisposable` puro (tests de composicion con `await using`).

## Decisiones

1. **Postura del marco** (columna vertebral de MEF-ADR-0038): el marco genera el wiring correcto y
   los filtros de ruido en origen; el **valor** del ratio es politica del consumidor via
   `TELEMETRY_SAMPLING_RATIO`, con default 1.0 en greenfield (amable al diagnostico).
2. **Eliminar** el bloque `samplingSettings` inerte del `host.json` que genera `domain-scaffolder`
   (JSON no admite comentarios; bloque muerto que se lee como vivo = deuda de diagnostico).
   Invierte la nota actual "no lo elimines".
3. **ADR nuevo** (MEF-ADR-0038) como sede: consolida la seccion Observabilidad de MEF-ADR-0003 y
   enmienda MEF-ADR-0034 (costo de ingesta del 24/7 + seccion 10, que dejaba de prohibir el
   sampler). Cumple el criterio que #457 dejo fijado ("si nace, que nazca con este issue").
4. **Desglose en 5 issues** (patron del batch MEF-ADR-0037): #463 remodelado como el ADR;
   #511 (sampling write-side en domain-scaffolder), #512 (durability metrics en domain-scaffolder),
   #513 (sampler del worker en projections-scaffolder, reescribe la regla 10), #514 (chequeos del
   reviewer). #511 y #512 comparten archivo pero son temas independientes — compartir archivo no
   restringe nada en el pipeline secuencial interno.
5. La regla 10 de `projections-scaffolder` ("NUNCA instales ningun Sampler", CA-5 de #457) queda
   **superada** por la distincion mecanismo-del-marco / valor-del-consumidor.

## Descartado

- Enmendar MEF-ADR-0003 y 0034 sin ADR nuevo (dispersaria doctrina transversal y dejaria el
  material de Wolverine sin sede).
- Dejar el bloque `samplingSettings` en el host.json (status quo) o "comentarlo" (inviable en JSON).
- Fusionar #511 y #512 en un solo issue (~8 CAs heterogeneos; preferible dos claros y pequenos).
- Reexplorar alternativas ya demostradas muertas por el consumidor (documentadas en los issues):
  apagar `DaemonSettings.ActivitySource`, `BaseProcessor<Activity>`, `ApplicationInsightsSampler`.

## Preguntas abiertas

- El valor del ratio en ambientes maduros: el propio consumidor dejo dicho "medir antes de decidir".
  El marco solo fija el default 1.0; recalibrar es del consumidor.
- Numeracion 0038: asume que MEF-ADR-0037 (#499) merge primero. Nota tecnica en #463 por si no.
- CA-6 de #513: verificar si `skills/projections/` cita la regla del sampler (se resuelve al
  implementar).

## Referencias

Issues creados: #511, #512, #513, #514
Issue refinado: #463 (borrador -> listo, remodelado como "Escribir MEF-ADR-0038")
Evidencia: Bitakora.ControlAsistencia issues #308/#309, PRs #311/#312, CA-ADR-0009
Orden de batch sugerido (tras 499-503): `/mefisto-sequential 463 511 512 513 514`
