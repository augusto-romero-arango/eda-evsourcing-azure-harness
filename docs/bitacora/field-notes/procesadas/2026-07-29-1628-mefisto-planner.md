---
fecha: 2026-07-29
hora: 16:28
sesion: mefisto-planner
tema: refinamiento del draft #457 (observabilidad del worker de proyecciones)
---

## Contexto

Refinar el draft #457, que llegaba con dos frentes acoplados: (1) `projections-scaffolder`
no genera ningun seam de observabilidad para el worker read-side, y (2) el wildcard
`AddSource("X.*")` de la plantilla write-side descarta en silencio los spans de la
`ActivitySource` propia. El draft traia contexto de campo rico del consumidor
`Bitakora.ControlAsistencia` (tabla de `cloud_RoleName` de Application Insights con el
worker apareciendo como `unknown_service:dotnet`), mas cuatro puntos abiertos sin decidir.

## Descubrimientos

- **El cable de infraestructura ya existe conectado a un solo extremo.**
  `agents/infra-base-scaffolder.md:1651-1652` ya inyecta
  `APPLICATIONINSIGHTS_CONNECTION_STRING` en el Container App como Key Vault reference, y
  nada en el codigo del worker la consume. Reencuadra el issue: no es una funcionalidad
  ausente, es wiring a medio terminar con el costo de infraestructura ya asumido. Ese
  framing entro al Contexto de #457.
- **El App Insights es uno por ambiente** (`azurerm_application_insights` se crea dentro de
  `infra/environments/{env}/`). Elimina la unica razon para que `service.name` lleve el
  ambiente: el destino de la telemetria ya lo discrimina.
- **El write-side perdio su sampling sin reemplazo.** `domain-scaffolder.md:411` documenta
  que con `telemetryMode: "OpenTelemetry"` el `samplingSettings` de `host.json` queda
  **inerte**. Nadie lo sustituyo por un sampler de OTel: hoy el harness no samplea en
  ningun lado, y el bloque muerto puede leerse como si algo filtrara.
- **MEF-ADR-0034 acepto el costo del 24/7 solo de compute** (`:175`), nunca el de ingesta de
  telemetria que ese mismo `min_replicas >= 1` arrastra. Es el hueco real detras del debate
  del sampler.
- **En Mefisto no existe la nocion de oleadas paralelas.** Del lado interno solo hay
  `mefisto-sequential` (no hay `mefisto-parallel`), y `mefisto-batch-pipeline.sh:18-21`
  mergea el PR de cada eslabon y sincroniza main de forma verificada antes de arrancar el
  siguiente, "para que cada issue se implemente sobre el merge del anterior". Por tanto **dos
  issues que tocan el mismo archivo no son un conflicto**: es el caso para el que el motor
  esta diseñado. La matriz de impacto archivo-por-archivo del planner publicado (donde si
  existe `/parallel` con worktrees concurrentes) **no aplica a este repo**; lo unico que
  restringe el orden son las dependencias declaradas, que valida
  `mefisto-validate-batch-deps.sh`. Esta sesion escribio la nota equivocada en tres issues
  antes de corregirla -- si el `mefisto-planner` sigue emitiendo "notas de oleadas", conviene
  quitarle esa seccion del prompt.
- **La doctrina de observabilidad del marco existe, pero solo write-side**, repartida entre
  la seccion "Observabilidad" de MEF-ADR-0003 (`:135-159`) y su tabla de paquetes
  (`:33-36`). MEF-ADR-0034, sede del worker, no dice nada de telemetria.
- **MEF-ADR-0003 no necesita enmienda por el wildcard**: su linea 137 describe el registro
  como "AddSource para 'Wolverine', 'Marten' y el namespace del dominio" -- agnostico al
  patron. Eso mantuvo #460 en un solo archivo y fuera de `docs/adr/`.
- **El wildcard aparece en un unico lugar de todo el repo** (`domain-scaffolder.md:336`),
  verificado con grep sobre `agents/ skills/ docs/adr/ scripts/ .claude/`.
