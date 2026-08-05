---
fecha: 2026-07-29
hora: 15:53
sesion: mefisto-planner
tema: refinamiento de #452 (rollForward del SDK) y de #453 (deploy del worker de proyecciones + filtros de paths)
---

## Contexto

Dos drafts creados el mismo dia desde el consumidor `Bitakora.ControlAsistencia`, ambos
nacidos del mismo incidente: el `docker build` del worker de proyecciones fallando con
exit 155 al publicar la imagen. Los dos llegaron con investigacion de campo densa y un fix
ya verificado en PRs reales del consumidor.

Resultado: #452 refinado tal cual, y #453 partido en tres issues (#454, #456, #453).

---

# Parte 1 -- #452 (rollForward del SDK en el `global.json` que emiten los scaffolders)

## Descubrimientos

- **Causa confirmada en el harness** (no era problema del consumidor): el bloque
  `global.json` con `"version": "10.0.201"` + `"rollForward": "latestPatch"` esta
  **duplicado literal** en `agents/domain-scaffolder.md` (Paso 3) y
  `agents/projections-scaffolder.md` (Paso 3), y el Dockerfile que emite el segundo usa
  tags **flotantes** (`dotnet/sdk:10.0`, `dotnet/runtime:10.0`). Feature band pineada
  contra tag flotante = incompatible por construccion.
- **`version` es un piso minimo, tambien con `latestFeature`** -- no "la version que se
  usa". La doc oficial: *"a feature band and patch level that's greater than or equal to
  the specified value"*. El draft no lo contemplaba: cambiar solo el `rollForward` deja el
  piso en la banda `2xx` y excluye la `1xx`.
- **.NET 10 sirve dos bandas en paralelo, no una progresion lineal.** El release 10.0.10
  (2026-07-14) publico `10.0.110` **y** `10.0.302`; la banda `1xx` (canal de Visual
  Studio) recibe parche cada mes igual que la `3xx`. Dato de
  `builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json`. Esto invalido
  el consejo inicial que le habia dado al usuario ("bajar el piso a `10.0.100`" como si la
  `1xx` fuera vieja) y hubo que corregirlo en la conversacion.
- **`test.runner` de `global.json` esta disponible "since .NET 10.0 SDK"**, o sea desde
  `10.0.100`: ninguna banda de `10.0` invalida el requisito de xunit v3 mtp-v2, asi que el
  piso se puede mover libremente dentro de `10.0.x`.
- **El pin no toca CI ni Docker**: el harness genera `setup-dotnet` con
  `dotnet-version: '10.0.x'` (3 sitios en `domain-scaffolder`), que resuelve a la ultima.
  El piso alto solo afecta maquinas de desarrollo.
- **Tres menciones historicas a `10.0.201`** en `projections-scaffolder` (lineas ~81, ~96,
  ~118) son registro de con que SDK se verifico la receta, no requisitos. Un find/replace
  ciego las corromperia afirmando una verificacion que nunca se corrio -> quedo como CA
  explicito de **no** tocarlas.
- **No hay ADR que gobierne el pin del SDK.** MEF-ADR-0034 origina el Dockerfile afectado
  (seccion 8: Container App sin ingress -> imagen `runtime`, no `aspnet`) pero no dice nada
  del `rollForward`. Ningun ADR se enmienda.
- **Ningun test valida `global.json`** (grep sobre `scripts/tests/`, `agents/`, `commands/`,
  `scripts/`, `skills/`, `.claude/`). El defecto no tenia red que lo atrapara.
- **Un resultado verificado puede podrirse sin que nadie toque una linea.** El CHANGELOG de
  la 0.19.0 registra el `docker build` en verde, y era cierto cuando se corrio: entonces
  `sdk:10.0` servia una `10.0.2xx`. La verificacion tenia fecha de vencimiento y eso no
  quedo registrado como tal.

## Decisiones

- **Greenfield-only.** Ambos agentes instruyen hoy no tocar un `global.json` preexistente;
  esa regla **se preserva** y el issue no agrega migracion. Consecuencia aceptada: los
  consumidores ya scaffoldeados siguen con `latestPatch` hasta que alguien lo edite a mano.
- **Piso a `10.0.300` + `rollForward: latestFeature`**, divergiendo del precedente del
  consumidor (que solo cambio el `rollForward`, dejando `10.0.201`). Criterio del usuario,
  textual: *"quiero estar en la banda mas alta que sea compatible, asi a mi me toque
  instalar otro sdk"*. Costo aceptado explicitamente: excluye a quien tenga `10.0.110`,
  que esta al dia y no es un rezagado.
- **#452 promovido a `estado:listo`** con `bug` + `tipo:tooling`. 6 CAs homogeneos, un
  componente, lado publicado, cambio de texto: pasa la revision de complejidad.
- Los dos agentes se cambian **en el mismo issue** aunque sean dos archivos: el bloque es
  duplicado literal y partirlo dejaria drift entre ellos.

