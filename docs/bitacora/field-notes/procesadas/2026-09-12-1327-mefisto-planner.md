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
- #1251 se implemento y cerro mediante PR #1253. La receta publicada conserva el create con zona asignada por Azure y protege los updates con `ignore_changes = [zone]`; sus suites reportaron 19/19 y 208/208 checks verdes.
- El consumidor porto el mismo cambio en su PR #6. El run `34711729734` completo Terraform Apply, siembra de secretos y reciclado de Function Apps en verde.
- El dominio ya habia completado build, tests, deploy y smoke tests en el run `34709338524`; el fallo simultaneo del apply de PR #5 no impidio ese deploy. El workflow posterior al fix de zona salto correctamente el redeploy porque PR #6 solo tocaba el modulo compartido de infraestructura.

## Decisiones
- Mantener `postgresql_zone = null` para que Azure elija zona durante el create y agregar `ignore_changes = [zone]` junto a `prevent_destroy = true` para los updates.
- Acotar #1251 al agente publicado `infra-base-scaffolder` y su prueba de contrato; MEF-ADR-0021 aplica como fuente del contrato, pero no requiere enmienda para este fix.
- Incluir migracion explicita: `/infra-base` no sobrescribe `.tf` existentes, por lo que consumidores ya provisionados deben aplicar el mismo cambio manual y confirmar un plan sin update ni recreacion de PostgreSQL.
- Mantener el apply exclusivamente en CI despues del merge, conforme a MEF-ADR-0022.
- Dar por cerrado el incidente: agente y consumidor quedaron corregidos, el apply posterior funciona y el dominio desplegado supera sus smoke tests.

## Descartado
- Fijar en HCL la zona que Azure asigno: acopla el entorno a una zona concreta y vuelve a divergir tras un failover.
- Cambiar o bajar el provider como workaround: la restriccion esta documentada y se reproduce tambien en versiones anteriores.
- Eliminar `prevent_destroy`: no resuelve el drift y debilita la proteccion del event store.
- Ejecutar el apply localmente o trasladarlo al gate del PR.

## Preguntas abiertas
- Si el modulo incorpora alta disponibilidad en el futuro, reevaluar en ese mismo cambio el lifecycle de `high_availability[0].standby_availability_zone`.

## Referencias
Issues refinados: #1251
Issues completados: #1251
PR Mefisto: #1253
PR consumidor: #6
Run de origen: https://github.com/augusto-romero-arango/mefisto-consumer-certification/actions/runs/34709338409
Apply recuperado: https://github.com/augusto-romero-arango/mefisto-consumer-certification/actions/runs/34711729734
Deploy y smoke tests verdes: https://github.com/augusto-romero-arango/mefisto-consumer-certification/actions/runs/34709338524
Provider: https://github.com/hashicorp/terraform-provider-azurerm/blob/main/website/docs/r/postgresql_flexible_server.html.markdown
Issue upstream: https://github.com/hashicorp/terraform-provider-azurerm/issues/25538
