---
fecha: 2026-08-30
hora: 16:25
sesion: mefisto-planner
tema: refinamiento interno de la cadena MCP (#761, #767-#771) y desglose del borrador de metricas OTel (#764)
---

## Contexto
Los issues MCP (#761, #767-#771) llegaron desde el consumidor Bitakora.ControlAsistencia ya marcados `estado:listo` sin pasar por el refinamiento interno de Mefisto. Esta sesion los reviso uno a uno contra la revision de complejidad y el DoR.

## Descubrimientos
- La plantilla del modulo `function-app` en `agents/infra-base-scaffolder.md` (seccion 1.7) no expone el output `default_hostname` que el piloto MCP necesito: todo greenfield nace sin el. Causa raiz corregible en la plantilla (-> #772).
- La copia del workflow de deploy del consumidor (bajada de main) mezcla los estados de fase 2 y fase 3 (ya incluye el job de smoke); se dejo aclaracion en #769 para que el writer de fase 2 no lo genere.
- El piloto valido empiricamente el etiquetado de issues MCP en el consumidor: `tipo:feature` + `dom:` de los dominios consumidos paso por el pipeline TDD sin friccion (issue #502 del consumidor, PR #512). Se fijo como guia en el CA-3 de #771.

## Decisiones
- **Politica nueva de refinamiento (dictada por el usuario)**: los issues de Mefisto no referencian archivos de repos consumidores. Lo que se adopta viaja como copia local (comentario en el issue, neutralizado a `<RootNamespace>`/`{Proposito}`/`{Dominio}`) y los artefactos generados usan solo doctrina general aplicable a cualquier BC.
- #761: CA-6 reformulado -- el ADR se redacta como doctrina general, sin referencias normativas a consumidores; la evidencia del piloto queda en el issue, no en el ADR.
- #767: resuelta la indecision "si se decide enmienda" -- si hay enmienda al control de cambios de MEF-ADR-0013 (CA-7), patron establecido del indice.
- #768/#769/#770: copias locales neutralizadas adjuntas como comentarios (fase 1: 17 archivos; fase 2: tf + workflow + patch del modulo; fase 3: suite smoke + reusable).
- #769: CA-2 nuevo concreto -- el mcp-scaffolder agrega el output `default_hostname` idempotentemente si falta (reemplaza el vago "degrada a proponer").
- #771: seccion del planner con estructura "reconocer senal -> derivar -> handoff"; escape hatch a Agent Skill (MEF-ADR-0033) como propuesta revisable.
- #772 creado: agregar `default_hostname` a la plantilla de infra-base-scaffolder (independiente, sin bloqueo con #769).
- Orden de produccion: `/mefisto-sequential 761 767 768 769 770 771` + `/mefisto-tooling 772` en paralelo.
- #764 desglosado en 3 (espejo de la cadena MCP): #764 reescrito como enmienda a MEF-ADR-0038 (borrador+bloqueado, gate: evidencia empirica de #515/#517 del consumidor, que siguen sin implementar) + #777 (domain-scaffolder sin metricas) + #778 (projections-scaffolder solo `dotnet.gc.*`), ambos borrador bloqueados por #764.
- Verificacion parcial cerrada contra el README oficial del exporter (Azure/azure-sdk-for-net): `UseAzureMonitorExporter` es cross-cutting; la API por senal separada hace viable y documentado "no registrar el pipeline de metricas". NO VERIFICADO (lo cierra el piloto): supresibilidad de `_APPRESOURCEPREVIEW_` e inventario de meters auto-habilitados.

## Descartado
- Referenciar rutas del consumidor en Notas tecnicas (politica nueva).
- Purga de la seccion Origen: se conserva como proveniencia del issue (registro local legitimo), pero no alimenta los artefactos generados.

## Preguntas abiertas
- Los agentes del pipeline TDD del consumidor (test-writer/implementer) no tienen doctrina MCP explicita; el piloto paso sin friccion, pero si aparece friccion al escalar, evaluar un Agent Skill MCP para el lado consumidor.

## Referencias
Issues refinados: #761, #767, #768, #769, #770, #771; #764 reescrito (borrador con gate). Issues creados: #772, #777, #778.
Comentarios de copia local: 768#issuecomment-5470420750, 769#issuecomment-5470435627 (+aclaracion 5470945532), 770#issuecomment-5470947592.
