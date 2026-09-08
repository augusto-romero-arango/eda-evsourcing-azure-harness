---
fecha: 2026-09-07
hora: 18:07
sesion: mefisto-planner
tema: Refinamiento del gate de dependencias bloqueadas en el flujo IaC publicado
---

## Contexto
Se retomo el draft #829, nacido de una corrida de `/infra 571` en el consumidor
Bitakora.ControlAsistencia que avanzo hasta writer, reviewer y Terraform aunque
una dependencia declarada seguia abierta. El objetivo fue confirmar la causa en
el harness actual, acotar el cambio y llevar el trabajo a Definition of Ready.

## Descubrimientos
- `commands/infra.md` sigue sin el preflight de `bloqueado` que ya existe en
  `commands/implement.md` (paso 1.6).
- `scripts/iac-pipeline.sh` descarga `number,title,body,state`, sin `labels`, y
  pasa de validar que el issue esta abierto a preparar el worktree; su bloque
  llamado `Verificar dependencias` solo comprueba CLIs.
- `commands/tooling.md` ya incorporo el gate despues de capturarse el draft
  original, como parte de la evolucion del modo `--variant`; esa parte del
  diagnostico de #829 estaba desactualizada.
- Los pipelines headless `tooling-pipeline.sh` y `tdd-pipeline.sh` tampoco
  aplican hoy el gate, pero no formaron parte del incidente IaC refinado.
- La invocacion directa de IaC es `scripts/iac-pipeline.sh <n>`; `--infra`
  pertenece al wrapper `tmux-pipeline.sh`.

## Decisiones
- Se partio el draft por componente principal: #829 conserva la defensa
  headless de `iac-pipeline.sh`; #1038 cubre solamente el skill `/infra`.
- Ambos issues son independientes: cada uno protege un punto de entrada distinto
  y aporta valor por si solo. Los dos quedaron `tipo:tooling`, `estado:listo` y
  `bug`.
- Se mantuvo para ambos el contrato observable de `/implement` 1.6: leer las
  referencias `#NNN` de la seccion `## Dependencias`, consultar issue y PR, y
  considerar resuelto solo `CLOSED`/`MERGED`. No se introdujo en este corte el
  parser forward canonico de `next-order.sh`.
- #829 abortara antes de `git fetch origin main`, worktree y agentes, y tendra
  cobertura bash para los caminos sin label, dependencia abierta y todas las
  dependencias resueltas.
- No se extrae helper a `_pipeline-common.sh` con un unico consumidor en este
  corte. La posible generalizacion se reevaluara si se priorizan los gaps
  headless de TDD/tooling.
- Revision de complejidad: cada issue tiene cinco CAs homogeneos, un solo
  componente principal, lado publicado decidido, verificaciones concretas y
  alcance estimado en una pasada menor de 30 minutos para un humano competente.

## Descartado
- Mantener skill y pipeline juntos en #829: violaba el criterio simplificado de
  un componente principal.
- Incluir ahora `tooling-pipeline.sh` y `tdd-pipeline.sh`: ampliaba el incidente
  observado a dos pipelines adicionales sin evidencia de campo propia.
- Replicar cambios al lado interno: Mefisto no tiene pipeline IaC.
- Hacer que metadata ausente o no canonica abortara con un contrato nuevo: se
  eligio conservar la semantica vigente de `/implement` para este refinamiento.

## Preguntas abiertas
- Si aparece evidencia de invocaciones directas de `tooling-pipeline.sh` o
  `tdd-pipeline.sh` sobre issues bloqueados, decidir si ameritan issues separados
  y si el tercer consumidor justifica extraer un helper comun.

## Referencias
Issues creados: #1038 (`Agregar validacion de dependencias bloqueadas a /infra`).

Drafts refinados: #829 (`Agregar gate de dependencias bloqueadas a iac-pipeline.sh`).
