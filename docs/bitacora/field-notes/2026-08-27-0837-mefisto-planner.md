---
fecha: 2026-08-27
hora: 08:37
sesion: mefisto-planner
tema: refinamiento de #718/#722/#726 y desglose del estandar de nombramiento de recursos Azure (#729-#733)
---

## Contexto
Draft #718 creado desde el consumidor Bitakora.ControlAsistencia (planner del consumidor, 2026-08-27): `skills/projections/read-apis.md` instruye a consultar `Query<TView>()`/`LoadAsync<TView>()` sin `Schema.For<TView>()` nombrando solo tenancy como condicion de convergencia, pero Marten impone numeric revisions (`mt_version bigint`) al documento proyectado mientras el mapping por convencion del Function App espera `mt_version uuid` -> `42804` que tumba toda sesion del store del write-side. Dos ocurrencias reales en el consumidor (sus issues #294 y #448).

## Descubrimientos
- Causa raiz verificada en Mefisto: `read-apis.md:189-193` (gap real), MEF-ADR-0034 seccion 6 (par 2 con una sola instancia enumerada: tenancy documental), `agents/reviewer.md:257` (el gate no dispara con un PR que solo agrega una Function GET).
- Precedente interno ya conocido: MEF-ADR-0031 cita los desajustes de `mt_version` del consumidor (#294/#357) como historial.
- Patron nuevo del consumidor: **"oraculo literal espejo"** - un config-test por lado, cada uno en su proyecto sobre su propio store, afirmando los mismos tres literales (`Metadata.Revision.Enabled == true`, `Metadata.Revision.Type == "bigint"`, `Metadata.Version.Enabled == false`) via `Options.FindOrResolveDocumentType(typeof(TView))`. Literales espejo y no comparacion cruzada porque los proyectos de test no pueden referenciarse (MEF-ADR-0039).
- **Asimetria de autoridad**: el worker no declara nada - Marten impone la forma fisica (`ProjectionDocumentPolicy`); el Function App replica con `Schema.For<TView>().UseNumericRevisions(true)`. El oraculo se congela tambien en el worker para que un cambio de default de Marten ponga ambos lados en rojo juntos.
- El par sin exigencia simetrica se rompe: Bitakora #448 ocurrio porque la mitad del worker existia (PR #441) y la del Function App nunca se escribio cuando se agrego el `Query<AsistenciaDiaria>`. La receta debe exigir la mitad del Function App en el mismo issue que agrega la superficie de consulta.

## Decisiones
- #718 refinado a `estado:listo` con 5 CAs: receta canonica en `read-apis.md` (por documento, no por policy), doctrina del par espejo en `config-test.md`, enmienda a MEF-ADR-0034 seccion 6 (segunda instancia del par 2) + fila en la tabla del reviewer, fragmentos `changelog.d/`.
- Premisa del default de Marten pendiente de cita a doc oficial: queda como requisito del writer en CA-1 (validada empiricamente en el consumidor, no verificada aun contra la doc).
- Alcance de la segunda dimension del patron (tabla/tenancy/id) separado a issue propio (#722), refinado en la misma sesion.
- #722: la plantilla general del par espejo vive en `config-test.md` (seccion propia, `read-apis.md` solo referencia); tabla/tenancy/id se documenta con el patron regla + instancia enumerada (coherente con "regla, no lista cerrada" de MEF-ADR-0034 seccion 6); el reviewer gana una nota (verificar que el par de tests exista y sus literales coincidan) sin reestructurar sus tablas.
- Hallazgo en #722: la instancia tabla/tenancy/id convierte la tenancy documental (instancia 1 del par 2) en guarda siempre-activa, hoy solo verificada por el reviewer bajo gate.

## Descartado
- Sugerencia 3 del draft original (ampliar el trigger del gate del reviewer a diffs que agregan `Query<`/`LoadAsync<`): la guarda siempre-activa del par espejo corre en cada `dotnet test` y cubre el hueco sin depender del diff.

## Preguntas abiertas
- Ninguna: las tres preguntas de refinamiento de #722 (ubicacion de la plantilla, enumerar vs ejemplificar, forma del cambio en el reviewer) se resolvieron en la misma sesion.

## Refinamiento de #726 (misma sesion)
- Sintoma real: `/mefisto-sequential 718` aborto porque la rama activa era `docs/field-notes-refinamiento-718` (residuo de esta misma sesion de planner) - el gate de arranque de `mefisto-batch-pipeline.sh:306-318` trata como fatal un caso salvable.
- Hallazgo: el sync entre eslabones (#566) ya tolera rama activa != main a mitad de corrida (actualiza main por nombre, warning); el gate de arranque era mas estricto que el propio invariante del motor.
- Decision: opcion (a) auto-switch con arbol limpio (`git switch` + `pull --ff-only` + warning con la rama original); arbol sucio o ff-only fallido conservan el abort fail-loud. Test de fixture nuevo siguiendo el patron de `test-batch-sync-branch-race.sh`.
- Descartado: (b) degradar a warning sin switch - dejaria incumplida toda la corrida la premisa de higiene que justifica el gate.
- Verificado: el motor publicado `scripts/batch-pipeline.sh` no tiene gate de arranque de rama - sin simetria que aplicar (cerro el CA-4 abierto del draft). Precedente #711 confirma que los cambios internos tambien llevan fragmento en `changelog.d/`.

## Desglose del estandar de nombramiento de recursos Azure (misma sesion)
- Comparacion contra la suscripcion Azure Cosmos (2026-08-27): el estandar canonico de la organizacion es el patron CAF `{abrev-tipo}-[{uso}-]{app}-{env}-{region}-{seq}` (ej. `kv-asis-dev-eus2-001`, `pip-vm-appl-dev-eus2-001`; sin guiones para storage/ACR). Mefisto lo rompio en controlplane: sin region/secuencia, sufijos random (`kv-cplane-8iiups` ademas sin env), prefijo inventado `sbint-`, y sin abreviatura de tipo en observabilidad (`-logs`/`-ai`/`-cost-alerts` en vez de `log-`/`appi-`/`ag-`).
- `rg-mcperp-dev` tambien rompe el estandar pero no es de Mefisto: fuera de alcance.
- Decisiones: patron objetivo confirmado con region+seq desde `harness.config.json` (token nuevo `azureRegionShort`); los sufijos random desaparecen (fallback ante colision global: incrementar `{seq}`); la correccion es solo hacia el futuro - nada desplegado se renombra (destroy/create en Terraform); el "uso" va entre tipo y app (el dominio es el uso: `func-billing-cplane-dev-eus2-001`).
- Desglose en 5 issues: #729 (ADR nuevo + token, sin dependencias) -> #730 (infra-base-scaffolder) -> #733 (domain-scaffolder, depende tambien de #730 por los locals) ; #731 (apim-gateway-scaffolder) y #732 (bootstrap-backend.sh) solo dependen de #729. Batcheables en orden 729, 730, 733, 731, 732.
- Deuda M2 enlazada en #733: el truncado de storage no debe perpetuar la asuncion env=dev.

## Referencias
Issues creados: #722 (refinado a `estado:listo` en la misma sesion; conserva `bloqueado` por #718); #729 (`estado:listo`), #730/#731/#732/#733 (`estado:listo` + `bloqueado`)
Issues refinados: #718, #722 y #726 (`estado:borrador` -> `estado:listo`)
