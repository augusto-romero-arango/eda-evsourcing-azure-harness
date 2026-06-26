---
fecha: 2026-06-25
hora: 11:33
sesion: mefisto-planner
tema: Backlog de hallazgos del primer greenfield real (Bitakora.ControlAsistencia)
---

## Contexto

El usuario corrio el primer greenfield real del harness provisionando
`Bitakora.ControlAsistencia` desde cero y reporto 9 hallazgos (A-I) con
severidades marcadas (bloqueantes / flujo-CI / menores). Tarea: knowledge
crunching, agrupar, verificar contra el codigo real del plugin y crear/refinar
issues en el repo activo (Mefisto), sin `gh -R`. En una segunda pasada se
refinaron los dos borradores (#93, #94) a `estado:listo`.

## Descubrimientos

- **Inconsistencia interna confirmada (A)**: el `domain-scaffolder.md` Paso 4
  (lineas 1284-1296) ya usa `random_string` de 6 chars para storage accounts de
  dominio, pero `bootstrap-backend.sh:133` hardcodea el storage del backend
  desde `terraformStateStorage`, y los modulos base hardcodean postgresql/
  service-bus. Dos patrones distintos para el mismo problema (unicidad global).
- **Los 7 modulos base NO existen en el harness (B)**: el scaffolder los
  referencia como preexistentes (`module.resource_group`, `.monitoring`,
  `.service_bus`, `.postgresql`, y consume `../../modules/{storage,service-plan,
  function-app}`). El ADR-0020 documenta el *contrato* de `modules/service-plan`
  (lineas 56-58) pero ningun archivo provee la *plantilla*. No hay comando ni
  agente generador (verificado). Un greenfield no provisiona nada sin reinventar
  la base.
- **Gate de issue OPEN vs Closes #N (E)**: `iac-pipeline.sh:206` aborta si el
  issue no esta OPEN; `iac-pipeline.sh:546` siempre emite `Closes #N` en el PR,
  incluso con `--skip-apply` (la rama skip-apply solo omite Stage 3, lineas
  442-444). Mergear el PR de preview cierra el issue y bloquea el apply.
- **Scope del plugin (D)**: `iac-pipeline.sh:332` corre `claude -p` dentro del
  worktree (`${REPO_ROOT}/../${BRANCH_NAME}`, linea 227). El scope project no
  cubre el worktree -> `agent not found`. Mismo patron en tdd/scaffold pipeline.
  El README "Primeros pasos" (lineas 101-188) instala con `/plugin install`
  sin mencionar `--scope user`.
- **Mismatch de secrets (F)**: deploy YAML del scaffolder usa `azure/login@v3`
  con `creds: ${{ secrets.AZURE_CREDENTIALS }}` (linea 1417); `setup-github-ci.sh`
  emite 4 secrets separados (lineas 62-65). No coinciden.
- **Reusable no generado (G)**: el scaffolder solo *referencia*
  `./.github/workflows/smoke-tests-dominio.yml` (linea 1427) y registra en
  `.github/smoke-tests-dominios.json` (Paso 6b), pero ningun paso genera el
  reusable ni el workflow global. El field note del #90 ya lo habia anotado como
  "fuera de alcance"; este backlog cierra ese gap.
- **H matizado**: el README *si* documenta `azureLocation` en prosa (lineas 80,
  119, 149); lo que falta es incluirlo en el *snippet JSON literal* (lineas 67-77).

### Descubrimientos del refinamiento de #93/#94 (contra Bitakora real)

- **Los 7 modulos base verificados** en `Bitakora.ControlAsistencia/infra/modules`:
  resource-group, monitoring, postgresql, service-bus, service-plan, storage,
  function-app. Cada uno es un `main.tf` unico (sin variables.tf/outputs.tf
  separados).
- **El sufijo de unicidad vive en el ENTORNO, no en los modulos**. Los modulos
  reciben `name` como `var.name`. En `environments/dev/main.tf`: `module.postgresql`
  recibe `name="psql-${local.prefix_short}"` y `module.service_bus`
  `name="sb-${local.prefix}"` (ambos SIN sufijo, hardcodeados). Solo las storage
  llevan `random_string` y tambien en el entorno. -> el fix de #94 es en el
  esqueleto del entorno, no en los `main.tf` de los modulos.
- **Divergencia real `service-plan` vs ADR-0020**: el modulo de campo de Bitakora
  solo acepta `name/resource_group_name/location/sku_name/tags`; NO acepta
  `os_type`, `worker_count`, `always_on` que el scaffolder le pasa
  (`domain-scaffolder.md:1303-1306`, contrato ADR-0020). La plantilla de campo
  esta desfasada del ADR. #93 debe entregar el modulo que cumple el contrato.
- **El `environments/dev/outputs.tf` de Bitakora SI existe** (resource_group_name,
  service_bus_name, postgresql_fqdn). El sintoma "terraform output vacio" del
  greenfield (hallazgo I) fue porque el plugin no genera ese esqueleto; Bitakora
  lo escribio a mano. Confirma que I es parte del gap de #93.
- **`infra-writer.md:29,56` tambien asume `infra/modules/` preexistente**: son
  DOS agentes del harness (scaffolder + infra-writer) los que dependen de modulos
  que el harness nunca crea.
- **Precedente de mecanismo de scaffold**: `domain-scaffolder` no copia archivos
  de un `templates/`; emite contenido inline via `Write`. El harness NO tiene
  directorio `templates/` ni mecanismo de copia (verificado). El unico patron de
  scaffold del harness es "agente que escribe contenido inline".

## Decisiones

Agrupacion respecto a la lista A-I (8 issues, no 9):

- **A dividido en A1 (#92) y A2 (#94)**: A1 = sufijo en `bootstrap-backend.sh`
  (independiente, `estado:listo`). A2 = sufijo en postgresql/service-bus
  (depende de #93).
- **B = #93**: la decision de diseno abierta se resolvio (ver abajo) -> `listo`.
  Bloquea a #94.
- **I fusionado en B (#93)** como CA-4 (outputs del entorno).
- **C + H fusionados en #99**: doc de bajo riesgo (region Postgres + azureLocation
  en el snippet).
- **D = #95** acotado a documentacion.
- E=#96, F=#97, G=#98 quedan como issues 1:1.

### Decision de diseno de #93 (TOMADA)

**Mecanismo: agente generador (estilo `domain-scaffolder`) que ESCRIBE inline los
7 modulos + esqueleto del entorno via `Write`, NO un directorio de plantillas
copiables.** Razon: (1) es el unico patron de scaffold que el harness ya usa
(domain-scaffolder no copia templates, los emite); el harness no tiene `templates/`
ni mecanismo de copia. (2) El contenido no es estatico: el `service-plan` debe
cumplir ADR-0020 (la plantilla de campo lo incumple), la region de Postgres
depende del consumidor (#99), los nombres globales necesitan sufijo (#94); un
agente aplica reglas, un archivo copiado las congela. (3) Encaja en el flujo
greenfield: `infra-bootstrap` ya orquesta "tfstate -> primer /infra"; el esqueleto
base es el eslabon que falta. Sub-eleccion dejada al implementador (agente nuevo
`infra-base-scaffolder` + script delgado vs extender `infra-bootstrap`); no cambia
el alcance. No hubo ambiguedad que cambiara el alcance del issue -> no fue
necesario consultar; se documento como decision tomada con el precedente del
harness.

### Decision de alcance de #94 (TOMADA)

El sufijo se aplica en el **esqueleto del entorno** (no en los modulos), con el
mismo `random_string` (length=6, special=false, upper=false) que ya usan las
storage. Limitacion documentada: `postgresql`/`service-bus` tienen
`prevent_destroy=true` y `name` es ForceNew -> el sufijo aplica a greenfield
(primer apply); migrar un consumidor ya desplegado exige `terraform state mv`/
import o aceptar nuevo nombre. Esto va al ADR-0021. `random_string` ya es
idempotente (state lo persiste; sin `keepers`).

## Descartado

- No se creo issue para "el pipeline detecta el scope incorrecto y avisa /
  pasa --plugin-dir" (mejora de robustez de codigo, mayor que la doc). Se anoto
  como decision abierta en #95 para que el coordinador decida si crearlo aparte.
- No se duplico la nota de region de Postgres en un ADR ahora: se deja en #99
  (README) con la indicacion de moverla al ADR-0021 (#93) si ese ADR avanza.
- Para #93 se descarto el directorio `templates/` copiable: sin precedente en el
  harness y congela contenido que debe ser dinamico.

## Preguntas abiertas

- #93: sub-eleccion agente nuevo vs extender infra-bootstrap (no cambia alcance);
  y si conviene partir la ENTREGA en dos PRs (modulos+ADR / entorno+outputs+edicion
  de agentes). No se partio en dos issues porque comparten el agente y el ADR.
  El modulo `function-app` no se inspecciono en detalle (solo se confirmo su
  existencia); el implementador debe leerlo de Bitakora.
- #96/#97: cada uno ofrece dos vias de fix (a/b); la eleccion final es del
  implementador/coordinador.
- #98: CA-4 (workflow global) podria separarse de CA-1/2/3 (reusable).
- Relaciones a vigilar al implementar: #97 y #82 tocan `setup-github-ci.sh`;
  #92 y #78 tocan el nombre de `terraformStateStorage`; #97 y #98 tocan ambos
  `agents/domain-scaffolder.md`; #93 y #94 tocan el esqueleto de entorno generado.

## Referencias

Issues creados/refinados:
- #92 - Anadir sufijo unico al storage account del backend en bootstrap-backend.sh [estado:listo, bug]
- #93 - Generar el scaffold de infraestructura base (7 modulos + entorno con outputs) con un agente, y crear su ADR [estado:listo] (refinado de borrador; titulo cambiado; decision de diseno tomada)
- #94 - Anadir sufijo de unicidad global a postgresql y service-bus en el esqueleto del entorno base [estado:listo, bloqueado, bug] (refinado de borrador; titulo y alcance precisados; depende dura de #93)
- #95 - Documentar que el plugin debe instalarse a scope user antes de correr cualquier pipeline [estado:listo, bug]
- #96 - Permitir el apply de IaC sobre un issue cerrado en el flujo preview -> merge -> apply [estado:listo, bug]
- #97 - Alinear los secrets de Azure entre el workflow de deploy del scaffolder y setup-github-ci.sh [estado:listo, bug]
- #98 - Generar el workflow reusable smoke-tests-dominio.yml y el workflow global la primera vez que el scaffolder corre [estado:listo, bug]
- #99 - Documentar la restriccion de region de PostgreSQL y anadir azureLocation al snippet de harness.config.json [estado:listo]

Archivos verificados: scripts/bootstrap-backend.sh, scripts/iac-pipeline.sh,
scripts/setup-github-ci.sh, scripts/scaffold-pipeline.sh, agents/domain-scaffolder.md
(Pasos 4/5/6b), agents/infra-writer.md, agents/infra-bootstrap.md,
README.md (Instalacion + Primeros pasos), docs/adr/0020, y como referencia de
campo Bitakora.ControlAsistencia/infra/{modules,environments/dev}/*.
