---
fecha: 2026-09-12
hora: 12:11
sesion: mefisto-planner
tema: Bypass del gate de pines OpenTelemetry por domain-scaffolder
---

## Contexto
La tercera corrida de `/scaffold certificacion`, ya con Mefisto `v0.37.10`, termino exitosamente y abrio el PR #5 del consumidor. Se reviso el resultado antes de autorizar el merge y apply.

## Descubrimientos
- Los markers canonico y legacy del consumidor confirman que la corrida uso `v0.37.10`; no es una sesion vieja ni una divergencia de instalacion.
- El PR #5 queda limpio ante `git diff --check`, es mergeable y su Terraform Plan esta verde con `7 add, 1 change, 0 destroy`.
- Pese a #1230, el Function App volvio a emitir `OpenTelemetry.Extensions.Hosting 1.15.3` y sus tests `OpenTelemetry.Exporter.InMemory 1.15.3`; la receta y MEF-ADR-0003 fijan `1.13.1`.
- #1230 implemento el gate dentro del Paso 7 del prompt de `domain-scaffolder`. Su prueba demuestra que la funcion existe y funciona de forma aislada, pero `scripts/scaffold-pipeline.sh` no la ejecuta ni verifica semanticamente los `.csproj`.
- Un agente puede salir 0 omitiendo una instruccion; build, tests y `git diff --check` permanecen verdes porque `1.15.3` es una version valida, aunque diverja del contrato arquitectonico.

## Decisiones
- No mergear el PR consumidor #5: el plan no destructivo no compensa la deriva semantica conocida.
- Crear #1242 para llevar el enforcement a la frontera determinista de `scripts/scaffold-pipeline.sh`, despues del commit defensivo y antes del push.
- Mantener #1230 como contrato de la receta, pero no considerarlo suficiente como gate operativo.
- No actualizar el pin a `1.15.3` dentro de este fix; una subida requiere su propia decision coherente sobre ADR, receta, comentarios y pruebas.

## Descartado
- Aceptar el PR porque compila o porque ambos paquetes quedaron alineados entre si en `1.15.3`.
- Corregir los dos `.csproj` manualmente en el consumidor.
- Atribuir la salida a una instalacion vieja: ambos markers observados apuntan a `0.37.10`.

## Preguntas abiertas
- Tras implementar y publicar #1242, cerrar y limpiar el PR #5 y regenerar desde un baseline limpio.
- Evaluar en un issue separado si el pin write-side debe evolucionar desde `1.13.1`; no es requisito para cerrar el bypass.

## Referencias
Issues creados: #1242
PR consumidor bloqueado: #5
