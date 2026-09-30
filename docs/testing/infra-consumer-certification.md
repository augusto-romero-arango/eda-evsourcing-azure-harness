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

Las secciones de protocolo satisfacen el CA-1 de #1629. Los CA-2 a CA-5 exigen
una sesion operada en vivo con acceso a Herdr, a una sesion `tmux` real y a un
consumidor sintetico -- el mismo tipo de operacion que
`tdd-consumer-certification.md` documenta como fuera de alcance de un stage de
escritura no interactivo ("Bloqueo estructural de la ejecucion automatizada
(#1464)"). Esa sesion y su veredicto quedan en "Estado de la certificacion".

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

**PASA (2026-09-30), release `v0.40.1`.** Las cuatro celdas de la matriz
(A, B-bis, C y D del intento 2) cumplen integramente CA-2 a CA-5, con identidad
`aligned`, centinelas en cero y baseline restaurado. `/mefisto:infra` queda
certificado bajo Claude Code y OpenCode, lanzado desde Herdr y desde `tmux`
autonomo, en el alcance que fija este protocolo: invocacion directa, sin
`--models` ni modelo explicito, fixture de modificacion acotada de un modulo
existente.

El intento 1 (`v0.40.0`) dio `NO PASA` por el gap de CA-4 que resolvio
[#1730](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1730).
El intento 2 expuso ademas una fuga de entorno entre distribuciones en
servidores `tmux` compartidos
([#1740](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1740)).
Se juzga fuera del veredicto, con el alcance explicado en "Fuga de entorno
entre distribuciones en tmux (#1740)": la celda B se repitio como B-bis sobre
un servidor limpio, y la evidencia de la matriz certificada proviene solo de
la distribucion de cada runtime.

### Intento 2 (2026-09-30, run-id `20260930-074511-v0.40.1`)

| Campo | Valor verificado |
|---|---|
| Release e identidad | `v0.40.1` (publicada 2026-09-30T12:19:52Z), version `0.40.1`, commit fuente `eba9773ad106b4e86400b2690340cfd3e8380c45`, digest OpenCode `0580ea32fd8312213365e0ae9f2a32cc7c779f30cd2057ab9bc61ac62d8c2201` validado por el instalador. `diagnose-installation-identity.sh` en `aligned` (Claude y OpenCode, misma version/commit) antes de crear fixtures; historial con `identity` `0.40.1` en las cinco corridas. Incluye #1730, #1731 y #1734. |
| Instalacion | Claude Code `claude plugin update` (scopes user y project) `0.40.0 -> 0.40.1`; OpenCode `mefisto-opencode install 0.40.1` + `project`. Rollback: `0.40.0` / `d876b9af` en ambos. |
| Consumidor, herramientas y fixture | Iguales al intento 1: mismo consumidor, `terraform` 1.14.4, Claude Code 2.1.285, OpenCode 1.18.32; mismo `<modulo-certificable>` (`monitoring`) y mismo cambio. |
| Baseline | `<sha-baseline-inicial>` = `<sha-baseline-final>` = `feb5103dc9b8ce118bddc76cd6b9c63481573abf`, arbol limpio antes y despues. |

| Dimension | A: Claude x Herdr | B-bis: Claude x tmux | C: OpenCode x Herdr | D: OpenCode x tmux |
|---|---|---|---|---|
| Issue fixture | [#70](https://github.com/augusto-romero-arango/mefisto-consumer-certification/issues/70) | [#78](https://github.com/augusto-romero-arango/mefisto-consumer-certification/issues/78) | [#72](https://github.com/augusto-romero-arango/mefisto-consumer-certification/issues/72) | [#73](https://github.com/augusto-romero-arango/mefisto-consumer-certification/issues/73) |
| Lanzamiento | pane Herdr `w9:pE` | sesion `infra-78`, servidor tmux creado por esta corrida | pane Herdr `w9:pF` | sesion `infra-73` |
| `MODELS:` writer / reviewer | `claude` balanced `sonnet` / deep `opus` | idem A | `opencode` balanced / deep, ambos `openai/gpt-6-sol` | idem C |
| Stage 1 / Stage 2 | `passed` 22 s / `passed` 30 s | `passed` 22 s (hold aparte) / `passed` 26 s | `passed` 1 m 45 s / `passed` 1 m 33 s | `passed` 1 m 37 s / `passed` 1 m 15 s |
| PR (sin `Closes`) | [#74](https://github.com/augusto-romero-arango/mefisto-consumer-certification/pull/74) | [#79](https://github.com/augusto-romero-arango/mefisto-consumer-certification/pull/79) | [#75](https://github.com/augusto-romero-arango/mefisto-consumer-certification/pull/75) | [#76](https://github.com/augusto-romero-arango/mefisto-consumer-certification/pull/76) |
| Diff y summaries | solo `infra/modules/monitoring/main.tf`, una linea identica; `<details>` de writer y reviewer | idem | idem | idem |
| Job `plan` de CI | `SUCCESS`; `apply` `SKIPPED` | `SUCCESS` | `SUCCESS` | `FAILURE` por `Error acquiring the state lock` (cuatro `plan` concurrentes sobre el mismo `tfstate`); rerun del job tras liberar el lock: `SUCCESS` |
| Session id (hash sha256, 12) writer / reviewer | `086de7d1cea0` / `e9c766bcdf62` | intento 1 sin sesion (`rate_limit`), intento 2 `911bdf4b4850` / `3a9f58c04692` | `76717e53a63a` / `e1046f02d307` | `ff71b382c28f` / `89e78b738bc8` |
| Evidencia bajo `.mefisto/pipeline/` | log por stage + stream por intento, `events.log`, historial | idem, mas `attempt-2` del writer | idem A | idem A |

- **CA-4 en curso y hold**: con C en Stage 1, el colector de ambos runtimes trajo
  la fila `running`, `1-infra-writer`, 30 %. En B-bis, con el mismo wrapper de
  `rate_limit` y `MEFISTO_HOLD_PROBE_SECONDS=90` del intento 1, el status paso a
  `state: hold`, `RATE_LIMIT`, `next_probe`, y `/work-status` mostro
  `EN ESPERA` con causa y proxima sonda. El hold tambien se indujo y se vio en
  ambos runtimes sobre la B original (#71).
- **CA-4 terminada**: en ambos runtimes las filas infra muestran
  `env:dev, PR #N` y `log` resuelto a `iac-pipeline-<started>.log`. El gap del
  intento 1 queda cerrado.
- **`events.log`**: todas las lineas, incluidas `[tool]`/`[stage]`, usan hora
  local. Se cierra el hallazgo #1731 del intento 1.
- **Ruta legacy**: igual que en el intento 1, solo se refresco el marker
  `.claude/pipeline/.plugin-root`, sin evidencia.
- **Centinelas**: 0 coincidencias en los cuatro patrones sobre los logs de las
  cinco corridas, `events.log`, `pipeline-history.jsonl` y el expediente
  `.mefisto/pipeline/certification/infra-v0.40.1/`.
- **Limpieza**: PRs #74-#77 y #79 cerrados sin merge, con sus ramas remotas
  eliminadas; fixtures #70-#73 y #78 cerrados `not planned`; sin worktrees ni
  sesiones tmux.
- **Desviaciones**: las mismas del intento 1 (fixtures con `gh issue create`
  desde el consumidor, invocacion no interactiva del comando publicado y hold
  por runner wrapper), mas el rerun del `plan` de D por contencion del lock de
  estado en CI. Ese lock es del workflow del consumidor, no de
  `iac-pipeline.sh`.

### Fuga de entorno entre distribuciones en tmux (#1740)

En el intento 2, D (OpenCode) arranco el servidor tmux. `tmux-pipeline.sh` carga
`mefisto-models.sh`, que exporta `MEFISTO_RUNTIME_LIB_DIR` con `:=`, asi que el
entorno global del servidor quedo con la raiz de librerias de la release
OpenCode, junto con `MEFISTO_STATE_DIR` y `MEFISTO_LEGACY_STATE_DIR`. La B
original (#71, PR #77, lanzada desde Claude sobre ese servidor) heredo ese
valor y ejecuto las librerias de runtime de la distribucion OpenCode. En
`0.40.1` ambas copias son identicas (solo difiere `runtime-fake.sh`, de tests),
y B cumplio todo, pero su evidencia no es de la distribucion Claude. Por eso se
repitio como B-bis (#78) sobre un servidor tmux arrancado por esa misma
corrida, con `MEFISTO_RUNTIME_LIB_DIR` en la raiz Claude, y es B-bis la celda
que entra en la matriz. El intento 1 corrio en el mismo orden (D antes que B)
y tuvo la misma fuga sin detectarla.

La fuga no invalida el veredicto: la matriz certificada ejecuta cada runtime
sobre su propia distribucion. Queda como defecto del lanzador en
[#1740](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1740):
mezclar lanzamientos de dos distribuciones o versiones sobre el mismo servidor
tmux permanece fuera del alcance certificado hasta que se resuelva.

### Intento 1 (2026-09-30, run-id `20260930-042402-v0.40.0`): NO PASA

| Campo | Valor verificado |
|---|---|
| Release e identidad | `v0.40.0` (publicada 2026-09-30T09:21:22Z), version `0.40.0`, commit fuente `d876b9af5e250c695b82031a58346064705e8ffb`, digest OpenCode `281b68f6c5ad4eede9fde9baa22b5a683b046ee135f179c1f0766f1f05b08d19` validado por el instalador contra el `.sha256` publicado. `diagnose-installation-identity.sh` en `aligned` (Claude y OpenCode, misma version/commit) antes de crear fixtures; `pipeline-status-infra-<N>.json` y `pipeline-history.jsonl` registran `identity` `0.40.0/d876b9af` (`identity_state: complete`) en las cuatro corridas. La ruta infra entro por primera vez en una release con `v0.40.0`: `v0.39.0` se publico antes de los merges de #1624-#1628. |
| Instalacion | Claude Code: marketplace + `claude plugin update` (scopes user y project) `0.39.0 -> 0.40.0`. OpenCode: `mefisto-opencode install 0.40.0` + `project`. Instalacion previa (rollback): `0.39.0` / `e5bff995` en ambos runtimes; se conserva `0.40.0` por ser la release vigente. |
| Consumidor | `augusto-romero-arango/mefisto-consumer-certification`, 11 modulos bajo `infra/modules/`, `infra-cd.yml` con `plan` en `pull_request` filtrado a `infra/**`. `<modulo-certificable>` = `monitoring`: tag determinista `modulo = "monitoring"` sobre `azurerm_log_analytics_workspace.this`. |
| Herramientas | `terraform` 1.14.4, Claude Code 2.1.285, OpenCode 1.18.32, tmux y Herdr locales. Sin `az login` ni backend remoto en local. |
| Baseline | `<sha-baseline-inicial>` = `<sha-baseline-final>` = `feb5103dc9b8ce118bddc76cd6b9c63481573abf`, arbol limpio antes y despues. |

#### Matriz 2x2 (CA-2, CA-3)

| Dimension | A: Claude x Herdr | B: Claude x tmux | C: OpenCode x Herdr | D: OpenCode x tmux |
|---|---|---|---|---|
| Issue fixture | [#62](https://github.com/augusto-romero-arango/mefisto-consumer-certification/issues/62) | [#63](https://github.com/augusto-romero-arango/mefisto-consumer-certification/issues/63) | [#64](https://github.com/augusto-romero-arango/mefisto-consumer-certification/issues/64) | [#65](https://github.com/augusto-romero-arango/mefisto-consumer-certification/issues/65) |
| Lanzamiento | pane Herdr `w9:pC` | sesion `infra-63` | pane Herdr `w9:pD` | sesion `infra-65` |
| `MODELS:` writer / reviewer | `claude` balanced `sonnet` / deep `opus` | idem A | `opencode` balanced / deep, ambos `openai/gpt-6-sol` | idem C |
| Stage 1 `infra-writer` | `passed`, 22 s | `passed`, 21 s (hold aparte) | `passed`, 1 m 48 s | `passed`, 1 m 36 s |
| Stage 2 `infra-reviewer` | `passed`, 24 s | `passed`, 18 s | `passed`, 1 m 23 s | `passed`, 1 m 31 s |
| PR (sin `Closes`) | [#66](https://github.com/augusto-romero-arango/mefisto-consumer-certification/pull/66) | [#69](https://github.com/augusto-romero-arango/mefisto-consumer-certification/pull/69) | [#67](https://github.com/augusto-romero-arango/mefisto-consumer-certification/pull/67) | [#68](https://github.com/augusto-romero-arango/mefisto-consumer-certification/pull/68) |
| Diff | solo `infra/modules/monitoring/main.tf`, una linea, identico en las cuatro | idem | idem | idem |
| Summaries en `<details>` | writer + reviewer | writer + reviewer | writer + reviewer | writer + reviewer |
| Job `plan` de CI | `SUCCESS` (fmt/init/validate/plan `success`, comentario publicado); `apply` `SKIPPED` | idem | idem | idem |
| Session id (hash sha256, 12) writer / reviewer | `eeb40e2c27cd` / `8acc929f575a` | intento 1 sin sesion (`rate_limit`), intento 2 `9290789cd785` / `cf4fca8dd827` | `cf6371fd10ed` / `74a7cf7464ec` | `b1af07664386` / `b937d11982b5` |
| Evidencia bajo `.mefisto/pipeline/` | log por stage + stream `attempt-1` por stage, `events.log`, historial | idem, mas `attempt-2` del writer | idem A | idem A |

Ninguna corrida escribio evidencia bajo `.claude/pipeline/`: el unico archivo
tocado ahi fue el marker `.plugin-root` que el comando Claude refresca como
mirror de resolucion de raiz, sin logs, estado ni historial.

#### Visibilidad en `/work-status` (CA-4)

- **En curso**: con C en Stage 1 y luego con D en Stage 2, el colector de
  ambos runtimes trajo la misma fila (`state: running`, `stage` vigente,
  `progress_pct` 30/80, `activity.kind = stage`), y los dos `/work-status`
  la dibujaron con barra de progreso.
- **Hold inducido (B)**: `MEFISTO_RUN_AGENT_BIN` apunto a un wrapper local
  que emite un terminal neutral `run.failed` con `error.kind = rate_limit` en
  el primer intento y delega en `src/runtime/mefisto-run-agent.sh` de la
  release en los siguientes, con `MEFISTO_HOLD_PROBE_SECONDS=90`.
  `events.log` registro `FALLO infra-writer: RATE_LIMIT` y la espera. El
  status paso a `state: hold` con `hold.cause = RATE_LIMIT` y `next_probe`.
  Ambos `/work-status` mostraron `EN ESPERA`, la causa, la proxima sonda y el
  techo de 6 h. Tras la sonda, el writer reanudo desde cero en `attempt-2`
  (no habia `session_id` que reanudar) y la corrida termino `completed`.
- **Terminada**: las cuatro filas pasan al historial como `completed` en ambos
  runtimes, pero con `detail = env:dev` y sin PR, a diferencia de las filas
  TDD, que muestran `PR #N`. `pipeline-history.jsonl` si guarda `pr`; el
  colector (`work-status-collect.sh`) prioriza `environment` sobre `pr` al
  calcular `detail` y no expone `pr` en la fila. Las filas infra ademas salen
  con `log: null`, asi que el drill-down no puede abrir la corrida. **Este es
  el gap de `NO PASA`** (#1730).

#### Centinelas y limpieza (CA-5)

- Barrido de los cuatro patrones sobre logs por stage, streams por intento,
  logs del pipeline, `events.log`, `pipeline-history.jsonl` y el expediente
  (`.mefisto/pipeline/certification/infra-v0.40.0/` en el consumidor, ignorado
  por Git): **0 coincidencias**.
- PRs #66-#69 cerrados sin merge (`mergedAt = null`) y ramas remotas
  eliminadas; fixtures #62-#65 cerrados `not planned` con comentario; sin
  worktrees `infra-issue-*`; sesiones `infra-63`/`infra-65` cerradas.

#### Desviaciones de la sesion

- **Fixtures**: se crearon con `gh issue create` desde el checkout del
  consumidor (sin `-R`, sin el planner interno de Mefisto) y con el cuerpo
  literal del template, mas `## ADRs aplicables` por la misma razon que juzgo
  #1487. No pasaron por el planner publicado; eso no afecta lo certificado,
  que empieza en `/mefisto:infra`.
- **Invocacion**: las cuatro corridas se lanzaron con el comando publicado
  real en modo no interactivo (`claude -p "/mefisto:infra <N>"`,
  `opencode run --command mefisto:infra <N>`) desde el checkout del
  consumidor. A/C heredaron el entorno Herdr del workspace del operador; B/D
  se lanzaron con las variables `HERDR_*` retiradas, de modo que
  `tmux-pipeline.sh` abrio sesiones `infra-<N>` autonomas.
- **Hold**: se indujo con un runner wrapper local, uno de los dos mecanismos
  que admite "Visibilidad en `/work-status`"; el wrapper no forma parte de la
  release y solo se inyecto en la sesion tmux de B.

#### Hallazgos no bloqueantes

- `events.log` mezcla zonas horarias: las lineas del pipeline van en hora
  local y las `[tool]`/`[stage]` del runner en UTC. La correlacion sigue siendo
  posible (draft
  [#1731](https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/issues/1731)).

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
