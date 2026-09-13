---
fecha: 2026-09-12
hora: 12:11
sesion: mefisto-planner
tema: Inconsistencia del canon OpenTelemetry del write-side
---

## Contexto
La tercera corrida de `/scaffold certificacion`, ya con Mefisto `v0.37.10`, termino exitosamente y abrio el PR #5 del consumidor. Se reviso el resultado antes de autorizar el merge y apply.

## Descubrimientos
- Los markers canonico y legacy del consumidor confirman que la corrida uso `v0.37.10`; no es una sesion vieja ni una divergencia de instalacion.
- El PR #5 queda limpio ante `git diff --check`, es mergeable y su Terraform Plan esta verde con `7 add, 1 change, 0 destroy`.
- Pese a #1230, el Function App volvio a emitir `OpenTelemetry.Extensions.Hosting 1.15.3` y sus tests `OpenTelemetry.Exporter.InMemory 1.15.3`; la receta y MEF-ADR-0003 fijan `1.13.1`.
- #1230 implemento el gate dentro del Paso 7 del prompt de `domain-scaffolder`. Su prueba demuestra que la funcion existe y funciona de forma aislada, pero `scripts/scaffold-pipeline.sh` no la ejecuta ni verifica semanticamente los `.csproj`.
- La replica de Claude demostro que bajar solo esos dos pines no es viable: `dotnet build` falla durante restore con NU1605 porque `Azure.Monitor.OpenTelemetry.Exporter 1.8.2` exige `OpenTelemetry.Extensions.Hosting >= 1.15.3`. Los 25 tests no llegan a ejecutarse.
- El registro oficial de NuGet confirma que toda la linea 1.8.x del exporter exige al menos Hosting 1.15.3; conservar Hosting 1.13.1 requeriria bajar el exporter hasta 1.4.0.
- GitHub Advisory Database identifica `OpenTelemetry.Api` anterior a 1.15.3 como vulnerable a GHSA-g94r-2vxg-569j y 1.15.3 como primera version corregida.
- Mientras llegaba esta evidencia, #1242 se implemento y mergeo mediante PR #1244. La frontera mecanica es util, pero codifico `OTEL_PIN_CANONICO=1.13.1` y una fixture sana que no representa un restore posible del stack completo.
- Restaurado el commit remoto `2d3dece` sin el downgrade, el consumidor compila con 0 warnings y 0 errores y sus 25 tests unitarios pasan. El unico fallo local pertenece a `HealthSmokeTests`: no resuelve la Function App porque aun no existe antes del primer merge/apply, comportamiento esperado del smoke predeploy.
- El unico check remoto del PR #5 es `Terraform Plan`; `domain-scaffolder` genera `deploy-{kebab}.yml` con un job `build-and-test`, pero el workflow no escucha `pull_request`. La propia plantilla afirma que existe un "CI del PR", por lo que hay una garantia declarada pero no materializada.

## Decisiones
- Conservar los pines 1.15.3 del PR consumidor #5; las dos ediciones de downgrade quedan descartadas y no deben commitearse.
- #1242 llevo correctamente el enforcement a la frontera determinista de `scripts/scaffold-pipeline.sh`, pero su valor concreto debe corregirse antes de la siguiente certificacion de `/scaffold`.
- Mantener #1230 como contrato de la receta, pero no considerarlo suficiente como gate operativo.
- Corregir el harness en tres issues secuenciales y pequenos: #1245 decide el canon en MEF-ADR-0003; #1246 alinea `domain-scaffolder`; #1247 cambia el gate y sus fixtures.
- No revertir la estructura del gate de PR #1244: su cardinalidad, parseo XML, diagnosticos y posicion previa al push siguen siendo validos.
- Considerar el PR consumidor #5 apto para merge por evidencia local de build/tests y plan remoto; el fallo del smoke no bloquea porque su precondicion es el deploy posterior al apply.
- Crear #1248 para ejecutar el job `build-and-test` existente tambien en pull requests, protegiendo expresamente los jobs de deploy y smoke tests.

## Descartado
- Tratar `1.15.3` como una deriva incorrecta solo porque contradice un ADR desactualizado.
- Bajar Hosting e InMemory a 1.13.1: produce NU1605 y reintroduce una version afectada por GHSA-g94r-2vxg-569j.
- Bajar `Azure.Monitor.OpenTelemetry.Exporter` a 1.4.0 para conservar 1.13.1: retrocede el exporter sin una necesidad tecnica.
- Revertir por completo PR #1244 en vez de corregir su constante y fixtures.
- Tratar el smoke predeploy como regresion del dominio: su DNS no existe todavia por construccion.
- Dar por suficiente la validacion local como politica permanente: resuelve este baseline, pero no deja evidencia durable en GitHub para PRs futuros.
- Atribuir la salida a una instalacion vieja: ambos markers observados apuntan a `0.37.10`.

## Preguntas abiertas
- Obtener autorizacion explicita para mergear el PR consumidor #5; despues observar Terraform Apply, deploy y smoke tests post-deploy.
- Implementar y liberar #1245 -> #1246 -> #1247 antes de usar nuevamente `/scaffold` como certificacion intacta del harness.
- Implementar #1248 y portar su cambio al workflow del dominio ya scaffoldeado, que el agente no sobrescribe por idempotencia.

## Referencias
Issues creados: #1242, #1245, #1246, #1247, #1248
PR del gate ya mergeado: #1244
PR consumidor apto para decision de merge: #5
