---
fecha: 2026-08-04
hora: 18:12
sesion: mefisto-planner
tema: Migracion de los dos planners de opus[1m] a Fable 5
---

## Contexto

Idea a refinar: cambiar el modelo de los planners de Opus a Fable. Estado de partida
verificado: `agents/planner.md:3` y `.claude/agents/mefisto-planner.md:3` en `model: opus[1m]`,
los dos unicos puntos del inventario con sufijo de ventana extendida. Tres preguntas abiertas
del refinamiento: alcance (uno o dos lados), sintaxis del frontmatter y existencia de la
variante de 1M para Fable, y si el cambio se documenta en el repo.

## Descubrimientos

Fuente usada, a falta de `WebFetch`/`WebSearch` en el agente: el **catalogo de modelos
embebido** en el binario del CLI instalado (`~/.local/share/claude/versions/2.1.221`), que es
la tabla que el propio binario consulta en runtime, mas `claude --help`. Queda como *no
verificado* contra `docs.claude.com` (se traslado como CA-5 del issue).

- **La premisa del cambio estaba invertida.** `claude-fable-5` declara
  `context:{window:1e6, native_1m:true, supports_1m_beta:true}` -- 1M **nativo** -- y a
  diferencia de `claude-opus-5` **no** declara `supports_1m_suffix`. `fable[1m]` si es alias
  valido, pero el resolvedor lo **descarta** en first-party
  (`if(n&&rae()&&L6g(o)&&mL(o))return YD(t.replace(/(\[1m\])+$/i,"").trim())`, con
  `L6g` = "el string incluye fable"). Conclusion: no hay regresion de ventana, y el valor
  correcto es `fable` a secas -- coherente con la doctrina de #411 (alias en todas partes,
  sufijo de ventana solo donde hace falta).
- **El coste es exactamente 2x**: `tier_10_50` (input 10 / output 50 / cache_read 1) vs
  `tier_5_25` de Opus 5 (input 5 / output 25 / cache_read 0.5). Cae sobre las sesiones de
  mayor volumen de tokens del harness, que es el mismo eje que puso a los agentes per-issue
  y a los scaffolders en `sonnet`.
- **Fable exige creditos de uso** (`FHt()` + `Nze()` -> `{reason:"absent"}`) y solo existe en
  `firstParty`/`gateway`; en Bedrock/Vertex/Foundry queda ausente con
  `fallback_3p: "claude-opus-5"`.
- **Cutoff mas viejo**: Fable `January 2026` vs Opus 5 `May 2026`.
- A favor: `advisor_rank: 5` (Opus 5 es 4) y el posicionamiento del propio CLI, *"most capable
  for your hardest and longest-running tasks"*. En contra en capacidades: Fable trae
  `rejects_disabled_thinking` y carece de `fast_mode` y `opus_5_prompt_bundle`.
- **MEF-ADR-0019 seccion E no aplica**: no hay ruta nueva. `agents/*`, `.claude/agents/*` y
  `changelog.d/*` ya estan enumeradas en `is_path_in_mefisto_scope`
  (`.claude/scripts/_mefisto-common.sh:75/:77/:79`) y ya viven en `main`. Un solo PR puede
  tocar los dos lados sin autobloquearse.
- El planner publicado **no se puede smoke-testear desde este repo**: el plugin no esta
  instalado sobre si mismo, y la unica copia instalada es `scope: project` de un consumidor
  pinneada a `0.19.0`.

## Decisiones

- **Se acepta el 2x** a cambio de la capacidad de Fable. El motivo del cambio queda registrado
  como capacidad de razonamiento, no ventana de contexto (que no cambia).
- **Alcance: los dos planners.** Decision del usuario, que anulo la recomendacion del
  refinamiento de limitarlo al interno.
- El riesgo del lado publicado (creditos de uso + ausencia en proveedores de terceros +
  degradacion **silenciosa** al modelo heredado) no se elimina por decidir a favor: se
  consigna como **consecuencia aceptada** en el fragmento de changelog, con CA propio (CA-4)
  para que sea verificable y no se pierda al ampliar el alcance.
- Valor a escribir: `model: fable`, sin `[1m]`.
- **Documentacion**: solo fragmento en `changelog.d/`, sin ADR ni seccion en `CLAUDE.md`, por
  el precedente explicito de #359 (*"el frontmatter de cada agente es la fuente de verdad"*).

## Descartado

- Escribir `fable[1m]`: el sufijo es un no-op que el CLI elimina para Fable.
- Limitar el cambio al planner interno (recomendacion del refinamiento, anulada por el usuario).
- Partir el issue en dos PRs por tocar los dos lados: verificado que MEF-ADR-0019 seccion E no
  se dispara sin ruta nueva.
- Crear un ADR o documentar la politica de modelos en `CLAUDE.md`.

## Preguntas abiertas

- CA-5 sigue vivo: confirmar contra `docs.claude.com` que `fable` es valor valido de frontmatter
  de subagente y que Fable 5 documenta 1M nativo. Si la doc contradice al catalogo del binario,
  gana la doc y el issue se replantea.
- Si la cuenta tiene Fable habilitado no se puede saber desde un subagente; lo dicen `/model`
  o `/usage-credits` en sesion interactiva.
- Queda sin medir el impacto real del 2x sobre el gasto mensual de planeacion.

## Referencias

Issues creados: #492 (Migrar los dos planners al modelo Fable 5) -- `tipo:tooling`, `estado:listo`.
Precedentes: #359 (pin a `claude-opus-5[1m]`), #411 / commit `c84521f` (revert al alias `opus[1m]`).
