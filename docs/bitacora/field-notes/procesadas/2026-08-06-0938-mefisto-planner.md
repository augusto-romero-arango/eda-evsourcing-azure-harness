---
fecha: 2026-08-06
hora: 09:38
sesion: mefisto-planner
tema: guia de migracion de la capa EDA para consumidores existentes + residual docs/eda en prompts de tooling
---

## Contexto

Continuacion de la sesion de la manana (ver field notes 2026-08-06-0854). El usuario pidio crear una guia de migracion para los consumidores existentes afectados por la demolicion de la capa EDA (MEF-ADR-0040): mudanza del glosario de lenguaje ubicuo y destino de las demas referencias a `docs/eda/`.

## Descubrimientos

- **El batch `559 562 563` cerro completo** durante la manana: el fallback del glosario ya vive en `agents/planner.md`, y `/show-flow`, `eda-modeler`, `event-stormer` y `eda-lint.sh` ya no existen en main. #568 tambien cerro.
- **MEF-ADR-0040 respalda la guia sin enmienda**: decision 5 es greenfield-only ("documentacion muerta, no se borra") pero su Alt 2 deja la limpieza en manos del consumidor — la guia manual es el instrumento de esa decision, no doctrina nueva. La tabla artefacto -> fuente de verdad ejecutable de su decision 1 es el corazon reutilizable.
- **Residual del barrido de #562**: los prompts de writer y reviewer de `scripts/tooling-pipeline.sh` (L522 y L642 en main actual) seguian listando `docs/eda/` como ruta de escritura del consumidor. El grep de #562 buscaba nombres de artefactos (`eda-modeler|event-stormer|show-flow|eda-lint`), no la ruta — y dos de mis propios greps de sesion lo enmascararon con `grep -v "adr/"` porque la misma linea contiene `docs/adr-proyecto/`. Leccion: al barrer rutas, filtrar por columnas, no por substring de linea.
- **Gates**: `docs/*` ya esta en `is_path_in_mefisto_scope` (`_mefisto-common.sh:79`) — un archivo nuevo bajo `docs/` del harness no necesita PR de registro previo (MEF-ADR-0019 seccion E no aplica).

## Decisiones

1. **Issue #578**: crear `docs/migracion-capa-eda.md` (junto a `greenfield-quickstart.md`) con: el `git mv` del glosario a `docs/ddd/` como unico paso activo; limpieza opcional de artefactos muertos con la tabla del ADR en lenguaje de consumidor; limpieza de referencias propias del consumidor; y que desaparece del harness al hacer `/upgrade`. Descubrimiento via fragmento `changelog.d/` (el delta que muestra `/upgrade`).
2. **La unica operacion que la guia marca como incorrecta es mantener dos copias del glosario** (coherente con el fallback de solo-lectura de MEF-ADR-0040 decision 4); `context-map.yaml` se documenta como perdida aceptada, no como algo a migrar.
3. **El residual de los prompts viaja en el mismo issue #578** (instruccion del usuario; #568, que tocaba ese archivo, ya habia cerrado): `docs/ddd/` toma el lugar de `docs/eda/` en la enumeracion de documentacion del consumidor.
4. **Dos componentes en un issue, justificado**: las 2 lineas residuales son parte del mismo barrido de MEF-ADR-0040 y no ameritan issue propio.

## Descartado

- **Sumar el residual a #568**: propuesto inicialmente (mismo archivo), invalidado porque #568 ya habia cerrado.
- **Tercer issue micro para el residual**: dos lineas no ameritan el overhead de un eslabon propio.

## Preguntas abiertas

- Ninguna nueva. (Las de la sesion 0854 siguen vigentes.)

## Referencias

Issues creados: #578 (guia de migracion capa EDA + residual docs/eda en prompts, `estado:listo`).
Issues cerrados: ninguno en este segmento (el batch #559/#562/#563 y #568 cerraron via pipeline, no via planner).
Implementacion sugerida: `/mefisto-tooling 578`.
