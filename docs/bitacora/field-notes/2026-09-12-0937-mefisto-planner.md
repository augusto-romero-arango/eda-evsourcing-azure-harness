---
fecha: 2026-09-12
hora: 09:37
sesion: mefisto-planner
tema: Revision del scaffold de certificacion emitido por v0.37.8
---

## Contexto
Se retomo la revision del PR #4 del consumidor privado de certificacion antes de autorizar su merge, apply de infraestructura y deploy del primer dominio.

## Descubrimientos
- El plan remoto queda en `7 to add, 1 to change, 0 to destroy`; el unico cambio sobre infraestructura existente elimina `zone = "1"` del PostgreSQL mediante update in-place.
- El output de `func init` conservado por `domain-scaffolder` dejo el `.gitignore` del Function App y su `.csproj` en CRLF. `git diff --check origin/main...HEAD` los reporta como trailing whitespace.
- Ni el Paso 7 de `domain-scaffolder` ni `scripts/scaffold-pipeline.sh` ejecutan `git diff --check`; por eso el pipeline publico la rama y abrio el PR pese al defecto textual.
- El scaffold emitio `OpenTelemetry.Extensions.Hosting 1.15.3` y `OpenTelemetry.Exporter.InMemory 1.15.3`, aunque la receta publicada y MEF-ADR-0003 fijan `1.13.1`. Los comentarios generados siguen citando `1.13.1`, por lo que la salida no representa una migracion coherente.
- El PR solo tiene como check remoto `Terraform Plan`; no hay evidencia durable de build/tests en GitHub. Las ejecuciones locales de `dotnet`, `terraform` y `actionlint` no estuvieron permitidas por la politica de comandos de la sesion.

## Decisiones
- Mantener el PR consumidor #4 abierto pero bloqueado; no mergear ni disparar apply con hallazgos conocidos.
- No parchear manualmente el consumidor: MEF-ADR-0053 exige corregir el harness, publicar una release y regenerar la evidencia de certificacion.
- Separar la correccion en tres issues pequenos: normalizacion LF en el agente, gate textual en el pipeline y verificacion de pines OpenTelemetry en el agente.
- Declarar que el gate del pipeline depende de la normalizacion LF para no introducir una release que bloquee sistematicamente el output conocido de `func init`.

## Descartado
- Corregir finales de linea o versiones directamente en la rama `scaffold-certificacion` del consumidor.
- Dar por verificados build, tests o validacion local cuando los comandos fueron denegados.
- Mergear basandose unicamente en que el plan Terraform no contiene destrucciones.

## Preguntas abiertas
- Tras publicar los fixes, decidir si se cierra el PR consumidor #4 y se regenera el scaffold desde `main` para conservar una certificacion limpia end-to-end.
- Ejecutar build, tests, validacion Terraform y lint de workflows en un contexto autorizado o mediante checks remotos antes del merge futuro.
- Confirmar en una corrida posterior si el update in-place que elimina la zona observada de PostgreSQL aplica correctamente o requiere estabilizar la configuracion del recurso.

## Referencias
Issues creados: #1228, #1229, #1230
