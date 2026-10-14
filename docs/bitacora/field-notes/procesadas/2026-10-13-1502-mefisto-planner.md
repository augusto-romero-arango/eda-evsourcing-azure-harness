---
fecha: 2026-10-13
hora: 15:02
sesion: mefisto-planner
tema: Refinar #2390 (tolerancia a huecos de secuencia del daemon) con ADR
---

## Contexto
Refinamiento del borrador #2390, capturado desde Bitakora.ControlAsistencia tras el atasco del daemon de Programacion (hueco 1590, 21 smoke tests fallidos). El usuario pidio refinarlo con ADR y verificar versiones y configuracion reales en el consumidor.

## Descubrimientos
- El marco fija Cosmos.* 2.1.0 / Marten 9.12.0 (MEF-ADR-0003); el consumidor ya corre Cosmos.* 3.1.0 / Marten 9.23.0 (commit 64d289c1), bump que cerro GHSA-rfx3-98h7-v3xp / CVE-2026-75513 e implico ITenantResolver -> ITenantContext.
- `SkipStaleGapsDespiteLiveTransactionsAfter` y `GapLivenessProbe` no existen en Marten 9.12.0 (CS1061 por compilacion); existen en 9.23.0 y 9.37.0. La doc oficial fecha el mecanismo en 9.23.
- Existe una perilla que el consumidor no evaluo: `UseTransactionEvidenceForGapSkipping` (true por defecto); en false vuelve al salto por reloj.
- PoC por ejecucion (9.23.0): la opcion se lee solo con downcast `((DocumentStore)store).Options.Projections`; defaults `UseTransactionEvidenceForGapSkipping=True`, `UseAdvisoryLockTransaction=True`.
- Bitakora #993 (correccion del worker) sigue abierto; #992 ya mergeado.

## Decisiones
- Partir #2390 en tres: enmienda de MEF-ADR-0034 (#2390), bump del pin (#2394), emision en scaffold + guarda del config-test (#2395, depende de ambos).
- Doctrina: tope de 5 min por named store desde una fuente unica (`ConfiguracionDaemonProjections`), creada por domain-scaffolder si falta.
- Prohibir borrar mt_events/mt_streams con el daemon corriendo; purga solo por MEF-ADR-0036 seccion 5.

## Descartado
- `UseTransactionEvidenceForGapSkipping=false`, `UseAdvisoryLockTransaction=false`, `idle_in_transaction_session_timeout`, tope configurable por env var.
- Adoptar en el marco la limpieza por debajo de `min(last_seq_id)` (Bitakora #994): no verificada en el marco.

## Preguntas abiertas
- #2394 queda en borrador: delta de API 2.1.0 -> 3.1.0 por decompilacion, inventario de menciones a 9.12.0 y si partir pin vs migracion de tenancy. Prioridad alta por el CVE.
- Reporte upstream a JasperFx/marten (own_daemon_locks por store), en manos del humano.

## Referencias
Issues: #2390 (listo), #2395 (listo, bloqueado), #2394 (borrador).
