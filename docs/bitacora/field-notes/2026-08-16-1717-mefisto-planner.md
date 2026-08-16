---
fecha: 2026-08-16
hora: 17:17
sesion: mefisto-planner
tema: veredicto del plan de velocidad interno + Fase 0 y plan de velocidad del pipeline TDD publicado (#645-#648)
---

## Contexto

El usuario pidio verificar con datos si las optimizaciones de velocidad/observabilidad del pipeline interno (plan de 5 pasos del 2026-07-31, paso 1 = bloque ECONOMIA DE TURNOS, PR #482) mejoraron el harness sin sacrificar calidad. Con el veredicto emitido, pidio trasladar los aprendizajes a un plan de mejora de tiempos para los agentes del pipeline TDD publicado, y ejecutar su Fase 0 (diagnostico retroactivo) en la misma sesion.

## Descubrimientos

**Veredicto del plan interno (criterio pre-escrito el 2026-07-31 se cumplio con holgura):**
- Turnos por issue: 85.1 (W31) -> 52.1 (W32) / 56.6 (W33) = -37% (proyeccion era -15/-25%). Wall media 18m00s -> 11m27s; P50 16m10s -> 9m42s (-40%). Costo mediano/issue $4.85 -> $3.59 (-26%).
- Calidad intacta por tres proxies: 0 corridas fallidas desde 08-06 (vs 20 previas), 0 issues con re-corridas desde 08-07 (vs 16/242), 0 reverts en 90 commits de agosto.
- El mecanismo coincide con el tratamiento: s/turno (~11-13s) y tokens_out/turno (~860) constantes — la caida es 100% turnos, exactamente el eje del paso 1.
- Matices: no-API subio +119% (33s -> 1m12s absoluto, costo visible de la observabilidad); %rd de cache 97.6% -> 94.1%. Paso 0 del plan (ventana-vs-ventana) resulto auto-resuelto: el bloque "QUE CRECIO" ya imprime con 2 meses instrumentados.

**Fase 0 del TDD publicado (retroactivo sobre transcripts, 200 sesiones / 57 issues de Bitakora.ControlAsistencia, jul-ago 2026, 34h wall):**
- La hipotesis "en TDD el tiempo se va en dotnet" es FALSA: dotnet = 11% del wall, tools = 14%, ~86% es API. El modelo wall ~= turnos x tok/turno / throughput transfiere (r +0.5..+0.98 por agente).
- Turnos por stage 3-4x peores que el interno pre-optimizacion: test-writer 118, reviewer 104, projection-tw 96, projection-im 86, implementer 74, smoke 52 (medianas agosto). s/turno: sonnet 4.5-6.0, opus 8.0.
- Deriva activa jul->ago: wall/issue 21.5m -> 38.7m (+80%), por doble via: sesiones/issue 3.0 -> 4.0 (smoke casi universal: 4/19 -> 28/38 issues) y turnos/stage (test-writer 78 -> 118, +51%).
- Sorpresa: el stage caro es el reviewer (opus, 14.8m), no el implementer (5.8m, el mas barato).
- El history del consumidor no registra smoke-test-writer, scaffold ni patch loops: ~5m/issue invisibles.
- Nada de la infraestructura interna (#431 traza, #426 metricas, #427 reporte, #481 bloque) existe del lado publicado; tdd-pipeline.sh invoca con --output-format text.

**Mecanica verificada durante el refinamiento:**
- La vista tmux tailea events.log, no los logs de stage: cambiar a stream-json no rompe la vista en vivo.
- El .log de texto tiene consumidores post-mortem (greps de clasificacion de fallo l.531-534): el porte exige derive_stage_log_from_stream.
- La linea TDD del history ya tiene claves por agente con duration: el esquema aditivo de #426 aplica limpio.
- El unico lector publicado del history es /work-status (skill LLM tolerante a claves extra).

## Decisiones

1. **Paso 1 del plan interno declarado exitoso.** Pasos pendientes: paso 3 (eje B) congelado — palanca riesgosa e innecesaria; paso 4 (modelos) innecesario — el costo ya bajo 26%; paso 2 (hooks PostToolUse) requiere re-medir la auto-verificacion residual antes de invertir (P50 ya esta bajo el nivel de junio).
2. **Plan TDD en 4 issues encadenados** (#645 traza -> #646 metricas -> #647 reporte -> #648 palanca), replicando la secuencia que funciono: medir -> baseline -> criterio pre-escrito -> una palanca -> veredicto.
3. **Alcance solo-TDD** (#645): tooling-pipeline.sh e iac-pipeline.sh no se cablean hasta que el patron demuestre valor (Rule of Three, MEF-ADR-0018). El helper queda en _pipeline-common.sh disponible.
4. **Esquema del history aditivo** (#646): metrics junto a duration en las claves existentes (con metrics.agent para las variantes projection-*), y 4 claves nuevas solo-cuando-corren: scaffolder, smoke-test-writer, patch-test-writer, patch-implementer. Los patch loops van al history (no solo a archivos) porque el reporte se alimenta solo de pipeline-history.jsonl.
5. **Reporte como script puro sin skill** (#647), segmentado por pipeline y stage con modelo declarado; ventana-vs-ventana con --desde/--hasta operativa desde el primer mes (no repetir la limitacion del interno).
6. **Bloque de economia de turnos en los 4 agentes** (#648, opcion B elegida por el usuario sobre la recomendacion de solo test-writer+reviewer): la atribucion por stage se preserva via el reporte de #647. Patch loops y scaffold quedan sin bloque.
7. **Criterio de exito pre-escrito en #648**: baseline agosto = test-writer 118 / reviewer 104 turnos, wall/issue P50 38.7m; proyeccion -30% de turnos en esos dos stages -> ~27-30m; si los turnos NO bajan, el diagnostico del eje A estaba incompleto y no se encadena nada mas. Proxies de calidad: coverage gate, frecuencia de patch loops, re-corridas, /fix-review, reverts.
8. Los 4 issues quedaron en estado:listo; #646/#647/#648 con label bloqueado. Batch sugerido: /mefisto-sequential 645 646 647 648.

## Descartado

- Portar el watchdog interno (run_agent_with_watchdog) y classify_agent_failure en #645: el TDD ya tiene watchdog SIGKILL propio; fuera de alcance.
- Extender la captura a tooling/iac del consumidor en esta tanda.
- Skill delgado para invocar el reporte de #647.
- Opcion A de #648 (bloque solo en test-writer y reviewer): recomendada por atribucion, el usuario prefirio cobertura completa.
- Copiar build_agents_history_json literal (es writer/reviewer-especifico): se generaliza a N stages.
- Tocar la clave coverage-gate existente del history.

## Preguntas abiertas

- **Smoke-test-writer casi universal** (28/38 issues, ~5.2m/issue): decision de alcance del pipeline pendiente de sesion propia — no es de velocidad de prompts.
- **Paso 2 del plan interno** (gates a hook PostToolUse): re-medir cuanta auto-verificacion queda en el pipeline interno antes de decidir; exige 2 PRs (MEF-ADR-0019 seccion E).
- El crecimiento del no-API interno (+119%): vigilar si sigue creciendo con mas observabilidad.
- La deriva de sesiones/issue del TDD (3.0 -> 4.0) solo se ataca parcialmente con #648: las rutas projection y el smoke universal son crecimiento estructural, no desperdicio.

## Referencias

Issues creados: #645 (traza stream-json en tdd-pipeline.sh), #646 (metricas por stage al history del consumidor), #647 (reporte agregado publicado), #648 (bloque de economia de turnos en los 4 prompts del TDD). Los 4 en estado:listo, cadena lineal 645->646->647->648.
Analisis Fase 0: /tmp/tdd-diag/ (analyze.py + sessions.json, efimero; las cifras relevantes quedaron en los bodies de los issues).
Veredicto del plan interno: baseline y criterio en la memoria del planner (project-mefisto-velocidad-plan-secuencia, 2026-07-31); cifras de la fila semanal de .claude/scripts/mefisto-metrics-report.sh (W31 vs W32/W33).