- **No pude verificar el anclaje del wildcard contra la fuente**: sin red en el entorno de
  planeacion. Quedo declarado como *no verificado* en #460 con la ruta exacta a inspeccionar
  (`src/Shared/WildcardHelper.cs`, metodo `GetWildcardRegex`) y una via alterna de
  experimento local, en vez de un "revalida" vago.

## Decisiones

1. **Partir el draft en dos**, con #460 (wildcard) **primero** y #457 dependiente de el.
   Razon: #460 es quien verifica el anclaje contra la version que el harness pinnea (1.13.1,
   no la 1.16.0 que midio el consumidor), y #457 escribe un `AddSource` nuevo que necesita
   ese veredicto. En orden inverso, el artefacto nuevo nace con el bug horneado -- lo que ya
   paso de verdad con `deploy-projections.yml` (#453).
2. **`service.name` derivado del ensamblado**, `Assembly.GetExecutingAssembly().GetName().Name!`,
   sin sustitucion de token por parte del agente. Alinea con el issue #263 del consumidor,
   reduce la superficie de error del scaffolder (el bug de #460 vive justo en una linea que
   si sustituye tokens) y ata `service.name` al nombre de la `ActivitySource` propia por
   construccion.
3. **Sin sampler en el seam generado**, pero con comentario doctrinal que señala el punto de
   extension, la propiedad del 24/7 y que el ratio es politica del consumidor. Argumento
   decisivo: instalar un sampler solo read-side crea una asimetria write/read **nueva**,
   justo el defecto que el issue cierra. Agravante: un ratio del 20 % en un scaffold recien
   nacido vuelve ambiguo el "no veo mi span" entre "wiring mal" y "me toco el 80 %".
4. **`service.version` con el SHA sale a issue propio (#462)**, dependiente de #453 y #457.
   El circuito exige tres piezas en dos agentes (ARG del Dockerfile, `--build-arg` del
   workflow que aun no existe, `AddService`); hacer dos de tres deja `InformationalVersion`
   en `1.0.0` a secas -- falsa trazabilidad en silencio, el mismo pecado que #457 corrige.
5. **Enmendar las dos ADRs existentes, sin crear una nueva.** MEF-ADR-0034 recibe la seccion
   de observabilidad del worker; MEF-ADR-0003 solo las filas de paquetes. Una ADR nueva
   obligaria a mover la seccion que ya vive en MEF-ADR-0003 para no duplicarla, convirtiendo
   un issue de tooling en un refactor de ADRs (y #430 ya muestra la friccion de tocar
   `docs/adr/`).
6. **`AddSource("Npgsql")` solo read-side**, asimetria deliberada y declarada como tal en el
   issue: el daemon poolea Postgres de forma sostenida. Si se quiere alinear el write-side,
   va en issue propio.

## Descartado

- **ADR nueva de observabilidad, por ahora.** Con una condicion registrada: si nace, que
  nazca con #463 (sampling), donde si habra material transversal a los dos lados que
  justifique sede propia y pague la consolidacion una sola vez.
- **Sampler generado por el marco** (lo que hizo el consumidor con su `CA-ADR-0009`).
- **`service.name` por-ambiente** (tipo `ca-asist-dev`): no puede vivir hardcodeado en codigo
  que se despliega a varios ambientes, y el App Insights por ambiente lo hace redundante.
- **`service.name` como literal hardcodeado** con token sustituido, frente a derivarlo por
  reflexion.
- **Enmendar MEF-ADR-0003 dentro de #460**: su texto es agnostico al patron de wildcard.

## Revision de #453 (misma sesion)

- **Sus dos dependencias declaradas como "bloqueantes reales" (#454, #456) ya estan CLOSED.**
  #453 es implementable ya. Su seccion `## Dependencias` estaba redactada en presente y se
  reescribio para no hacer esperar a quien lo implemente.
- **Defecto encontrado en #462, introducido en esta misma sesion.** Su CA-2 exigia pasar el
  `--build-arg` con `${{ github.event.workflow_run.head_sha || github.sha }}`, expresion
  importada del write-side. Pero la **decision 2 de #453** descarto deliberadamente el
  encadenamiento por `workflow_run` en `deploy-projections.yml` (trigger `push` a `main` +
  `workflow_dispatch`): ahi `github.event.workflow_run.head_sha` es **siempre nulo**.
  Corregido a `github.sha` a secas, con la advertencia de no copiar la expresion del
  write-side sin mirar el trigger. Leccion: copiar una plantilla write-side sin verificar su
  trigger es el mismo error de fondo que #457/#453 corrigen -- lo cometi planeando su arreglo.
- **Sinergia aprovechada**: #453 CA-4(c) ya tiene el SHA a mano para taggear la imagen. #462
  reutiliza **ese mismo valor** para el `--build-arg`, con lo que el tag del ACR y el
  `service.version` de la telemetria quedan identicos por construccion (una traza se
  correlaciona con el tag exacto, sin tabla de traduccion).
- **#458 (`.dockerignore`) queda como nota de relacion, no dependencia.** CA-4(b) de #453 fija
  el build context en la raiz del repo, asi que sin `.dockerignore` arrastra `.git/` y los
  `bin/`/`obj/` locales. No se elevo a bloqueante: el consumidor corrio el workflow
  end-to-end sin el, y no tiene sentido frenar un issue listo detras de un draft.

## Deuda del tooling interno detectada (capturada en #464 y #466)

Tres huecos que asomaron mientras se usaba el propio tooling en esta misma sesion. El hueco 1
quedo como **#464**; los huecos 2 y 3 se fusionaron en **#466** (mismo eje -- el gate de
admision admite lo que no debe -- y mismo par de archivos):

1. **El modo "oleadas" del prompt de `mefisto-planner`** hereda la matriz de impacto
   archivo-por-archivo del planner publicado, que no aplica a este repo (no hay
   `mefisto-parallel`). Hizo que esta sesion escribiera notas de paralelismo falsas en tres
   issues.
2. **`mefisto-sequential` no valida `estado:listo`.** Su paso 1 solo comprueba que el issue
   exista, no este CLOSED y tenga `tipo:tooling`: `/mefisto-sequential 463` arrancaria sobre
   un draft sin criterios de aceptacion.
3. **`mefisto-validate-batch-deps.sh:72` solo examina issues que ya tienen el label
   `bloqueado`.** Un issue que declara `Depende de #X` con #X abierto pero al que se le
   olvido el label pasa la validacion **en silencio**, y el batch lo corre antes que su
   dependencia. El label es una anotacion manual del planner: si falla, la salvaguarda
   automatica no existe.

## Preguntas abiertas

- Las cinco de #463 (draft): si el marco debe opinar sobre sampling o es del consumidor; que
  hacer con el `samplingSettings` inerte del `host.json`; si un ratio unico serviria para los
  dos lados; sede de la doctrina; y si `ParentBasedSampler` aporta algo real en un daemon
  cuyas trazas no tienen parent remoto.
- El veredicto de CA-1 de #460: si el anclaje del wildcard se comporta igual en 1.13.1 que en
  1.16.0. Si lo desmiente, #460 no debe aplicar su CA-2 y hay que reconsiderar el patron de
  #457.
- Si conviene registrar `Npgsql` tambien en el write-side (asimetria dejada a proposito).

## Referencias

Issues creados: #460 (wildcard, `estado:listo`), #462 (`service.version`, `estado:listo`
+ `bloqueado`), #463 (doctrina de sampling, `estado:borrador`).
Issues refinados: #457 (reescrito como Frente 1, `estado:borrador` -> `estado:listo`
+ `bloqueado`).

Issues revisados: #453 (ya `estado:listo`; dependencias satisfechas, notas ampliadas),
#462 (CA-2 corregida).
Issues de deuda del tooling interno: #464 (modo oleadas del planner), #466 (gate de admision
del batch). Los dos `estado:listo`, sin dependencias, en archivos disjuntos entre si y
disjuntos de los cuatro issues del frente de observabilidad.

**Orden de batch**: #460 antes de #457; #453 y #457 antes de #462. Es lo unico que restringe
el orden, y `mefisto-validate-batch-deps.sh` ya lo verifica solo a partir de la seccion
`## Dependencias` de cada issue.