## Descartado

- **Bajar el piso a `10.0.100`** (ejemplo canonico de la doc oficial): descartado a favor
  de la banda mas alta, por decision del usuario.
- **Subir el `version` manteniendo `latestPatch`**: arregla hoy, vuelve a romper con la
  banda `4xx`. Ya venia descartado del consumidor.
- **Pinear la imagen base a un tag con `10.0.2xx`**: acopla el Dockerfile a un digest que
  hay que mover a mano. Ya venia descartado del consumidor.
- **Migrar el `rollForward` heredado en consumidores ya scaffoldeados**: descartado (ver
  decision greenfield-only).
- **Mecanismo para avisarle al desarrollador que suba de SDK.** El usuario lo pidio a mitad
  de sesion y luego lo descarto explicitamente al ver las dos formas posibles: propagar el
  piso nuevo a consumidores existentes, o dar un mensaje propio en el momento del fallo.
  Sin issue hermano. Razon de fondo: con el piso en `10.0.300` el mensaje nativo del SDK ya
  es accionable, a diferencia del caso original donde pedia `10.0.201` teniendo instalado un
  `10.0.302` mas nuevo. Nota para quien lo retome: un `<Error>` custom en
  `Directory.Build.props` **no** cubre este escenario -- el muxer del SDK rechaza antes de
  que MSBuild corra.

---

# Parte 2 -- #453 (deploy del worker de proyecciones), partido en tres

## Descubrimientos

El draft traia cuatro puntos abiertos. Verificarlos cambio el alcance: **dos se resolvieron
solos, uno se confirmo y saco trabajo a otro agente, y uno se cerro con analisis.**

- **El punto abierto de autenticacion se apoyaba en una premisa falsa.** El draft decia que
  generar OIDC seria *"incoherente con lo que generan hoy los demas workflows"*. **El
  harness ya genera OIDC en sus cuatro workflows**: `domain-scaffolder:2474-2476` e
  `infra-base-scaffolder:1915-1917` emiten `azure/login@v3` con
  `client-id: ${{ secrets.AZURE_CLIENT_ID }}` y `permissions: id-token: write`, citando
  MEF-ADR-0022 y diciendo *"en vez del JSON unico `AZURE_CREDENTIALS`"*. Lo desviado es el
  consumidor, no el harness -- el investigador parece haber mirado los workflows de Bitakora
  y concluido que el harness generaba lo mismo. Se cae tambien el corolario del draft de que
  *"esta decision aplica a los cuatro generadores"*: no hay nada que decidir ni propagar.
- **El `ignore_changes` sobre la imagen del Container App falta, y es trabajo de otro
  agente.** Los cinco bloques `lifecycle` de `infra-base-scaffolder.md` estan en los modulos
  con estado (~94-819); el modulo `container-app` (~985-1160, `image = var.image` en 1115)
  no tiene ninguno, ni `precondition`. Divergencia a tener presente: en el consumidor el
  bloque `lifecycle` **ya existia** con dos `precondition` y el `ignore_changes` se sumo
  dentro; en el harness hay que **crearlo**.
- **`<SolutionFile>` no debe entrar en el filtro del write-side**, aunque el job si corre
  `dotnet restore/build <SolutionFile>` (lineas ~2418-2421). Cuando el `.slnx` cambia por
  este dominio ya viene con cambios en `src/<RootNamespace>.{PascalCase}/**` que disparan
  igual; cuando cambia por otro dominio, el binario de este no se altera. Agregarlo solo
  compraria N deploys espurios por cada scaffold nuevo.
- **`infra/**` en el filtro de paths del write-side seria una regresion, no una mejora.** El
  draft afirmaba que en el write-side *"`infra/environments/<env>/**` si corresponde"*.
  Incorrecto para el harness vigente: el issue #197 / MEF-ADR-0022 **movio** ese trigger a
  `infra-cd.yml` y encadena por `workflow_run` (nota de la linea ~2504). Quedo como CA
  negativo explicito en #454 para que el writer no lo agregue siguiendo el draft.
- **Los `smoke-tests*` no necesitan el arreglo de filtros**: `smoke-tests-dominio.yml` es
  `workflow_call` y `smoke-tests.yml` usa `workflow_dispatch` + `schedule`; ninguno declara
  `paths`.
- **El harness ya escribio la especificacion del artefacto que le falta.**
  `infra-base-scaffolder.md` (Nota operativa 2, ~1160) describe que debe hacer el pipeline
  de imagen *"cuando se implemente"*, y expone el output que necesitaria (~1742). MEF-ADR-0034
  seccion 8 **no** excluye el pipeline del harness: lo excluye del alcance del issue #368 y
  da por sentado que existe. No hay ADR que enmendar -- es un hueco sin dueno asignado.
- **El job `determinar-alcance` no estorba**: solo filtra cuando el evento es `workflow_run`
  (`if [ "$github.event_name" != "workflow_run" ]` -> despliega siempre), asi que un `push`
  que toque `global.json` entra por la rama "siempre despliega".

