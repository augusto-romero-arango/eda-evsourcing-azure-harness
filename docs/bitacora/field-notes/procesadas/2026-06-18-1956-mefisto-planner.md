---
fecha: 2026-06-18
hora: 19:56
sesion: mefisto-planner
tema: Mejoras al /mefisto-sequential para seguir cadenas de dependencias internas
---

## Contexto

Al planear el orden de #44/#43/#45 surgio que `/mefisto-sequential` no puede lanzar una
cadena cuyos bloqueos se resuelven dentro del propio batch (paso 1.5 aborta si una
dependencia sigue OPEN). El usuario pidio dos capacidades: (1) sync verificado entre
eslabones, (2) que la evaluacion entienda bloqueos satisfechos por el orden del batch.

## Descubrimientos

- `mefisto-batch-pipeline.sh` Stage 4 (L256-258) ya hace `git pull origin main`, pero es
  **best-effort**: silencia el fallo con `warn ... (continuando)`. No verifica que el merge
  del PR anterior este en main local antes del siguiente eslabon.
- Hay 3 capas de actualizacion (batch Stage 4; `git pull` al inicio del tooling-pipeline
  L206-207; "Sincronizar con main" fetch+merge antes del PR L472-506). Ninguna garantiza,
  de forma fail-loud, el sync entre eslabones de la cadena.
- `mefisto-sequential.md` paso 1.5 (L42-66) aborta si CUALQUIER dependencia esta OPEN, sin
  distinguir si es un issue del mismo batch que va antes en el orden.

## Decisiones

- Dos issues separados (componentes distintos) con dependencia entre si:
  - **#46** (bug, estado:listo) - motor: sincronizar main de forma verificada y fail-loud
    entre eslabones. Bloquea #47.
  - **#47** (estado:listo, bloqueado) - skill: permitir batches cuyos bloqueos se resuelven
    por el orden del propio batch. Depende de #46.
- #47 depende de #46 porque permitir cadenas con bloqueos internos solo es seguro si el sync
  entre eslabones esta garantizado.

## Descartado

- Afirmar "no hay sync": el codigo si intenta `git pull origin main`; el defecto es que es
  best-effort/silenciado, no que falte por completo. El issue #46 lo reformula como
  "verificado y fail-loud".

## Preguntas abiertas

- #47 CA-5: ¿el skill retira el label `bloqueado` al validar (recomendado) o se documenta que
  la resolucion ocurre durante la ejecucion? Decision pendiente de confirmar al refinar/implementar.

## Referencias

Issues creados: #46 (sync motor), #47 (gate sequential).
Orden de implementacion sugerido: #46 -> #47.
Nota: para los #44/#43/#45 actuales aplica aun la "opcion 1" (correr #44 solo y luego
`/mefisto-sequential 43 45`) hasta que #46 y #47 esten mergeados.
