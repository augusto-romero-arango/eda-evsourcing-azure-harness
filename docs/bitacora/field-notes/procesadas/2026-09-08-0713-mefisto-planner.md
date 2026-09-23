---
fecha: 2026-09-08
hora: 07:13
sesion: mefisto-planner
tema: Reclasificacion del rollout y cierre documental de los planners
---

## Contexto

La planeacion inicial del rollout multi-runtime creo 25 issues consecutivos, #1042-#1066,
directamente con `estado:listo`. Se reviso cuales habian recibido despues un refinamiento
sustantivo y cuales solo conservaban el alcance preliminar o habian recibido ajustes mecanicos de
dependencias. Al cerrar ese trabajo quedo visible un segundo problema: `mefisto-planner` habia
creado esta nota en una rama intermedia, sin commit ni PR, y el checkout principal ya no estaba en
`main`.

## Descubrimientos

- El historial `userContentEdits` de GitHub permite distinguir una edicion sustantiva del body de
  una simple actualizacion de dependencias.
- #1052, #1053 y #1057 recibieron refinamientos sustantivos aunque sus field notes aun no estaban
  presentes en esta carpeta. #1052 genero #1089; #1053 genero #1091, #1092 y #1093; #1057 corrigio
  su inventario contra los seis handlers reales de `hooks/hooks.json`.
- Las ediciones de #1055, #1060, #1061 y #1062 solo mantuvieron el grafo tras desgloses de otros
  issues; no constituyen un segundo refinamiento de su propio alcance.
- #1054, #1056, #1058, #1059 y #1063-#1066 no tenian ninguna edicion de contenido desde su
  creacion.
- Tanto `agents/planner.md` como `src/internal/agents/mefisto-planner.md` terminan despues de
  escribir sus field notes: no ejecutan commit, push, PR ni restauran la rama inicial.
- Los historiadores publicado e interno ya contienen un precedente de cierre atomico, pero
  reutilizan cualquier rama activa. Para los planners es mas seguro entregar los artefactos de la
  sesion desde una rama o worktree documental aislado.

## Decisiones

- Conservar `estado:listo` en los originales abiertos #1046, #1052, #1053 y #1057 porque existe
  evidencia de un refinamiento sustantivo posterior a la planeacion inicial.
- Cambiar de `estado:listo` a `estado:borrador`, con confirmacion explicita del mantenedor, los 12
  originales #1054, #1055, #1056 y #1058-#1066.
- Preservar `tipo:tooling` y `bloqueado` en los 12 issues reclasificados; esta sesion solo corrige
  la afirmacion falsa de que cumplen Definition of Ready.
- Excluir de la reclasificacion los issues derivados #1072, #1075, #1076, #1079, #1080, #1089 y
  #1091-#1093, porque nacieron de refinamientos posteriores y no pertenecen al conjunto original.
- Crear dos issues independientes por MEF-ADR-0019: #1095 para el planner publicado y #1096 para
  `mefisto-planner`.
- Ambos planners deben abrir un PR documental y dejarlo abierto. Al terminar restauran la rama
  inicial: una sesion iniciada en `main` termina en `main`; una iniciada sobre trabajo del usuario
  vuelve a esa rama.
- El PR del planner publicado incluye la field note y solo el delta de glosario producido por la
  misma sesion. El interno incluye exclusivamente su field note. Ninguno absorbe cambios ajenos.

## Descartado

- Pasar a borrador todos los issues abiertos por rango numerico, porque habria degradado issues
  derivados que ya nacieron refinados.
- Usar `updatedAt` como unica evidencia: los cambios de dependencias tambien actualizan ese campo.
- Reabrir o reclasificar los originales ya cerrados #1042-#1045 y #1047-#1051.
- Forzar siempre `main` aunque la sesion hubiera empezado en una rama de trabajo del usuario.
- Fusionar automaticamente el PR documental: la entrega y la restauracion de rama cierran la
  responsabilidad del planner; el merge permanece separado.
- Crear un helper compartido entre ambos lados: dos agentes separados preservan la frontera de
  MEF-ADR-0019 y el cambio no justifica una abstraccion comun.

## Preguntas abiertas

- Definir el orden conversacional en que se refinaran los 12 borradores; cada uno debera volver a
  pasar la revision de complejidad simplificada antes de recuperar `estado:listo`.
- Implementar #1095 y #1096 y verificar el cierre desde `main`, desde otra rama y con cambios
  preexistentes en el working tree.

## Referencias

Issues creados: #1095 y #1096.

Issues reclasificados a borrador: #1054, #1055, #1056, #1058, #1059, #1060, #1061, #1062,
#1063, #1064, #1065 y #1066.
