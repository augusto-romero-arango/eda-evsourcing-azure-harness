---
fecha: 2026-09-07
hora: 22:13
sesion: mefisto-planner
tema: Refinamiento del resolutor de estado publicado #1050
---

## Contexto

Se solicitó refinar el issue #1050 del rollout multi-runtime publicado. El issue ya estaba
marcado `estado:listo`, pero conservaba `bloqueado` aunque sus dependencias arquitectónicas
#1042 y #1043 estaban cerradas, y dejaba sin decidir si el helper viviría separado de
`scripts/_pipeline-common.sh` ni cómo evitar que el estado canónico ensuciara el repo consumidor.

## Descubrimientos

- Los pipelines, visores, comandos, agentes y hooks publicados todavía componen
  `.claude/pipeline` directamente para logs, eventos, métricas, status, history, summaries,
  sesiones, raíz activa y panes Herdr.
- El precedente interno `src/internal/scripts/lib/mefisto-state.sh` ya define el contrato útil:
  escritura canónica, lectura por archivo canónica-primero/legacy-después, raíz explícita para
  worktrees y cero migración automática.
- `metrics-report.sh` y `stream-watch.sh` no sourcean hoy `_pipeline-common.sh`; por eso crear el
  helper y migrar sus lectores son cortes distintos.
- En consumidores no se puede ignorar `.mefisto/` entero: #1049 canonicaliza allí
  `.mefisto/harness.config.json`, que es configuración versionada. Solo
  `.mefisto/pipeline/` es estado local no versionado.
- El contrato greenfield del `.gitignore` vive en `infra-base-scaffolder`; `/onboard` es la
  superficie adecuada para diagnosticar consumidores existentes sin mutarlos por defecto.

## Decisiones

- El helper publicado se implementará directamente en `scripts/_pipeline-common.sh`, con los
  mismos nombres observables del precedente interno: `MEFISTO_STATE_DIR`,
  `MEFISTO_LEGACY_STATE_DIR`, `mefisto_state_path`, `mefisto_state_read_paths` y
  `mefisto_state_read_first`.
- No se sourceará la utilidad interna: MEF-ADR-0019 exige que ambos lados conserven políticas y
  evolución separadas aunque porten la misma mecánica.
- #1050 no migra callers. #1059, #1062 y #1063 siguen siendo los adoptantes directos; Herdr y
  la certificación quedan bloqueados transitivamente.
- El ignore greenfield será exactamente `.mefisto/pipeline/`; onboarding lo comprobará con
  `git check-ignore` y solo propondrá una acción manual cuando falte.
- Se retiró el label `bloqueado`; el issue conserva `tipo:tooling` y `estado:listo`.

## Descartado

- Crear un helper publicado separado con ubicación aún abierta: dejaba ambigüedad innecesaria y
  obligaba a decidir ahora su empaquetado futuro en `dist/`.
- Sourcear `src/internal/scripts/lib/mefisto-state.sh`: mezclaría los lados de MEF-ADR-0019.
- Ignorar `.mefisto/` completo en consumidores: ocultaría el config canónico versionado.
- Migrar todas las referencias `.claude/pipeline` en el mismo PR: excede un componente principal
  y duplicaría el alcance de #1059/#1062/#1063.
- Mover las señales de `pipeline-state/`: MEF-ADR-0017 mantiene su ubicación propia.

## Preguntas abiertas

Ninguna para implementar #1050.

## Referencias

Issue refinado: #1050 "Resolver el estado publicado bajo .mefisto con fallback legacy".

ADRs: MEF-ADR-0017, MEF-ADR-0019, MEF-ADR-0049, MEF-ADR-0050 y MEF-ADR-0053.
