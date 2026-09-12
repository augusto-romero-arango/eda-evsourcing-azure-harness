---
fecha: 2026-09-12
hora: 13:27
sesion: mefisto-planner
tema: Drift de zona de PostgreSQL despues del primer apply
---

## Contexto
El apply de infraestructura posterior al merge del scaffold del dominio `Certificacion` fallo al intentar actualizar la zona del PostgreSQL Flexible Server compartido. Se refino el draft #1251 para corregir la receta de `infra-base-scaffolder`.

## Descubrimientos
- El modulo generado declara `zone = var.zone` con default `null`. Azure asigna una zona durante el create y el provider la persiste en state, dejando una divergencia permanente frente al HCL.
- El segundo plan propone `zone = "1" -> null`, pero el error aparece solo durante Update: Azure no admite ese cambio salvo como intercambio con la zona standby de alta disponibilidad.
- La causa esta presente en `agents/infra-base-scaffolder.md`; `scripts/tests/test-infra-base-config-path.sh` comprueba el default y el wiring, pero no el `lifecycle` de la zona.
- El modulo consumidor reproduce literalmente la receta. No es una personalizacion ni una deriva propia del consumidor.
- La documentacion oficial del provider recomienda `ignore_changes` para `zone` y, cuando existe alta disponibilidad, para `high_availability[0].standby_availability_zone`.

## Decisiones
- Mantener `postgresql_zone = null` para que Azure elija zona durante el create y agregar `ignore_changes = [zone]` junto a `prevent_destroy = true` para los updates.
- Acotar #1251 al agente publicado `infra-base-scaffolder` y su prueba de contrato; MEF-ADR-0021 aplica como fuente del contrato, pero no requiere enmienda para este fix.
- Incluir migracion explicita: `/infra-base` no sobrescribe `.tf` existentes, por lo que consumidores ya provisionados deben aplicar el mismo cambio manual y confirmar un plan sin update ni recreacion de PostgreSQL.
- Mantener el apply exclusivamente en CI despues del merge, conforme a MEF-ADR-0022.

## Descartado
- Fijar en HCL la zona que Azure asigno: acopla el entorno a una zona concreta y vuelve a divergir tras un failover.
- Cambiar o bajar el provider como workaround: la restriccion esta documentada y se reproduce tambien en versiones anteriores.
- Eliminar `prevent_destroy`: no resuelve el drift y debilita la proteccion del event store.
- Ejecutar el apply localmente o trasladarlo al gate del PR.

## Preguntas abiertas
- Despues de portar el fix al consumidor, capturar un `terraform plan` que ya no proponga `zone = "1" -> null` antes de reintentar el apply fallido.
- Si el modulo incorpora alta disponibilidad en el futuro, reevaluar en ese mismo cambio el lifecycle de `high_availability[0].standby_availability_zone`.

## Referencias
Issues refinados: #1251
Run de origen: https://github.com/augusto-romero-arango/mefisto-consumer-certification/actions/runs/34709338409
Provider: https://github.com/hashicorp/terraform-provider-azurerm/blob/main/website/docs/r/postgresql_flexible_server.html.markdown
Issue upstream: https://github.com/hashicorp/terraform-provider-azurerm/issues/25538