## Decisiones

- **Partido en tres issues, uno por agente**, con la dependencia de orden que el propio
  draft senalaba:

  | # | Trabajo | Archivo | Depende |
  |---|---|---|---|
  | #454 | `global.json` + el propio workflow en `paths` | `agents/domain-scaffolder.md` | -- |
  | #456 | `ignore_changes` sobre la imagen | `agents/infra-base-scaffolder.md` | -- |
  | #453 | Generar `deploy-projections.yml` | `agents/projections-scaffolder.md` | #454, #456 |

  #454 y #456 son independientes entre si (agentes distintos, paralelizables). #453 queda
  con label `bloqueado` y su `## Dependencias` en formato canonico `Depende de #NNN`.
- **#453 se retitulo** recortando la segunda mitad ("y cubrir los inputs del build en los
  filtros de paths"), que ahora es #454.
- **#453 lleva 7 CAs, uno por encima del limite**, justificado por homogeneidad y declarado
  como tal dentro del issue: todos describen partes de un unico artefacto (un workflow
  generado por un paso nuevo). Partirlo dejaria mitades de un solo YAML sin valor
  independiente.
- **`projections-scaffolder` es el dueno del nuevo workflow**, no `domain-scaffolder`
  (cardinalidad equivocada: corre por dominio, el artefacto es uno por BC) ni
  `infra-base-scaffolder` (romperia la separacion infra/codigo que el write-side mantiene).
  Argumento decisivo: el agente que scaffoldea el codigo es dueno de su deploy, y este ya
  genera el Dockerfile que el workflow construye.
- **Sin `workflow_run` tras `Infra CD` en el read-side**, a diferencia del write-side. El
  requisito de MEF-ADR-0034 (correr despues del sembrado de secretos) es una precondicion de
  **bootstrap** ("al menos una vez"), no un orden por-commit, y con el `ignore_changes` de
  #456 un apply normal ya no toca la imagen. El caso residual (un apply que **recree** el
  Container App, dejandolo con el placeholder) se cubre documentandolo en la cabecera y con
  `workflow_dispatch`. Si se demuestra que ocurre en la practica, encadenar por
  `workflow_run` es mejora posterior con issue propio.
- **Nombre del repositorio de imagen en el ACR: `projections`.** Contractual solo que el tag
  incluya el SHA.

## Descartado

- **Refinar #453 como un solo issue de dos frentes**: son tres agentes distintos con una
  dependencia de orden real; el propio draft pedia cerrar el frente de filtros antes de
  escribir el generador.
- **Meter el `ignore_changes` dentro del issue del workflow**: es otro agente y otro
  artefacto (HCL vs YAML), y en el consumidor tuvo que estar en `main` **antes** de la
  primera publicacion.
- **Agregar `<SolutionFile>` e `infra/**` al filtro del write-side** (ver descubrimientos).
- **Enmendar MEF-ADR-0034**: el draft ya traia la correccion de esa lectura y la verifique;
  ningun ADR se toca en los tres issues.

## Preguntas abiertas

- **El `docker build` del Paso 4 de `projections-scaffolder` sigue siendo "opcional, no
  bloqueante"**: el agente commitea igual aunque lo corra y lo vea fallar, que es
  exactamente el camino por el que el defecto de #452 llego a un consumidor. Sin issue.
- **`ci.yml` e `infra-ci.yml` no los genera ningun agente**, aunque existen en el consumidor.
  Si la doctrina es que el harness genera los actions, son dos huecos mas del mismo tipo.
  Anotado en #453 como observacion fuera de alcance, sin issue.
- **Los consumidores ya scaffoldeados quedan con el `global.json` roto por diseno**
  (greenfield-only en #452), y nadie los va a enterar (mecanismo de aviso descartado). Si
  aparece un segundo consumidor con el mismo sintoma, esta es la deuda que lo explica.
- **`commands/scaffold-projections.md:82`** menciona la verificacion de `global.json` sin
  transcribir el bloque; no lo exige ningun CA de #452.

## Referencias

Issues creados: #454 (filtro de paths, `bug`), #456 (`ignore_changes` de la imagen).
Issues refinados: #452 y #453 (`estado:borrador` -> `estado:listo`; #453 retitulado y con
label `bloqueado`).
Batch propuesto: `/mefisto-sequential 454 456 453` (las dos dependencias van antes que su
dependiente, asi que la validacion intra-batch le quita el `bloqueado` a #453).
Fuentes consultadas: [`global.json`, tabla de `rollForward`](https://learn.microsoft.com/dotnet/core/tools/global-json#rollforward);
`builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json`;
HashiCorp, *The `lifecycle` Meta-Argument* (via el issue #249 del consumidor);
PRs del consumidor #257 (workflow a mano), #258 (`rollForward`), #259 (filtro de paths),
issues #236, #249 y #261.
