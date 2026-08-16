---
fecha: 2026-08-14
hora: 23:15
sesion: mefisto-planner
tema: doctrina de comentarios de codigo minimos + refinamiento del draft de ids URL-safe (#631)
---

## Contexto

Dos frentes en una sesion. Primero, el usuario quiere reducir la documentacion que los agentes escritores generan sobre el codigo del consumidor (narracion, provenance, comentarios que parafrasean) y dotar al reviewer de capacidad de limpieza — trajo como insumo una guia sintetizada con GPT ("Minimal Code Documentation Doctrine") para evaluacion critica. Segundo, refinar el draft #631 (politica de aceptacion de ids y codigos de negocio destinados a segmentos de URI), creado desde el consumidor Bitakora.ControlAsistencia.

## Descubrimientos

- **La guia de GPT es adoptable pero no verbatim**: su mejor pieza es el umbral doble (Context Delta + Decision Delta, sintesis propia de la guia, no terminologia de los repos que cita); sus referencias (AGENTS.md de Airflow, OpenHands, Vercel eve, OpenAI Apps SDK) son verificables. Pero su prohibicion de provenance choca con doctrina vigente del marco si se aplica sin regla de precedencia.
- **El `// HU-XX` del test-writer es provenance puro sin consumidor mecanico**: ningun script, gate ni agente lo consume (verificado por grep). Exactamente el tipo de comentario que la doctrina nueva proscribe.
- **Los templates de los scaffolders estan llenos de guardrails deliberados que citan ADRs** (ej. el "No limpies `using OpenTelemetry;`" del projections-scaffolder): en un repo conducido por agentes, la cita al ADR en un comentario es puntero operativo al guardrail, no historia. Una limpieza sin regla de precedencia los podaria.
- **Los comentarios HCL son hogar canonico de documentacion por doctrina vigente** (MEF-ADR-0027/0040 topologia de enrutamiento; MEF-ADR-0032 B6 notas de APIM): el modo limpieza no puede aplicar a HCL.
- **Trampa de replica parcial confirmada en la saga 0043**: `agents/planner.md` (linea ~200) y `agents/reviewer.md` (punto 3 del checklist) replican la precondicion URL-safe de forma parcial — tras la enmienda de #631 quedarian verdaderos-pero-incompletos, misma trampa que 0043 documento en `commands/implement.md` ("los 5 criterios").
- **MEF-ADR-0043 seccion 1 solo cubre el caso feliz** de ids URL-safe (constata que Guid canonico y `ComputarStreamId` cumplen); ni 0043 ni 0037 tienen el criterio de que hacer cuando el dato de negocio no nace URL-safe.

## Decisiones

Paquete de comentarios minimos (fase 1, issues #632-#635):

1. **Eliminar la convencion `// HU-XX`** del test-writer (proscrita en el ADR nuevo, retiro efectivo en #635).
2. **Regla de precedencia**: cita a ADR en comentario se conserva solo cuando acompana una restriccion local activa; cita sola es provenance y se poda; comentarios mandatados por ADRs del marco (MEF-ADR-0029, 0034) y guardrails de scaffolders se conservan.
3. **Alcance por lenguaje**: `.cs` pleno (umbral + limpieza); HCL solo criterio de escritura, sin modo limpieza; JSON/YAML fuera; markdown/bash del plugin fuera (posible fase 2).
4. **Frontera de limpieza estricta**: el reviewer limpia exclusivamente archivos que el PR interviene, nunca archivos externos al diff; behavior-preserving; sin doctrina de "issues de limpieza masiva".
5. **Reparto de doctrina**: pases de limpieza -> Agent Skill publicado `comment-cleanup` (precargado solo por el reviewer via `skills:`); doctrina compacta (~10 lineas) -> body de test-writer/implementer/smoke-test-writer, que no precargan el Skill.
6. **Nombre `comment-cleanup`** (no `code-comments`): nombre de accion, no de tema — el Skill limpia, no ensena a comentar.
7. **Corte en fases**: fase 1 = ADR (MEF-ADR-0044) + Skill + reviewer + escritores + linea en CLAUDE.md; fase 2 diferida (auditar plantillas de scaffolders, lado interno).

Refinamiento de #631:

8. **Enmienda a MEF-ADR-0043 seccion 1, no ADR nuevo**: el sujeto es la politica de aceptacion de datos destinados a URI y la seccion 1 ya es esa precondicion con la fuente correcta; un ADR nuevo fragmentaria la doctrina HTTP de comandos en lectura conjunta obligatoria.
9. **Contenido de la enmienda**: charset unreserved de RFC 3986 seccion 2.3 explicito; criterio rechazar-vs-normalizar segun quien es dueno del dato (dominio normaliza / tercero rechaza 400); momento de la invariante (issue previo dedicado, nunca el mismo PR que cambia rutas). Mecanismo no se reabre: cross-referencia a MEF-ADR-0037 seccion 2.
10. **Propagacion en issue aparte** (#636, planner + reviewer en un solo issue): delta menor que la saga original #628/#629, cambio homogeneo.

## Descartado

- **ADR nuevo para la politica de ids URL-safe**: descartado a favor de enmendar 0043 (fragmentacion de doctrina).
- **Nombre `code-comments`** para el Skill: ambiguo — nombra el tema, no la accion.
- **`minimal-comments`**: nombra el estado final, mismo problema.
- **Camino de "issues dedicados de limpieza masiva"** en el ADR de comentarios: el usuario fijo frontera estricta (solo archivos del PR); si algun dia hace falta, se planifica como issue normal sin doctrina especial.
- **Precargar el Skill `comment-cleanup` en los escritores**: ellos escriben, no limpian; la doctrina compacta basta y el contexto se paga en cada corrida.
- **Aplicar la guia de GPT verbatim**: cuatro fricciones documentadas (HU-XX mandatado, guardrails de scaffolders, HCL como hogar canonico, frontera de limpieza).

## Preguntas abiertas

- **Fase 2 de comentarios**: cuando auditar las plantillas de los scaffolders (domain, projections, infra-base, workos, apim) contra el umbral doble, y si el lado interno (bash/markdown del plugin) amerita doctrina propia. Sin issues creados, deliberadamente.
- **Redaccion final del bloque compacto**: #633 y #635 dependen del texto final de MEF-ADR-0044; el batch secuencial absorbe ajustes porque cada eslabon lee el ADR ya mergeado.

## Referencias

Issues creados: #632 (crear MEF-ADR-0044 doctrina de comentarios minimos), #633 (Agent Skill comment-cleanup), #634 (paso de limpieza en el reviewer), #635 (doctrina compacta en escritores + retiro de HU-XX), #636 (propagar enmienda 0043 a planner y reviewer).
Issues refinados: #631 (borrador -> listo, enmienda a MEF-ADR-0043; origen del consumidor preservado).
Orden de batch sugerido: `/mefisto-sequential 632 631 633 634 635 636` (cadenas 632->633->634->635 y 631->636).
Insumo externo: guia "Minimal Code Documentation Doctrine" (sintesis GPT del usuario), evaluada criticamente; sus decisiones adaptadas quedaron embebidas en el body de #632.
