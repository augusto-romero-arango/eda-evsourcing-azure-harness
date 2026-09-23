---
fecha: 2026-09-12
hora: 18:46
sesion: mefisto-planner
tema: launcher OpenCode legado bloquea upgrade multi-runtime
---

## Contexto

Al repetir la preparación de #1180 con `v0.37.12`, el consumidor confirmó que Claude ya cargaba la versión candidata y ejecutó `/mefisto:upgrade` para habilitar OpenCode sin bootstrap manual.

## Descubrimientos

- La instalación OpenCode preexistente expone el launcher global, pero pertenece al contrato anterior a `projection-status`; su mensaje de uso enumera `install`, `activate`, `prune`, `project`, `deactivate`, `status`, `diagnose` y `package-root`.
- `commands/upgrade.md` reduce correctamente una respuesta no versionada a `unavailable`, pero prohíbe cualquier alineación para ese estado y remite a diagnóstico manual.
- `scripts/update-plugin.sh --align-opencode` ya contiene la autoridad necesaria para migrar: valida identidad, usa `status`/`package-root` cuando el launcher es válido y cae al bootstrap confiable de la raíz Claude destino en caso contrario.
- El defecto está en el gate de consentimiento del skill, no en el instalador ni en el consumidor.

## Decisiones

- No pedir descargas, bootstrap, edición de ledger ni reparación manual al usuario.
- Crear #1270 como bug `estado:listo`, acotado al skill publicado `/upgrade`.
- Exigir confirmación explícita antes de migrar un contrato legado: la mera presencia del launcher o de `active` no constituye adhesión.
- Mantener `conflict`, `operation-in-progress` y salidas arbitrarias bajo el régimen fail-closed sin mutación.
- Añadir #1270 como dependencia de #1180 y restaurar su label `bloqueado`; la evidencia observada satisface la regla de CA-6 para detener la certificación ante un defecto.

## Descartado

- Abrir inmediatamente el consumidor con OpenCode: todavía no existe una proyección certificable.
- Usar comandos internos del instalador para saltar `/upgrade`: ocultaría el defecto que debe superar el consumidor real.
- Tratar cualquier `unavailable` como consentimiento implícito: violaría MEF-ADR-0053.

## Preguntas abiertas

- Implementación y release patch de #1270.
- Repetición de `/mefisto:upgrade` y continuación de #1180 con la release corregida.

## Referencias

Issue creado: #1270 — Permitir que /upgrade migre launchers OpenCode sin projection-status.

Issue bloqueado: #1180.

Fuentes: `commands/upgrade.md`, `scripts/update-plugin.sh`, `src/published/scripts/install-opencode-release.sh`, MEF-ADR-0050 y MEF-ADR-0053.
