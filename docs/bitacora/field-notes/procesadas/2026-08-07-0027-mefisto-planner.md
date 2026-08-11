---
fecha: 2026-08-07
hora: 00:27
sesion: mefisto-planner
tema: refinamiento de la familia de gates con punto ciego (fase roja TDD y coverage gate)
---

## Contexto

Sesion de refinamiento sobre dos drafts creados desde el consumidor Bitakora.ControlAsistencia (#585 y #586), ambos parte de una familia de tres gates del marco que fallaron sobre casos legitimos con la misma forma: una heuristica que asume el caso general sin declarar su punto ciego (el tercero, #568, ya estaba cerrado).

## Descubrimientos

- **La fase roja del TDD es estructuralmente inalcanzable** cuando la unica capa de test declarada en un issue `tipo:projection` es el test de composicion (MEF-ADR-0029): ese test verifica wiring del contenedor DI, nunca invoca `Run`, y pasa en cuanto el stub compila. No es un descuido del agente — `projection-test-writer.md:36` le ordena algo imposible en ese caso.
- **El patron de senal en `pipeline-state/` (MEF-ADR-0017) es reutilizable** como carve-out generico de gates: `refactor-signal.md` ya resolvio la ubicacion (fuera de `.claude/`, gitignored), el formato `JUSTIFICATION=`, la deteccion pre-existente para `--from-stage` y el viaje de la justificacion al reviewer y al PR (lineas 872 y 1600 de `tdd-pipeline.sh`).
- **`not_evaluated` y `excluded` se reportan con filas identicas** en los tres sitios de la tabla del coverage gate (`tdd-pipeline.sh` ~1093, ~1277, ~1505), anulando en la practica la mitigacion que MEF-ADR-0014:110 declara ("se reportan para revision humana").
- **El patron de logica del clasificador quedo desactualizado** frente al camino EventHandler de `Cosmos.EventDriven` 2.1.0: `*CommandHandler.cs` esta, `*EventHandler.cs` no.
- **Una de las propuestas del draft ya estaba resuelta**: la regla que exigia carpeta `/Eventos/` fue extendida por #567 (2026-08-05) a `\.DomainEvents$|\.DomainEvents/` — el consumidor observo una version anterior del plugin. Leccion: los drafts de consumidor traen contexto valioso pero hay que verificar cada afirmacion contra el codigo vigente del harness antes de refinar.

## Decisiones

- **#585**: via B (senal explicita del agente, gemela de `refactor-signal.md`) con mitigaciones — solo se honra en la ruta read-side (`STAGE1_AGENT = projection-test-writer`), exige `JUSTIFICATION=`, no salta el Stage 2 (a diferencia de refactor, hay implementacion por escribir), y queda visible en log y PR. Ademas se corrige el texto acusatorio del abort para el caso residual.
- **#586 se partio en dos** (un componente principal por issue): #586 reciclado para la visibilidad del reporte (etiqueta "sin clasificar", nota propia, terminologia en MEF-ADR-0014) y #590 nuevo para sumar `*EventHandler.cs` al patron de logica (clasificador + test + enmienda de la tabla de MEF-ADR-0014).
- Ambos enmiendan MEF-ADR-0014 en secciones distintas, cada uno con su fragmento `changelog.d/<issue>.adr-index.md` (convencion #380) — sin colision entre si.
- Los tres issues (#585, #586, #590) son independientes entre si: pueden ir en el mismo batch sin orden particular.

## Descartado

- **Via A del #585** (parsear `## Capas de test esperadas` en bash): fragil frente a la prosa libre del planner; acopla el gate al fraseo del issue.
- **Reformular la regla `/Eventos/`**: ya resuelta por #567.
- **Exigir cobertura a records con cuerpo** (`Equals`/`GetHashCode` custom): diferido por Rule of Three (MEF-ADR-0018) — la visibilidad nueva de #586 ya los pone frente al reviewer; endurecer espera casos reales.
- **Exigir justificacion del reviewer por cada sin-clasificar**: visibilidad primero, burocracia despues si los casos lo piden.

## Preguntas abiertas

- Si los records con cuerpo acumulan casos reales de bugs de igualdad silenciosos, retomar la regla diferida (candidato natural: tercer caso observado).
- La familia de "gates con punto ciego" ya tiene sus tres miembros atendidos; si aparece un cuarto, puede valer un patron transversal (todo gate declara su fallback y lo reporta distinto de sus decisiones).

## Referencias

Issues creados/refinados:
- #585 — Honrar una senal de fase roja no aplicable en el gate del Stage 1 del pipeline TDD (refinado, `estado:listo`)
- #586 — Distinguir en el reporte del coverage gate los archivos sin clasificar de los excluidos deliberadamente (reciclado del draft original, `estado:listo`)
- #590 — Sumar *EventHandler.cs al patron de logica del coverage gate (nuevo, desglose de #586, `estado:listo`)
