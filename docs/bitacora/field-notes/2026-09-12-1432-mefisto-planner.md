---
fecha: 2026-09-12
hora: 14:32
sesion: mefisto-planner
tema: UX de bootstrap y upgrade multi-runtime desde Claude
---

## Contexto

La preparación de la certificación publicada #1180 llegó al primer bootstrap real de OpenCode. El procedimiento vigente exige al usuario descargar el tarball y el checksum, verificar, extraer y ejecutar el instalador. Se rechazó trasladar esa secuencia manual a usuarios y se pidió una operación simple desde Claude/Mefisto que alineara ambas distribuciones.

## Descubrimientos

- `commands/upgrade.md` ya concentra la intención de actualizar Mefisto, pero `scripts/update-plugin.sh` solo actualiza el marketplace/plugin Claude y protege su caché.
- `src/published/scripts/install-opencode-release.sh` ya implementa la descarga segura, validación SHA-256, inspección del tarball, publicación inmutable y activación atómica. Sin embargo, la descarga remota se selecciona indirectamente mediante `MEFISTO_OPENCODE_INSTALLED=1`, detalle privado que exporta el launcher activo; no existe un entrypoint público para invocarla desde una copia Claude confiable.
- El primer bootstrap y los upgrades posteriores son casos distintos: una instalación activa puede actualizarse mediante el launcher; el bootstrap necesita una raíz de confianza previa. El plugin Claude recién actualizado puede ser esa raíz sin descargar ni ejecutar un script remoto sin verificar.
- El diagnóstico heredado desde la sesión Claude ve `CLAUDE_PLUGIN_ROOT` de la versión todavía cargada. Antes del reload, la verificación correcta en disco debe recibir explícitamente la nueva raíz Claude y la raíz OpenCode activa; de lo contrario reportaría una deriva esperable como si fuera defecto.
- `dist/{claude,opencode}` contiene todavía únicamente el corte vertical `/mefisto:tooling`; migrar `/upgrade` a OpenCode antes de #1180/#1181 contradiría el rollout corte-vertical-primero de MEF-ADR-0053.

## Decisiones

- Extender `/mefisto:upgrade` en lugar de crear otro slash command: la intención existente ya es actualizar Mefisto y debe seleccionar una sola versión para ambos adaptadores.
- No usar un Agent Skill: la instalación es una operación explícita y verificable, no doctrina de carga progresiva.
- Mantener una única confirmación cuando no exista una proyección OpenCode activa. Una release instalada no equivale a OpenCode habilitado: solo un ledger de proyección Mefisto válido y sus enlaces administrados autorizan la alineación/reproyección automática. Sin proyección —incluido después de `deactivate`— `/upgrade` ofrece habilitar o reactivar, pero rechazarlo actualiza únicamente Claude.
- Separar el trabajo en tres issues secuenciales por componente: entrypoint del instalador (#1256), orquestación mecánica de `update-plugin.sh` (#1257) y UX/documentación de `/upgrade` (#1258).
- No podar releases OpenCode durante el upgrade. La instalación permanece aditiva y reversible; cualquier poda conserva su opt-in separado.
- #1180 depende ahora de #1258 y recuperó el label `bloqueado`; la certificación debe probar la UX resultante y no el procedimiento manual rechazado.

## Descartado

- Crear `/mefisto:install-opencode`: duplicaría selección de versión, diagnóstico y mantenimiento respecto de `/mefisto:upgrade`.
- Crear un Agent Skill de instalación: no proporciona una entrada operativa explícita ni es el mecanismo adecuado para efectos globales.
- Exponer `MEFISTO_OPENCODE_INSTALLED` desde el comando: convertiría un detalle privado del launcher en API y haría frágil el bootstrap.
- Instalar OpenCode silenciosamente para todos los usuarios Claude en el primer upgrade: añade una proyección global nueva sin expresar consentimiento.
- Interpretar `active` o la presencia del launcher como consentimiento permanente: desharía un `deactivate` deliberado e impediría que el modo solo Claude fuera una opción estable.
- Proyectar `/upgrade` en `dist/opencode` antes de certificar `/mefisto:tooling`: ampliaría el catálogo antes del gate fijado por MEF-ADR-0053.

## Preguntas abiertas

- Tras integrar #1256-#1258 será necesaria una release patch posterior a `v0.37.11`; su número concreto se resolverá en `/mefisto-release`.
- La evidencia de #1180 deberá registrar por separado identidad destino en disco y, tras `/reload-plugins`, identidad efectiva de la nueva sesión Claude.

## Referencias

Issues creados: #1256, #1257, #1258.

Issue actualizado: #1180.

Fuentes: `commands/upgrade.md`, `scripts/update-plugin.sh`, `src/published/scripts/install-opencode-release.sh`, `src/published/scripts/project-opencode-release.sh`, `src/published/scripts/diagnose-installation-identity.sh`, MEF-ADR-0019, MEF-ADR-0025, MEF-ADR-0031, MEF-ADR-0050 y MEF-ADR-0053.
