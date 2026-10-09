---
fecha: 2026-10-01
hora: 20:47
sesion: mefisto-planner
tema: refinar auditoria NuGet no bloqueante para consumidores
---

## Contexto
El draft #1760 llego desde Bitakora.ControlAsistencia tras detectar tarde avisos NuGet enterrados en logs de build.

## Descubrimientos
Mefisto no genera el ci.yml general del consumidor: setup-github-ci.sh configura identidad Azure, mientras los scaffolders generan workflows de deploy con filtros de rutas. Microsoft Learn confirma que dotnet package list en .NET 10 admite salida JSON, inclusion de transitivos y consulta de advisories con restore implicito.

## Decisiones
El usuario eligio cobertura en todos los PR. #1760 quedo listo y acotado a /onboard publicado: bajo confirmacion crea un workflow de auditoria independiente en el consumidor, sin pisar CI existente ni bloquear el PR ante advisories o fallo de consulta. Origen del consumidor preservado; ADRs 0019, 0025, 0049, 0050 y 0053 listados.

## Descartado
No editar ci.yml del consumidor desde este repo ni usar workflows de deploy por dominio como unica via de aviso; no tratar vulnerabilidades como errores del build.

## Preguntas abiertas
La adopcion en consumidores existentes requiere invocar /onboard con una release que incorpore el cambio y entregar el workflow resultante por PR del consumidor.

## Referencias
Issues refinados: #1760, Generar avisos NuGet no bloqueantes en todos los PR del consumidor.
Issues creados: ninguno.
