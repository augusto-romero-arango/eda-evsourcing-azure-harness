---
fecha: 2026-08-04
hora: 17:37
sesion: mefisto-planner
tema: Investigacion de #463 (sampling de telemetria) -- standby con hallazgos registrados
---

## Contexto

Tras refinar #443 (field note `2026-08-04-1143`), se pregunto por que #463 seguia en
`estado:borrador` y se abrio su refinamiento. La investigacion cambio la naturaleza del issue,
asi que **se detuvo deliberadamente antes de tocar el body**: los hallazgos quedaron como
comentario fechado en el issue (`#463 issuecomment-5185385265`) y el issue sigue en borrador.

## Por que #463 estaba en borrador (respuesta a la pregunta que abrio la sesion)

No es un issue a medio escribir: es un **descarte con condicion registrada**. La field note
`2026-07-29-1628` lo pone en la seccion "Descartado" del refinamiento de #457:

> ADR nueva de observabilidad, por ahora. Con una condicion registrada: si nace, que nazca con
> #463 (sampling), donde si habra material transversal a los dos lados que justifique sede propia.

De esa sesion salieron 5 issues; #460, #462, #464 y #466 se cerraron el mismo dia. #463 quedo
abierto por ser el unico cuyo contenido era una decision pendiente, no una tarea. El riesgo que
lo acompañaba (`/mefisto-sequential 463` arrancaria sobre un draft sin CAs, hueco capturado en
#466) ya esta tapado: **#466 esta cerrado**.

## Descubrimientos

**1. La pregunta central del body ya estaba respondida, en tres sedes.** El marco ya decidio
delegar el ratio al consumidor: MEF-ADR-0034:224 (seccion 10 punto 4), regla absoluta 10 de
`projections-scaffolder.md:980`, y el precedente de MEF-ADR-0015:61-66. Refinar #463 no requeria
una decision de politica nueva -- ese encuadre era incorrecto.

**2. Lo que si esta mal es el mecanismo, no el ratio (verificado con fuente oficial).** El punto
de extension que documentan MEF-ADR-0034 §10.4 y el seam generado es
`SetSampler(ParentBasedSampler(TraceIdRatioBasedSampler(ratio)))` -- el sampler **generico de
OTel**. Pero `Azure.Monitor.OpenTelemetry.Exporter` 1.8.3, que el marco **ya referencia en ambos
lados**, expone sampling nativo: `AzureMonitorExporterOptions.SamplingRatio`, `TracesPerSecond`
y `EnableTraceBasedLogsSampler` (API .NET oficial). Y la doc conceptual dice que el sampler de
Azure Monitor es el que adjunta el rate a los spans *"so Application Insights can adjust
experience counts accurately"*, que evita trazas rotas y que **Live Metrics lo requiere para
compatibilidad** -- con `EnableLiveMetrics` activo por default en ese mismo exporter.

*No verificado, declarado como tal en el issue*: que el sampler generico produzca sub-conteo
medible. Confirmarlo pide un KQL sobre `itemCount` en un componente ya sampleado.

**3. El defecto no es teorico: el consumidor ya lo adopto, y desigualmente.** El marco no
samplea nada por si solo (100% de ingesta en ambos lados), pero `Bitakora.ControlAsistencia`
implemento el patron generico que el marco documenta:

| Artefacto | Sampler |
|---|---|
| `…Projections` (read) | si -- ratio 0.2 via `TELEMETRY_SAMPLING_RATIO`, CA-ADR-0009 |
| `…ControlHoras` (write) | si -- mismo patron, misma env var |
| `…Programacion` (write) | **no** |

Dos Function Apps del mismo BC con politicas de telemetria distintas. Consecuencia esperable de
que `domain-scaffolder.md` tenga **cero menciones de `Sampler`** (verificado con grep): sin punto
de extension documentado, se parchea a mano donde duele y no se propaga.

**4. El `samplingSettings` inerte se lee como activo, no solo como ambiguo.** El `host.json` real
del consumidor declara `"isEnabled": true` y `"maxTelemetryItemsPerSecond": 5` sobre un bloque que
`telemetryMode: OpenTelemetry` inhabilita por completo. El body de #463 lo describia como algo
que "puede leerse como si algo estuviera filtrando"; el dato real es mas fuerte.

## Decisiones

1. **#463 queda en standby**, en `estado:borrador`, sin tocar su body. Decision del dueño: el
   reencuadre se decide en frio.
2. **Los hallazgos se registran como comentario fechado**, no reescribiendo el body: preserva la
   trazabilidad de lo que decidio el refinamiento de #457 y separa evidencia nueva de encuadre
   original.
3. **Reencuadre propuesto, pendiente de aceptacion**: de "decidir la doctrina de sampling" a
   "corregir el mecanismo documentado y cerrar la asimetria write-side". Si se acepta, no haria
   falta ADR nueva (basta enmendar MEF-ADR-0034 §10.4 y añadir el equivalente write-side), y el
   issue baja mucho de costo.

## Descartado

- **Refinar #463 a `estado:listo` en esta sesion**: la decision del reencuadre es del dueño y no
  se fuerza dentro de la sesion que la descubre.
- **Reescribir el body con los hallazgos**: perderia la traza del encuadre original de #457.

## Preguntas abiertas

- **La que bloquea a #463**: se acepta el reencuadre? De eso depende si es un issue de tooling
  acotado (enmienda de ADR + punto de extension write-side) o una decision de politica con ADR
  nueva.
- Que hacer con el `samplingSettings` inerte (ahora con el agravante de `isEnabled: true`).
- Si `ParentBased` aporta algo real en el daemon; podria volverse discutible si se migra a
  `SamplingRatio` del exporter.
- **Consecuencia de campo sin dueño**: el consumidor corre hoy el patron generico en dos de sus
  tres artefactos. Si el hallazgo 2 se confirma, sus conteos y su Live Metrics estan degradados.
  Eso es un issue del consumidor (no de Mefisto) y **no se abrio**: el planner interno solo
  gestiona issues de este repo.

## Referencias

Issues tocados: **#463** (comentario con hallazgos; sigue en `estado:borrador`)
Issues creados: ninguno
Relacionados: #457 (lo abrio), #466 (cerro el riesgo del draft en el batch), MEF-ADR-0034 §10,
MEF-ADR-0015, MEF-ADR-0003 §Observabilidad, `CA-ADR-0009` del consumidor
Fuentes: Microsoft Learn — API `AzureMonitorExporterOptions`; "Sampling in Azure Monitor
Application Insights with OpenTelemetry"; "Configure Azure Monitor OpenTelemetry"
