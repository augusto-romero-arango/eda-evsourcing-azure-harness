---
fecha: 2026-07-27
hora: 11:48
sesion: mefisto-planner
tema: refinamiento de #412 -- las clases de proyeccion salen de ReadModels y se van al worker
---

## Contexto

El issue #412 llego desde el consumidor **Cosmos.ControlPlane** (autor `luisfelipediaz`, sin ningun label), reportando que MEF-ADR-0034 seccion 5 fuerza un `PackageReference` a Marten dentro de `<RootNamespace>.ReadModels` al ubicar ahi tanto los read models como las clases de proyeccion. El equipo de ese consumidor ya divergia deliberadamente del ADR (PRs #136/#137 de su repo) con la restriccion de que `ReadModels` no referencie Marten.

Se pidio refinarlo hasta `estado:listo`.

## Descubrimientos

- **La causa raiz esta en el harness, no en el consumidor.** `docs/adr/mef-adr-0034-...md` linea 57 y `agents/projections-scaffolder.md` Paso 1b (lineas 198-206) implementan exactamente lo que el consumidor reporta como defecto.
- **El alcance real es mayor que el reportado.** El issue enumeraba 5 cambios; el inventario completo es de **3 ADRs + 9 archivos de tooling**. El ADR que faltaba en el reporte es **MEF-ADR-0006**: su tabla de naming registra la clase de proyeccion companion como *"companion, N2 de MEF-ADR-0035"* y su nota del `partial` dice explicitamente que *"aplica tanto al read model auto-agregante de N1 como a la clase de proyeccion de N2"*.
- **N1 auto-agregante y "ReadModels sin Marten" son mutuamente excluyentes.** Si el record declara sus propios `Create`/`Apply`, el record *es* la clase de proyeccion y necesita el analizador en su ensamblado. Mover el record al worker no es opcion: el Function App del dominio lo necesita para el `LoadAsync<TView>()` del GET. Por eso el cambio de layout arrastra forzosamente un cambio de estilo canonico.
- **Ningun script bash cambia por el movimiento de archivos.** `classify_file` de `scripts/tdd-pipeline.sh` (lineas 1061-1132) clasifica por **basename**, no por proyecto. Consecuencia inesperada: la clasificacion de coverage de MEF-ADR-0034 seccion 9 **ya sobrepromete hoy** -- un `*Projection.cs` en `ReadModels` tampoco se mide (cae en `not_evaluated`).
- **Hueco latente en la ubicacion de los unit tests de proyeccion.** La doctrina no dice donde viven; el ejemplo `TurnoViewTests` de `projection-test-writer` implica el proyecto de tests del dominio, que hoy **no tiene** `ProjectReference` ni a `ReadModels` ni al worker. `tests/<Root>.Projections.Tests` si lo tiene (al worker, y a `ReadModels` transitivamente), asi que mover los tests ahi cierra el hueco sin tocar ningun `.csproj`.
- **Segundo hueco latente, no abordado**: nada cablea un `ProjectReference` de `ReadModels` desde el Function App del dominio (necesario para el GET) -- ni `domain-scaffolder` ni `projections-scaffolder`. Anotado en #413 como algo a reportar si se confirma al implementar, no a resolver ahi.
- **El mecanismo de `changelog.d/` es append-only para el indice de ADRs.** `consolidate_adr_index_fragments` apendiza filas nuevas al final de la tabla de `CLAUDE.md`; no reescribe filas existentes. Un issue que **enmienda** un ADR sin cambiar el tema de su fila no debe crear fragmento `.adr-index.md`.

## Decisiones

1. **Estilo canonico unico para N1 y N2**: clase de proyeccion companion `partial` en el worker (`SingleStreamProjection<TView, TId>` en N1, `MultiStreamProjection<TView, TId>` en N2), read model como record plano sin `partial`. El registro de N1 pasa de `Snapshot<TView>(SnapshotLifecycle.Async)` a `Add<{Concepto}Projection>(ProjectionLifecycle.Async)`. Articulado por el usuario: *"La clase de la proyeccion que tiene el create y apply esta en el repo de Projections. Los views que son records brutos son los que se quedan en readmodels. La intencion es compartir el readmodel con la funcion del get."*
2. **Ubicacion en el worker**: `src/<Root>.Projections/{Dominio}/{Concepto}Projection.cs` -- carpeta por dominio en la raiz, espejando las que el scaffolder ya crea en `ReadModels` (misma ruta relativa en ambos proyectos). `Program.cs` e `Infraestructura/` no se mueven.
3. **Unit tests de proyeccion**: `tests/<Root>.Projections.Tests/{Dominio}/{Concepto}ProjectionTests.cs`. Ese proyecto pasa a alojar dos cosas (config-test del `DocumentStore` + unit tests por dominio) y ningun `.csproj` cambia.
4. **Particion en dos issues + un draft**: doctrina primero (#412), propagacion despues (#413, `bloqueado`), y el classifier de coverage aparte (#414, borrador, independiente).
5. **MEF-ADR-0035 seccion 2 cierra su propio caveat**: el requisito `partial` aplica a la subclase de proyeccion con metodos convencionales, no al record auto-agregante -- lo dice literal el mensaje de error de Marten que el consumidor capturo. El ejemplo `QuestParty` de la doc oficial, que el ADR marcaba como *"posible desalineamiento"*, estaba bien.
6. **El mensaje de error de Marten queda documentado como engañoso**: apunta al ensamblado del **documento** (*"Ensure that analyzer runs in the assembly that defines ...AvailableTenantView"*), lo cual es falso con el layout de clase companion. Es probablemente el origen de la inferencia que el ADR original hizo.

## Descartado

- **Tres issues (doctrina / Skill+scaffolder / trio read-side)**: el usuario cerro en dos. La propagacion se implementa en un solo issue porque los 9 archivos reciben la misma decision aplicada mecanicamente, sin decisiones nuevas (las tres que faltaban quedaron cerradas en el cuerpo de #413).
- **Fragmento `.adr-index.md` en #412**: innecesario, el mecanismo solo apendiza filas nuevas y las tres filas ya existen con temas correctos.
- **Meter el ajuste de `classify_file` en la misma tanda**: el hueco es preexistente y ortogonal al layout; endurecer el gate puede romper pipelines de consumidores con proyecciones ya implementadas, asi que necesita su propia conversacion (#414).
- **Mantener N1 auto-agregante y aceptar Marten en `ReadModels`**: no cumple el objetivo del issue (el contrato compartido queda acoplado en lockstep de version).

## Preguntas abiertas

- El patron exacto del classifier (`*Projection.cs` a secas vs gateado por `IS_PROJECTION`) y si el `{Concepto}View.cs` (record plano de varias lineas) cae bien en la exclusion de "records DTO puros" del gate, que hoy exige <= 3 lineas de contenido -- ambas en #414.
- Si el `ProjectReference` de `ReadModels` desde el Function App del dominio debe cablearlo `domain-scaffolder` o `projections-scaffolder` -- se decide cuando se confirme el hueco al implementar #413.
- Ventana de desalineamiento entre #412 y #413: aceptada como transitoria y deliberada (doctrina primero), sin mitigacion adicional.

## Referencias

Issues creados: #413 (propagacion a tooling, `bloqueado` por #412), #414 (draft del classifier de coverage).
Issue refinado: #412 (`tipo:tooling` + `estado:listo`, titulo reescrito, cuerpo completo con seccion `## Origen` que preserva la verificacion de campo del consumidor).
Origen externo: PRs #136 y #137 de Cosmos.ControlPlane.
