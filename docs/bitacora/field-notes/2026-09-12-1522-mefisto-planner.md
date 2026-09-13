---
fecha: 2026-09-12
hora: 15:22
sesion: mefisto-planner
tema: lifecycle de habilitación OpenCode
---

## Contexto

Después de aclarar en #1258 que el modo solo Claude debe respetar `deactivate`, surgió la necesidad de ofrecer dentro de Mefisto una UX para deshabilitar y volver a habilitar OpenCode sin conocer la ruta física del launcher ni ejecutar un upgrade innecesario.

## Descubrimientos

- El launcher usa `activate <semver>` para seleccionar una release instalada, pero la operación que habilita Mefisto en OpenCode es `project`. Exponer ambas como «activar» produciría una ambigüedad entre lifecycle de proyección y selección/rollback de versión.
- Hay escenarios legítimos de solo habilitación: volver después de `deactivate`, proyectar una release ya instalada, reconciliar después de resolver un conflicto o usar otra raíz efectiva de configuración, sin red ni cambio de versión.
- `status` del launcher informa la release activa. El `status` del proyector solo comprueba superficialmente el ledger y no ofrece un contrato JSON que distinga `disabled`, `enabled`, `stale` y `conflict`.
- `install`, `activate` y `prune` usan `releases/.operation.lock`; `project` y `deactivate` no participan en esa exclusión. Un upgrade concurrente con una desactivación podría competir sobre `active`, ledger y enlaces.
- Deshabilitar Mefisto desde OpenCode retira el propio comando que permitiría volver a habilitarlo. La reactivación necesita otro entrypoint confiable todavía activo: Claude/Mefisto o el launcher estable.
- Durante esta planeación se integró el PR #1259, que cerró #1256 y entregó el bootstrap remoto explícito.

## Decisiones

- Usar **enable/disable** para la proyección y reservar `activate <semver>` para selección/rollback avanzado de releases.
- Crear #1260 para exponer un estado estructurado y centralizar la validación de ledger/enlaces; #1258 pasa a depender de esa autoridad mecánica.
- Crear #1261 para serializar todas las mutaciones de release/proyección bajo una exclusión común; #1258 también depende de este gate.
- Crear #1262 para un comando neutral `/mefisto:runtimes` con `status`, `enable opencode` y `disable opencode`, más selector cuando no recibe argumentos.
- #1262 depende de #1066 y no se genera antes del veredicto del corte `/mefisto:tooling`, conforme al rollout de MEF-ADR-0053.
- Las acciones afectan solo la raíz global efectiva de la invocación y siempre la muestran; no recorren el home buscando otras configuraciones.
- Claude se reporta como lifecycle administrado externamente por su gestor de plugins; no se simula una operación enable/disable que Mefisto no controla desde dentro de la sesión.

## Descartado

- Llamar «activate» a la proyección: colisiona con el subcomando existente de selección de versión.
- Crear `/mefisto:opencode`: nacería acoplado a un runtime y rompería el principio abierto de MEF-ADR-0050.
- Incorporar enable/disable como argumentos de `/mefisto:upgrade`: mezcla lifecycle local sin red con actualización/selección de versión.
- Buscar y retirar proyecciones en raíces de configuración distintas de la efectiva: ampliaría el alcance de inspección y podría tocar estado ajeno.
- Migrar `/mefisto:runtimes` antes de #1066: ampliaría el catálogo antes de certificar el único corte vertical permitido.

## Preguntas abiertas

- La selección/rollback de una versión desde `/mefisto:runtimes` queda fuera del primer corte; el launcher conserva `activate <semver>` como mecanismo avanzado.
- La ejecución real de auto-desactivación desde OpenCode debe formar parte de la evidencia posterior a #1066.

## Referencias

Issues creados: #1260, #1261, #1262.

Issues actualizados: #1258, #1066.

Fuentes: `src/published/scripts/install-opencode-release.sh`, `src/published/scripts/project-opencode-release.sh`, `docs/testing/opencode-global-projection.md`, MEF-ADR-0019, MEF-ADR-0025, MEF-ADR-0031, MEF-ADR-0050 y MEF-ADR-0053.
