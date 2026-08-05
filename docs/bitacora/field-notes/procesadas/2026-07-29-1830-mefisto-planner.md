---
fecha: 2026-07-29
hora: 18:30
sesion: mefisto-planner
tema: Revalidacion y ordenamiento de #447/#448/#449 para el batch secuencial
---

## Contexto

Los tres issues (#447, #448, #449) se refinaron a `estado:listo` mas temprano el mismo dia,
en dos sesiones consecutivas de planner alimentadas por el consumidor
`Bitakora.ControlAsistencia`. Entre ese refinamiento y esta sesion se mergearon **10 PRs**
(#442 a #471). La pregunta de entrada fue si algun borrador los bloquea, cual es el orden
correcto para `/mefisto-sequential`, y si lo ya implementado invalido alguna premisa.

## Descubrimientos

### 1. Ningun borrador bloquea, pero dos comparten archivo con #447

Los tres declaran `## Dependencias: Ninguna`, ninguno lleva `bloqueado`, y
`mefisto-validate-batch-deps.sh 449 448 447` pasa. La unica coordinacion que #449 declaraba
era con **#435**, que ya cerro (PR #451).

Lo que si aparecio: **#458** y **#463** (borradores) tocan
`agents/projections-scaffolder.md`, y #463 tambien `domain-scaffolder.md` y `mef-adr-0034`.
No bloquean -- son borradores, no van en la cadena --, pero la implicacion es la inversa de
la esperada: **refinarlos antes de #447 seria refinar contra un texto que #447 reescribe**.
Orden correcto: implementar #447, luego refinar #458/#463.

### 2. La deriva de referencias de linea es asimetrica y predecible

`agents/projections-scaffolder.md` crecio a 900 lineas por cuatro PRs consecutivos (#452,
#453, #457, #462) -- todas las citas de #447 quedaron corridas. `scripts/tmux-pipeline.sh`
(630 lineas) no lo toco nadie: **todas** las citas de #449 sobre el wrapper publicado siguen
exactas. El wrapper **interno**, en cambio, paso de 174 a 276 lineas por #435.

Patron: los archivos que estan en el camino del trabajo en curso derivan rapido; los
laterales no derivan nada. Un issue refinado contra un archivo "caliente" caduca en horas.

### 3. #435 convirtio una hipotesis de #449 en punto de partida

Las notas tecnicas de #449 proponian *"si ambos se implementan cerca en el tiempo, conviene
unificar el pre-parseo de flags del wrapper en un solo lugar"*. #435 ya lo hizo:
`extract_verbose_flag()` existe. La diferencia relevante para `--from-stage`: **consume el
flag Y su valor** (dos posiciones), no una.

### 4. El radio de impacto de #447 estaba subdeclarado en 4 archivos

Barrido con `grep -rln "AssertOpcionesDeEvento|replica de metadata|guarda 3|guardas 1 y 2"`:
ademas de los 5 archivos declarados, la doctrina vieja vive en
`mef-adr-0011:61`, `agents/planner.md:743`, `commands/scaffold-projections.md:81,121` y
`agents/projection-implementer.md:50`.

**Sin barrerlos, #447 dejaria la doctrina enumerada en 4 sitios -- que es exactamente el modo
de fallo que #447 existe para eliminar.** El issue se habria "cumplido" reproduciendo su
propio defecto.

### 5. El rango de `--from-stage` depende del pipeline destino

`tdd` acepta 1-4; `tooling`, `iac` y `mefisto-tooling` solo 1-2. Como `cmd_single` resuelve
el pipeline por label, **el wrapper no puede validar el rango sin desincronizarse** del
sub-script en la primera fase nueva. Valida entero; el rango lo valida el destino.

### 6. Mefisto no ejecuta sus propios tests en ningun gate

No hay `.github/workflows/`, y ni `mefisto-tooling-pipeline.sh` ni sus gates invocan
`scripts/tests/*.sh` ni `.claude/scripts/tests/*.sh`. Los 21 archivos de test del repo se
corren solo a mano. Un CA que dice "el test nuevo pasa" no lo verifica nadie salvo que el
implementador lo corra explicitamente.

### 7. Riesgo de auto-modificacion durante un batch secuencial

`mefisto-batch-pipeline.sh` corre **en vivo** durante toda la cadena y hace `merge --ff-only`
de main entre eslabones; bash lee los scripts de forma incremental. Un PR de la cadena que
modifique ese archivo (o `_mefisto-common.sh`, ya sourceado) es un riesgo real. Los wrappers
tmux **no** lo son: montan los panes y salen antes de que arranque el primer eslabon.
Verificado que ninguno de los tres issues toca los archivos peligrosos.

## Decisiones

- **Orden del batch: `449 -> 448 -> 447`.**
  - #449 primero: cero acoplamiento doctrinal, y una vez mergeado la cadena gana la capacidad
    de retomar (`--from-stage` desde el wrapper) si un eslabon posterior cae.
  - #448 antes de #447: #448 redefine que dice la fila de `tipo:projection` en MEF-ADR-0011 y
    el template de proyeccion del planner; #447 corrige una referencia **dentro** de ese
    texto. El orden inverso obligaria a #448 a no reintroducir una frase que su alcance no
    cubre.
  - #447 al final: el mas grande (7 CAs, 9 archivos) y el unico con una decision de diseno
    abierta (la firma del seam).
- **#447 se mantiene entero, no se parte.** Se evaluo cortarlo en "ADR + Skill" vs
  "propagacion a los 5 agentes", con el segundo dependiendo del primero. Se descarto: el
  eslabon de ADR solo seria prosa cuyo valor se realiza recien con el segundo, y el
  `--from-stage` que #449 habilita cubre el riesgo de que la corrida larga caiga a medias.
- **CA nuevos, no reescritura de los existentes.** #447 gana CA-7 (barrido de referencias con
  verificacion por grep, excluyendo `CHANGELOG.md` y `docs/bitacora/` como historicos);
  #449 gana CA-7 (test + correr los tests a mano, con la razon).
- **El wrapper interno rechaza `--from-stage` en `cmd_batch`.** `mefisto-batch-pipeline.sh`
  solo acepta `--stop-on-error`, y un `--from-stage` sobre un lote es ambiguo. Coherente con
  la nota de multi-issue que el propio issue ya traia como "opcion segura".

## Descartado

- **Crear un issue nuevo para el barrido de referencias de #447.** Seria un issue que solo
  existe porque otro quedo incompleto, y que puede mergear con la doctrina a medio migrar
  entre uno y otro. Va como CA del mismo issue.
- **Validar el rango de `--from-stage` en el wrapper.** Duplicaria en el wrapper un rango que
  vive en 4 sub-scripts con valores distintos.
- **Tocar `CHANGELOG.md` en el barrido de #447.** Es historico: describe lo que se decidio
  entonces, no lo vigente.

## Preguntas abiertas

- **No hay gate que corra los tests del repo.** Candidato a issue: un workflow de GitHub
  Actions (o un paso en el pipeline interno) que ejecute `scripts/tests/*.sh` y
  `.claude/scripts/tests/*.sh`. Hoy la unica garantia es la disciplina del implementador.
  Sin filar todavia.
- **El riesgo de auto-modificacion de `mefisto-batch-pipeline.sh`/`_mefisto-common.sh` a
  media cadena no esta documentado en ningun sitio** -- se descubrio en esta sesion al
  verificar el orden. Ni `/mefisto-sequential` ni MEF-ADR-0019 lo advierten. Candidato a
  issue o a nota en el skill.
- La firma del seam de #447 (que no permita colarse `Connection`) sigue siendo decision del
  implementador dentro de CA-1.

## Referencias

Issues creados: ninguno.
Issues editados: **#447** (CA-7 nueva, 4 archivos sumados al Impacto, MEF-ADR-0011 sumado a
ADRs aplicables, citas de linea corregidas a `:312`/`:326-341`/`:344`/`:887`/`:894`, nota de
orden), **#448** (nota de orden, nota del guard `[A]` de `commands/*.md`, referencias
revalidadas), **#449** (#435 recontextualizado como punto de partida, citas del wrapper
interno corregidas a `:152`/`:167`/`:214`/`:227`/`:72-84`, CA-2 con el criterio de rango,
CA-6 reescrito sobre `extract_verbose_flag`, CA-7 nueva).
Issues cerrados: ninguno.
Lanzamiento acordado: `/mefisto-sequential 449 448 447`.
