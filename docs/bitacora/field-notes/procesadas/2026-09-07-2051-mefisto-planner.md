---
fecha: 2026-09-07
hora: 20:51
sesion: mefisto-planner
tema: Refinamiento de la arquitectura publicada multi-runtime
---

## Contexto

Se reviso el issue #1042, raiz doctrinal del rollout multi-runtime para consumidores, que ya estaba abierto con `tipo:tooling` y `estado:listo`.

## Descubrimientos

- #874 y #879 estan cerrados; el pipeline interno actual ya resuelve `MEFISTO_RUNTIME` y usa el runner neutral.
- El lado publicado conserva acoplamientos verificables a `CLAUDE_PLUGIN_ROOT`, `.claude/harness.config.json`, `.claude/pipeline/`, `CLAUDE.md` y al cache del marketplace de Claude.
- #1042 bloquea directamente #1043, #1047, #1049, #1050, #1051 y #1057, y transitivamente el resto del corte #1044-#1066.
- `pipeline-state/` ya tiene semantica neutral propia bajo MEF-ADR-0017 y no debe quedar absorbido implicitamente por la futura `.mefisto/pipeline/`.

## Decisiones

- Mantener #1042 como un issue exclusivamente doctrinal: crea MEF-ADR-0053 y hace una enmienda acotada a MEF-ADR-0049, sin poblar las rutas nuevas.
- Fijar `src/runtime/` solo para la mecanica compartida de runner/eventos; doctrina, scope y orquestacion permanecen separados por MEF-ADR-0019/0018.
- Exigir una sola SemVer/tag para Claude y OpenCode, versiones OpenCode inmutables, activacion atomica y deteccion visible de versiones/commits divergentes.
- Incluir paridad headless e interactiva y un corte vertical real de `/mefisto:tooling` como gate antes de migrar el resto del catalogo.
- Resolver la ambiguedad del impacto: #1042 no modifica `AGENTS.md`; esa migracion pertenece a #1051.

## Descartado

- Crear rutas, instaladores o adaptadores dentro del mismo issue del ADR.
- Fusionar politica o doctrina publicada/interna dentro del nucleo comun.
- Tratar la presencia de archivos generados como evidencia suficiente de soporte al consumidor.

## Preguntas abiertas

- El mecanismo concreto con el que OpenCode proyectara la version activa a sus rutas globales debe verificarse contra la documentacion y el binario vigentes en #1053; el ADR fija la invariante, no anticipa symlinks o loader.
- La ruta exacta del destino Claude dentro de `dist/` debe quedar decidida y documentada por MEF-ADR-0053 antes de implementar el generador.

## Referencias

Issues creados: ninguno.

Issue refinado: #1042 — Registrar la arquitectura de distribucion multi-runtime para consumidores.
