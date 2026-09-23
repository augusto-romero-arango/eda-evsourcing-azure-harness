# Protocolo de certificacion IaC multi-runtime (`/mefisto:infra`)

Este protocolo define, sin ejecutarla, la certificacion reproducible del
pipeline `/mefisto:infra` (`scripts/iac-pipeline.sh`, lanzado por
`scripts/tmux-pipeline.sh --infra`) sobre ambos runtimes y sobre los dos
contextos de lanzamiento que el propio script distingue: dentro de un
workspace Herdr (`herdr-workspace.sh`) y en una sesion `tmux` autonoma fuera
de Herdr. Molde: "Resultado write-side (#1435)" y
[`tdd-consumer-certification.md`](./tdd-consumer-certification.md), que a su
vez reutiliza la instalacion, identidad y discovery ya certificadas por
[`opencode-consumer-cutover.md`](./opencode-consumer-cutover.md) (veredicto
`PASA` de #1066). Este documento no repite esa mecanica: la fija como
prerrequisito y agrega la superficie propia de `/mefisto:infra` -- dos
agentes (`infra-writer`, `infra-reviewer`), cero credenciales de Azure, PR
sin `Closes` y la doble matriz runtime x contexto de lanzamiento.

Redactar este documento no ejecuta ninguna corrida ni declara `/mefisto:infra`
soportado bajo ambos runtimes. Satisface unicamente el CA-1 de #1629 (el
protocolo en si). Los CA-2 a CA-5 exigen una sesion operada en vivo por un
humano con acceso a Herdr, a una sesion `tmux` real y a un consumidor
sintetico -- exactamente el mismo tipo de operacion que
`tdd-consumer-certification.md` documenta como fuera de alcance de un stage
de escritura no interactivo en su seccion "Bloqueo estructural de la
ejecucion automatizada (#1464)". Este documento deja por eso, hasta que esa
sesion ocurra, las tablas de "Estado de la certificacion" en
`PENDIENTE DE EJECUCION`.

## Invariantes y prerrequisitos (CA-1: preflight)

- **Identidad**: una unica release candidata instalada en ambos runtimes,
  verificada por `diagnose-installation-identity.sh` con `status=aligned` y el
  mismo `<version>`/`<commit-fuente>` en Claude y OpenCode, igual que exige
  "Invariantes y prerrequisitos (CA-1)" de `tdd-consumer-certification.md`. Una
  identidad distinta de `aligned`, o distinta entre las cuatro corridas,
  bloquea el protocolo antes de crear ningun fixture.
- **Instalacion publicada exclusivamente**: prohibido instalar o referenciar
  Mefisto desde un checkout, un worktree, un enlace simbolico o una ruta
  absoluta del repositorio de Mefisto (marketplace para Claude Code,
  `install.sh install <version>` con checksum verificado para OpenCode).
- **Consumidor sintetico**: a diferencia del consumidor completo que exige
  `tdd-consumer-certification.md` (dominio scaffoldeado con Function App y
  proyecto SmokeTests), `/mefisto:infra` solo necesita:
  - `infra/modules/` con al menos un modulo base ya generado (por ejemplo por
    `/mefisto:infra-base`, MEF-ADR-0021) para que `infra-writer` tenga algo
    real que modificar y `infra-reviewer` tenga algo real que revisar;
  - `terraform` instalado en el `PATH` de cada pane de ejecucion, version
    registrada en el manifiesto de evidencia;
  - **sin** backend remoto configurado ni sesion `az login`: `infra-reviewer`
    corre `terraform init -backend=false` (MEF-ADR-0021, MEF-ADR-0022), asi que
    el consumidor sintetico no necesita una Storage Account de tfstate real ni
    ningun permiso de Azure.
  Puede ser el mismo consumidor persistente de #1180/#1181/#1435/#1436
  (`augusto-romero-arango/mefisto-consumer-certification`) si ya tiene
  `infra/modules/` provisionado, o un consumidor sintetico dedicado mas
  liviano; cualquiera de los dos vale mientras cumpla los tres puntos
  anteriores y se registre como `<consumidor-certificable>`.
- **`tipo:infra` fuera de lotes**: la matriz de este protocolo no incluye
  `/mefisto:batch-stop`, `/mefisto:sequential` ni `/mefisto:parallel`
  (`SKIP:infra` en ambos orquestadores de cola); las cuatro corridas se lanzan
  siempre como invocacion directa de `/mefisto:infra` (`/infra` en Claude Code).
- Registra antes de crear ningun fixture: `<tag-certificable>`, `<version>`,
  `<commit-fuente>`, `<checksum-opencode>`, `<consumidor-certificable>`,
  `<sha-baseline-inicial>`/`<sha-baseline-final>`, version de `terraform` y
  versiones de CLI de cada runtime.

## Fixture minimo `tipo:infra` (CA-1: fixture)

Se crea **un issue fixture por corrida** (cuatro en total), todos desde el
planner **publicado** del consumidor (nunca desde el planner interno de
Mefisto ni con `gh -R`, MEF-ADR-0019), todos con `estado:listo` explicito y
DoR de la columna `infra` de MEF-ADR-0011: `## Contexto`, `## Dependencias`
(`Ninguna`), `## Criterios de aceptacion` (**Critico**), `## Ambiente`
(**Obligatorio**) y `## Impacto en archivos` (**Obligatorio**). `dom:X` es
opcional en `infra` y `## ADRs aplicables` es solo Recomendado -- ni
`infra-writer` ni `infra-reviewer` lo consumen en su paso 1b, a diferencia de
`implementer`/`reviewer` -- pero el planner publicado la agrega igual por
buena practica; su ausencia no bloquea el lanzamiento en esta ruta.

### Eleccion del cambio certificable

Antes de redactar los cuatro fixtures se registra `<modulo-certificable>`: un
modulo ya existente bajo `infra/modules/` de `<consumidor-certificable>` (por
ejemplo `monitoring` o `service-plan`). El cambio que describe el fixture es
**deterministico y acotado** -- agregar o modificar un `tag`/etiqueta fija, o
un valor de variable con default explicito -- para que `terraform fmt`,
`terraform init -backend=false` y `terraform validate` tengan una unica forma
correcta de pasar, sin ambiguedad de diseño que dependa del modelo. El fixture
**no** crea un modulo nuevo ni toca `infra/environments/<env>/backend.tf`: eso
mantiene fuera de alcance el bootstrap del backend (`bootstrap-backend.sh`),
que este protocolo no certifica.

### Template de fixture (Claude/OpenCode x herdr/tmux)

Las cuatro corridas usan la misma forma; solo el runtime, el contexto de
lanzamiento y `<run-id>` (formato `YYYYMMDD-HHMMSS-<tag-certificable>`,
mismo que `tdd-consumer-certification.md`) cambian.

````markdown
# Certificar IaC bajo <runtime> x <contexto-lanzamiento> (<run-id>)

## Contexto

Certificar `/mefisto:infra` sobre la release `<tag-certificable>`
(`<version>`, commit fuente `<commit-fuente>`) desde una instalacion
publicada real en este consumidor, lanzada desde <contexto-lanzamiento>
(Herdr o tmux autonomo).

## Ambiente

`dev`. El fixture no ejecuta `terraform plan` ni `terraform apply` en ningun
punto del pipeline local (MEF-ADR-0021, MEF-ADR-0022): solo revision estatica
sin credenciales de Azure.

## Criterios de aceptacion

- CA-1: el modulo `<modulo-certificable>` en `infra/modules/<modulo-certificable>/`
  agrega el tag/valor determinista descrito, sin cambiar ninguna interfaz
  (variables de entrada, outputs) del modulo.
- CA-2: `terraform fmt -check` no reporta diferencias sobre el modulo
  modificado.
- CA-3: `terraform init -backend=false` y `terraform validate` pasan sobre
  `infra/environments/dev/` con el modulo modificado.
- CA-4: el diff no toca `infra/environments/dev/backend.tf` ni ningun otro
  modulo distinto de `<modulo-certificable>`.

## Impacto en archivos

- Modifica: `infra/modules/<modulo-certificable>/main.tf` (o el archivo HCL
  equivalente donde vive el tag/valor).
- No crea modulos nuevos ni toca `infra/environments/<env>/backend.tf`.

## Dependencias

- Ninguna.
````

## Matriz de corridas (CA-1: matriz)

| Corrida | Runtime | Contexto de lanzamiento | Invocacion |
|---|---|---|---|
| A | Claude Code | Herdr | `/infra <issue-A>` desde el pane "ejecucion [claude]" de un workspace Herdr (`herdr-workspace.sh`) |
| B | Claude Code | tmux autonomo | `/infra <issue-B>` (o `scripts/tmux-pipeline.sh --infra <issue-B>` directo) fuera de cualquier sesion Herdr, con `tmux -CC attach -t infra-<issue-B>` para monitorear |
| C | OpenCode | Herdr | `/mefisto:infra <issue-C>`, pane "ejecucion [opencode]" del mismo workspace Herdr |
| D | OpenCode | tmux autonomo | `/mefisto:infra <issue-D>` fuera de Herdr, con la misma sesion `infra-<issue-D>` |

Las cuatro corridas parten del mismo `<sha-baseline-inicial>` del consumidor y
son independientes entre si: ninguna depende de que el PR fixture de otra se
fusione (los cuatro PRs se cierran sin merge, seccion "Fail-closed y limpieza"
mas abajo). `scripts/tmux-pipeline.sh` detecta `HERDR_ENV=1` y delega en la
interfaz Herdr para A/C; fuera de Herdr, para B/D, abre una sesion `tmux`
nombrada `infra-<issue>` tal como documenta `commands/infra.md`.

## Resultados esperados de cada corrida (CA-2 de #1629)

En las cuatro corridas, `/mefisto:infra` (`/infra` en Claude Code) debe:

1. **Lanzar `iac-pipeline.sh` en el runtime correcto**: antes de la cabecera
   `=== IAC STAGE <n>: <agente> ===`, `events.log` contiene una linea
   `MODELS:` por agente (`infra-writer` e `infra-reviewer`) con
   `runtime=<runtime-resuelto>`, `perfil=` (`balanced` para `infra-writer`,
   `deep` para `infra-reviewer`) y `resuelto=` con el modelo efectivo,
   conforme la escribe `resolve_infra_model` en `scripts/iac-pipeline.sh`. El
   `runtime=` debe coincidir con el runtime de la columna de la matriz. Ninguna de las cuatro
   corridas fija `--models` ni un modelo explicito: la seleccion automatica
   por perfil neutral es parte de lo que se certifica.
2. **Completar Stage 1 (`infra-writer`) y Stage 2 (`infra-reviewer`) con
   summaries**: `pipeline-status-infra-<N>.json` registra
   `agents.infra-writer.result` y `agents.infra-reviewer.result` en `passed`,
   y el PR final incluye el summary de cada stage en `<details>` (mismo patron
   que `iac-pipeline.sh` lineas 694-722).
3. **Abrir un PR real limitado a `infra/`, sin `Closes #N`**: el pipeline
   IaC nunca agrega `Closes` al body del PR (MEF-ADR-0021, MEF-ADR-0022): el
   cierre del issue lo hace el workflow `infra-cd.yml` tras un `apply` exitoso
   en CI, no este pipeline local. El diff del PR se limita exactamente al
   archivo declarado en `## Impacto en archivos` del fixture.
4. **Publicar o justificar el job `plan` de CI**: si el consumidor tiene
   `infra-cd.yml` con el job `plan` sobre `pull_request` filtrado a
   `infra/**`, su conclusion (o el comentario que publica en el PR) queda
   registrada. Si el consumidor sintetico no tiene ese workflow configurado
   (por ejemplo, un consumidor sin bootstrap de CI todavia), se registra
   `NO_APLICA` con el motivo explicito -- mismo criterio que usa
   `tdd-consumer-certification.md` para sus checks `NO_APLICAN`. Cualquiera de
   las dos formas es aceptable; la ausencia silenciosa de ambas no lo es.

## Evidencia correlacionada (CA-3 de #1629)

Cada una de las cuatro corridas debe dejar, bajo `.mefisto/pipeline/` del
consumidor (nunca bajo `.claude/pipeline/`, que queda solo como fallback de
lectura de `work-status-collect.sh` desde #1626):

- `logs/iac-stage-<N>-<agente>-<ts>-issue-<issue>.log` por stage (Stage 1
  `infra-writer`, Stage 2 `infra-reviewer`).
- Los streams neutrales por stage e intento
  (`logs/iac-stage-<N>-<agente>-<ts>-issue-<issue>-attempt-<k>.events.jsonl`;
  mas de un intento solo aparece si hubo hold o reanudacion), redactados conforme al
  catalogo de centinelas de la seccion "Centinelas y limpieza" mas abajo.
- `events.log` con la linea `MODELS:` de cada stage y los eventos de
  transicion de stage.
- `pipeline-status-infra-<issue>.json` con `identity` (version/commit/estado
  de la distribucion), `runtime` y, si hubo hold, el objeto `hold`. El
  pipeline lo borra al completar, asi que se captura mientras la corrida esta
  en curso (o en hold); tras el cierre, la fuente es `pipeline-history.jsonl`.
- `pipeline-history.jsonl` con una entrada por corrida, `runtime` e
  `identity`.

La correlacion se verifica cruzando issue, PR, stage y session id (hash) entre
estos cinco artefactos y el PR real de GitHub. Cualquier corrida cuya
evidencia aparezca bajo `.claude/pipeline/` en vez de `.mefisto/pipeline/` es
una divergencia de MEF-ADR-0053 seccion 4, no solo del protocolo, y produce
`NO PASA` para esa corrida.

## Visibilidad en `/work-status` (CA-4 de #1629)

- **En curso**: mientras cualquiera de las cuatro corridas esta `running`,
  `/mefisto:work-status` (`/work-status` en Claude Code) en ambos runtimes
  muestra una fila con `pipeline=infra`, el `issue`, el `runtime` y el
  `stage` vigente (`1-infra-writer` o `2-infra-reviewer`), con el
  `progress_pct` que asigna `scripts/work-status-collect.sh` (30 para
  `infra-writer`, 80 para `infra-reviewer`); la barra se dibuja cuando es la
  unica fila activa con `activity.kind = stage`.
- **Terminada**: al completar, la fila pasa a reflejar el PR (`pr` no vacio) y
  dejar de aparecer como `running`, conforme al historial en
  `pipeline-history.jsonl`.
- **Hold inducido**: se induce un hold sobre **al menos una** de las cuatro
  corridas fijando `MEFISTO_HOLD_PROBE_SECONDS` a un valor corto y usando un
  runner de agente con `rate_limit` simulado (mismo mecanismo que
  `.claude/scripts/tests/test-agent-hold.sh`/`scripts/tests/test-pr-sync-hold.sh`
  stubean para el resto de pipelines), o aprovechando un limite real de uso
  del proveedor si ocurre durante la ventana de la corrida. Mientras el hold
  esta activo, la fila del colector debe traer `state: hold` /
  `activity.kind = hold` y `/work-status` debe mostrar `EN ESPERA` en lugar del stage, con
  la causa (`activity.cause`) y la proxima sonda (`activity.next_probe`)
  visibles, en ambos runtimes -- MEF-ADR-0051 (mecanismo) y MEF-ADR-0053
  seccion 4 (raiz de estado unica) convergen aqui con MEF-ADR-0031: la
  visibilidad del hold es evidencia ejecutable, no un campo que se asuma
  presente porque el JSON lo declara.

## Centinelas y limpieza (CA-5 de #1629)

Se reutiliza sin modificacion el catalogo de centinelas de "Manifiesto de
evidencia y redaccion" (`opencode-consumer-cutover.md`), aplicado sobre los
cinco artefactos de "Evidencia correlacionada" y sobre cualquier manifiesto
propio de esta corrida:

```text
("|')?(prompt|system[ _-]?prompt|question|confirmation|approval|raw|stderr|message|tool[ _-]?input)("|')?[[:space:]]*[:=]
(authorization|cookie|set-cookie|x-api-key)[[:space:]]*:
auth\.json|credentials|((api[_-]?key|access[_-]?token|refresh[_-]?token)[[:space:]]*[:=])
Bearer[[:space:]]+[A-Za-z0-9._~+/-]+=*|sk-[A-Za-z0-9]{16,}
```

Cero coincidencias en las cuatro corridas es el minimo para continuar; una
coincidencia exige redaccion local antes de persistir evidencia. Tras
capturarla (haya `PASA` o `NO PASA`):

1. Cierra los **cuatro PRs sin merge** y elimina sus ramas remotas -- **nunca
   se mergean**: un merge dispararia el `apply` real de CI sobre un fixture
   sintetico (MEF-ADR-0022).
2. Cierra los **cuatro issues fixture** como `not planned` desde el
   consumidor, con un comentario que enlace la certificacion.
3. Retira los cuatro worktrees de las corridas y comprueba que no queda
   ninguno.
4. Restaura el baseline y comprueba que `<sha-baseline-final>` coincide
   exactamente con `<sha-baseline-inicial>` y que el arbol queda limpio.
5. Restaura la instalacion Claude/OpenCode previa si alguna corrida cambio la
   release activa, conservando en el manifiesto los punteros/version previos.

La limpieza es idempotente, igual que en `tdd-consumer-certification.md`.

## Escala de veredicto y fail-closed

- **`PASA`**: las cuatro corridas cumplen integramente "Resultados esperados
  de cada corrida", "Evidencia correlacionada" y "Visibilidad en
  `/work-status`" (incluido el hold inducido en al menos una corrida), con
  centinelas en cero y limpieza completa.
- **`NO PASA`**: cualquier gap -- stage sin summary, PR con `Closes`,
  evidencia bajo `.claude/pipeline/`, hold no visible, centinela positivo sin
  redaccion posible, o una diferencia entre corridas espejo no atribuible a
  runtime/contexto de lanzamiento -- produce `NO PASA` para el protocolo
  completo. Cada gap abre un issue `tipo:bug` dependiente antes de repetir la
  matriz, con la evidencia sanitizada de la corrida afectada enlazada.
- Un recurso inaccesible (issue, PR, check, log o sesion no consultable) se
  marca `BLOQUEADO`, nunca se completa por inferencia (MEF-ADR-0031).

## Estado de la certificacion

**PENDIENTE DE EJECUCION.** Este documento cumple el CA-1 de #1629 (define el
protocolo). Los CA-2 a CA-5 exigen una sesion operada en vivo por un humano
con Herdr, una sesion `tmux` real y un consumidor sintetico con `terraform`
instalado -- una operacion que un stage de escritura no interactivo no puede
producir, por la misma razon documentada en "Bloqueo estructural de la
ejecucion automatizada (#1464)" de `tdd-consumer-certification.md`: no hay
credenciales ni alcance sobre un repositorio de consumidor, no se pueden
operar paneles Herdr/tmux en vivo, y no se puede esperar a que CI resuelva un
check real.

Quien opere esa sesion:

1. Ejecuta el preflight de "Invariantes y prerrequisitos (CA-1)" sobre una
   release candidata vigente, fijando `<tag-certificable>`, `<version>`,
   `<commit-fuente>`, `<checksum-opencode>` y `<consumidor-certificable>` con
   identidad `aligned` verificada.
2. Crea los cuatro issues fixture de "Fixture minimo `tipo:infra` (CA-1:
   fixture)" desde el planner publicado del consumidor y lanza las cuatro
   corridas de la "Matriz de corridas (CA-1: matriz)".
3. Completa esta seccion con la evidencia real correlacionada por
   issue/PR/stage/session, siguiendo el mismo formato de tabla "Campo | Valor
   verificado" que usan "Resultado write-side (#1435)"/"Resultado read-side
   (#1436)" de `tdd-consumer-certification.md`, y ejecuta la limpieza de
   "Centinelas y limpieza (CA-5 de #1629)".
4. Emite el veredicto (`PASA`/`NO PASA`) conforme a "Escala de veredicto y
   fail-closed" y, si aplica, abre el issue `bug` dependiente.

Hasta que esa sesion ocurra, `README.md` no declara a `/mefisto:infra` bajo
ningun runtime como parte del alcance certificado.

## Referencias

- `docs/testing/tdd-consumer-certification.md`: molde de protocolo, fixture,
  matriz, manifiesto de evidencia y la seccion "Bloqueo estructural de la
  ejecucion automatizada (#1464)" que esta certificacion replica para
  `/mefisto:infra`.
- `docs/testing/herdr-workspace.md`: convenciones de filas/labels por runtime
  de `herdr-workspace.sh` que las corridas A y C reutilizan.
- `docs/testing/opencode-consumer-cutover.md`: manifiesto de evidencia y
  catalogo de centinelas reutilizado sin modificacion.
- MEF-ADR-0011: Definition of Ready; columna `infra` de la tabla DoR.
- MEF-ADR-0019: separacion publicado/interno; issues y PRs fixture se
  gestionan exclusivamente desde el consumidor.
- MEF-ADR-0021/MEF-ADR-0022: cero credenciales de Azure en el pipeline local,
  PR sin `Closes`, `apply` real solo en CI tras merge.
- MEF-ADR-0031: el gate es evidencia ejecutable, no outputs asumidos.
- MEF-ADR-0050: toda operacion nace neutral a runtime.
- MEF-ADR-0051: mecanismo de hold ante `rate_limit`/`provider_unavailable`.
- MEF-ADR-0053, seccion 4: raiz de estado canonica `.mefisto/pipeline/` que
  la evidencia de este protocolo debe usar exclusivamente.
