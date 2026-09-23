---
fecha: 2026-09-16
hora: 14:32
sesion: mefisto-planner
tema: Refinamiento de lectores del contrato consumidor TDD
---

## Contexto
Se refino #1408, que agrupaba cinco agentes TDD con lecturas exclusivas del contrato legacy del consumidor.

## Descubrimientos
`{{mefisto:config-path}}` solo materializa hoy la ruta canonica literal, aunque `resolve_harness_config_path read` ya fija precedencia canonica, fallback legacy y no mezcla. No existe una directiva equivalente para el archivo efectivo de instrucciones.

## Decisiones
Se creo #1427 para centralizar `instructions-path` y convertir `config-path` en una ruta efectiva de lectura. #1408 queda acotado a `domain-scaffolder`; #1428, #1429, #1430 y #1431 cubren respectivamente `projection-test-writer`, `test-writer`, `implementer` y `smoke-test-writer`. #1411 declara ahora las cinco dependencias directas de agentes.

## Descartado
Se descarto repetir la precedencia canonica/fallback en cada agente y mantener los cinco agentes en un solo issue. Tambien se descarto retirar el fallback legacy, prohibido por MEF-ADR-0053.

## Preguntas abiertas
#1411 conserva pendiente elegir el consumidor de certificacion, separar o no Stage 2b/proyecciones y definir la evidencia versionada minima.

## Referencias
Issues creados: #1427, #1428, #1429, #1430, #1431. Issue refinado: #1408. Dependencias actualizadas: #1411.
