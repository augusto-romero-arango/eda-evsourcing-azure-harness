---
fecha: 2026-09-07
hora: 22:31
sesion: mefisto-planner
tema: refinar #1078 (permisos de OpenCode vs rutas neutrales del scope)
---

## Contexto

El batch interno de OpenCode del 2026-09-07 proceso `#1045, #1072, #1046, #1047`.
Solo cerro #1045. Los otros tres fallaron en Stage 1 sin producir cambio alguno.
#1078 nacio como borrador con la causa ya localizada -- la allowlist canonica
`is_path_in_mefisto_scope` admite `src/published/*`, `src/runtime/*` y `dist/*`
desde #1043, pero el mapping que genera el frontmatter `permission` de OpenCode
solo autoriza `src/internal/**` -- y con cuatro preguntas de refinamiento abiertas.

## Descubrimientos

- **El desfase afecta a los cinco agentes internos, no a dos.** Los cinco
  `src/internal/agents/*.md` declaran `capabilities: ["read","edit","shell"]` y el
  mapping de permisos es compartido: no existe politica por rol (decision de #862,
  "la diferencia entre roles la da que capacidades declara cada agente").
- **El lado Claude no sufre la divergencia.** Su scope se aplica con
  `mefisto-scope-hook.sh`, que invoca `is_path_in_mefisto_scope` directamente, y
  `adapter-claude.sh` no emite politica de rutas. La divergencia es estructural del
  lado OpenCode: su politica es un frontmatter **estatico** resuelto al arrancar el
  agente, no una funcion evaluada por hook. Esa asimetria es la razon de fondo por la
  que la paridad hay que declararla y vigilarla, no derivarla.
- **Hay una segunda divergencia de la misma clase en el mismo archivo**, en
  `capability_map.shell`: autoriza ejecutar scripts bajo `scripts/tests/`,
  `.claude/scripts/` y `src/internal/scripts/`, y ninguna forma para
  `src/runtime/scripts/` ni `src/published/scripts/`. #1047 crea
  `src/published/scripts/validate-published-artifacts.sh`.
- **Los dos tests de paridad estaban en verde y eran ciegos al defecto** (53/0 y
  88/0 en esta rama). El de paridad recorre una lista de diez rutas copiada a mano;
  el de generacion exige explicitamente solo `src/internal/**`. Una lista de casos
  copiada a mano no es un guard contra la deriva de la lista que copia.
- **`mefisto-next-order.sh` no filtra por el label `bloqueado`** (issue #466): lee
  `Depende de #N` de la seccion `## Dependencias` del issue **dependiente**. Declarar
  "Bloquea #X" en el issue bloqueante no tiene ningun efecto operativo por si solo.
- **#1057 iba a chocar contra el mismo muro**: crea `src/published/hooks/` y en el
  orden calculado quedaba *antes* de #1078. Se detecto al verificar el grafo, no al
  costo de otra corrida perdida.
- **#1078 es auto-corregible bajo la politica rota**: todo lo que toca cae en rutas
  ya autorizadas (`src/internal/**`, `.claude/scripts/**`, `.opencode/agents/**`,
  `changelog.d/**`).

## Decisiones

1. **La paridad se declara en el mapping y se vigila con un test; no se deriva
   mecanicamente del `case` de `is_path_in_mefisto_scope`.** Tres razones: (a) la
   relacion nunca fue de igualdad -- el mapping replica el gate *mas* los dos
   directorios de resumenes de stage, deliberadamente fuera del gate; (b) MEF-ADR-0019
   seccion E separa a proposito los dos artefactos (el gate final se carga desde `main`,
   fuera del worktree; la politica se genera dentro), y derivar acopla lo que el PR
   puede editar con el veredicto que no puede alterar; (c) los globs no son
   equivalentes -- en `case` de bash `src/internal/*` cruza `/`, en OpenCode hace falta
   `**`. La carga de detectar la deriva pasa al test.
2. **`dist/**` no se agrega a `edit|write|patch`.** MEF-ADR-0053 decision 1 la declara
   salida generada "no editable a mano", y el generador escribe via `bash`, no via las
   tools de edicion: denegar `edit` no impide generarla. Queda como excepcion
   documentada y probada.
3. **El alcance es el mapping compartido**: los cinco agentes internos.
4. **Se enlaza el bloqueo en el cuerpo de los issues dependientes**, no en el label:
   `Depende de #1078` en #1072, #1046, #1047 y #1057, mas el label `bloqueado` como
   convencion. El relanzamiento es operacion, no criterio de aceptacion.
5. **La divergencia de `shell` se corrige en el mismo issue** (mismo archivo, misma
   causa, misma clase de deriva), acotada a registrar las formas de invocacion en
   paridad con `src/internal/scripts/`.

## Descartado

- Derivar la politica de permisos desde el gate (ver decision 1).
- Dejar CA-2 como "se decide y prueba explicitamente si..." -- una pregunta disfrazada
  de criterio no pertenece a un issue `estado:listo`.
- Mantener CA-6 preliminar ("se reintentan #1072, #1046 y #1047") como criterio de
  aceptacion: es operacion posterior al merge, no verificable en el PR.
- Retirar `.opencode/agents/**` o `.claude/agents/**` de la politica de edicion por ser
  salida generada: no hay evidencia de dano y no es el defecto que este issue corrige.

## Preguntas abiertas

- Si el test de paridad debe derivar los patrones parseando el bloque `case` del gate
  o forzar la sincronia por otro medio: se fijo la **propiedad** de falla, no el
  mecanismo, para dejar latitud al implementador.
- Si conviene un guard generico que impida que cualquier ruta registrada en el gate
  quede sin reflejo en algun adaptador futuro (mas alla de OpenCode). Fuera de alcance.

## Referencias

Issues refinados: #1078 (borrador -> listo)
Issues modificados (dependencia + label `bloqueado`): #1072, #1046, #1047, #1057
