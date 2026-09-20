---
fecha: 2026-09-20
hora: 09:20
sesion: mefisto-planner
tema: priorizacion de issues borrador por refinar
---

## Contexto
Se revisaron los cinco issues abiertos con `estado:borrador` para recomendar cuales refinar y en que orden.

## Descubrimientos
El draft #1509 subestima el alcance: no son solo cinco tests internos; hay 25 `test-*.sh` versionados sin bit de ejecucion (5 internos y 20 publicados), y el inventario los filtra antes de validarlos. #1513 tiene causa y patron de arreglo confirmados. #1519 ya no bloquea #1496, cerrado. #1487 sigue bloqueado por #1464. #801 lleva mas de 7 dias y abarca varios componentes.

## Decisiones
Orden recomendado: tratar primero #1509 mediante desglose/decision de baseline y guard; despues #1513; luego #1519. No promover #1487 hasta que cierre #1464. No refinar #801 como una sola tarea: desglosarlo cuando exista un consumidor multi-entorno concreto o cerrarlo por ahora.

## Descartado
No se cambiaron labels ni bodies y no se crearon issues sin confirmacion del usuario.

## Preguntas abiertas
Decidir si los 25 tests omitidos deben activarse todos o si alguno merece una exclusion explicita; fijar para #1519 si el objetivo es el generador aislado o el presupuesto completo de 10 s del gate.

## Referencias
Issues creados: ninguno. Drafts revisados: #1509, #1513, #1519, #1487 y #801.
