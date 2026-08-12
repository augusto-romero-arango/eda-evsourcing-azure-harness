---
fecha: 2026-08-11
hora: 13:30
sesion: mefisto-planner
tema: refinamiento del draft #605 (versiones flotantes en plantillas csproj)
---

## Contexto

Sesion en modo refinar sobre el draft #605, creado el mismo dia desde el consumidor
`Bitakora.ControlAsistencia` tras el incidente NU1103 de la ola `Microsoft.Extensions.*
10.0.11` (eslabon `FileProviders.Physical` no publicado tumbo los 4 deploys a la vez;
mismo commit paso el restore 5 minutos antes).

## Descubrimientos

- Mapa completo de comodines en el harness: 9 lineas, 8 paquetes, 2 agentes.
  `agents/domain-scaffolder.md` (Function App ~194/~203, Tests ~1073 reusado por
  PublicEvents.Tests/PrivateEvents.Tests, SmokeTests ~1862-1867) y
  `agents/projections-scaffolder.md` (Projections.Tests ~317/~319).
- El pin exacto ya es el patron dominante del harness (~80% de las referencias:
  Cosmos.* 2.1.0, Functions.Worker 2.52.0, Marten 9.12.0, trio OpenTelemetry), con
  notas de revalidacion estilo issue #263. Los flotantes eran la excepcion.
- No existe hoy ninguna maquinaria de Dependabot/Renovate ni de
  `packages.lock.json`/`--locked-mode` en el harness.
- Precedente de nota de migracion para repos ya scaffoldeados: CA-3 del issue #253
  (idempotencia no reescribe archivos existentes -> parche manual documentado).

## Decisiones

- Direccion elegida: **pin exacto en las plantillas** (converge al patron existente,
  cambio minimo que cierra la ventana del incidente).
- Versiones concretas se deciden al implementar, verificadas contra NuGet.org
  (principio de verificacion de fuentes), no las del dia del incidente a ciegas.
- Un solo issue cubriendo ambos agentes: cambio homogeneo (mismo eje comodin->pin),
  5 CAs, <30 min.
- #605 refinado a `estado:listo` con titulo "Fijar versiones exactas de paquetes en
  las plantillas csproj de los scaffolders".

## Descartado

- Central Package Management, lock files + `--locked-mode` en CI, y Dependabot/Renovate:
  fuera de alcance **y sin draft aparte** (decision explicita del usuario). Implicarian
  maquinaria nueva inexistente en el harness.

## Preguntas abiertas

- Ninguna para este issue.

## Referencias

Issues creados: ninguno (refinamiento de #605 existente).
Issues refinados: #605 (borrador -> listo).
