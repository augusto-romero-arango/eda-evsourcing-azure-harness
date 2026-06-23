---
fecha: 2026-06-18
hora: 19:31
sesion: mefisto-planner
tema: Analisis a profundidad del #43 (un Service Plan por Function App) y desglose
---

## Contexto

El usuario pidio revisar el draft #43 a profundidad: directiva "un App Service Plan por
Function App (dominio)", no compartido. Origen: noisy-neighbor en `Bitakora.ControlAsistencia`
(dos Function Apps en un B1, CPU saturada en reposo por agentes de durabilidad Wolverine
`DurabilityMode.Solo`). Objetivo: ver todas las consecuencias dentro de Mefisto.

## Descubrimientos

- Mefisto NO tiene carpeta `infra/`: las plantillas Terraform viven embebidas como heredocs
  en `agents/domain-scaffolder.md`. Los modulos (`service-plan`, `function-app`, `storage`)
  viven en el consumidor y se referencian con `source = "../../modules/..."`.
- El punto donde se comparte el plan hoy: `domain-scaffolder.md:1281`
  (`service_plan_id = module.service_plan.id`, plan unico para todos los dominios).
- No existe ADR de hosting en el harness (llegan hasta ADR-0019). `domain-scaffolder` y
  `bug-investigator` apuntan a "el ADR de hosting del consumidor".
- `infra-writer.md:71` nombra `asp-<proyecto>-<env>` (un plan sin dominio).
- Gap pre-existente: el indice de ADRs en `CLAUDE.md` omite ADR-0019 y `README.md` dice
  "18 ADRs" (hay 19). A corregir de paso en #44.

## Decisiones

- Aclaracion terminologica: "cada funcion" = **una Function App (dominio)**, no cada
  `[Function(...)]`. En Azure el plan se asigna a la Function App. Confirmado por el usuario.
- Correccion del modelo mental (usuario): la palanca es la **plantilla que emite el
  scaffolder**, no "codigo externo intocable". El scaffolder debe emitir un `module
  service_plan` por dominio y pedir/aceptar parametros de hosting al aprovisionar.
- ADR-0020 **canonico en el harness** (no solo en el consumidor).
- Defaults: SKU B1, worker_count=1, Always On OFF en dev / evaluar ON en prod.
- Desglose **compactado** (3 issues), validado por el usuario.

## Desglose creado

- **#44** (estado:listo) - Crear ADR-0020 de hosting + indices (CLAUDE.md, README). Sin deps;
  bloquea #43 y #45.
- **#43** (estado:listo, bloqueado) - reconvertido de draft a issue B: scaffolder emite un
  Service Plan dedicado por Function App + pide parametros de hosting; incluye naming de
  infra-writer, checklist de infra-reviewer y resumen de /scaffold. Depende de #44.
- **#45** (estado:listo, bloqueado) - bug-investigator: detectar noisy-neighbor y verificar
  aislamiento por plan. Depende de #44.

## Descartado

- Service Plan por `[Function]` individual: imposible/sin sentido en Azure.
- Tratar el modulo `modules/service-plan` del consumidor como bloqueante intratable: se
  documenta su contrato de inputs en el ADR y el scaffolder avisa si es incompatible.
- Migrar el dev existente de Bitakora: fuera de alcance por decision del issue.

## Preguntas abiertas

- ¿Se crea un issue aparte para corregir el desfase de indices de ADR (0019) y conteo en
  README, o se resuelve dentro de #44 (CA-6)? Por ahora dentro de #44.

## Referencias

Issues creados/reconvertidos: #44 (ADR), #43 (scaffolder), #45 (bug-investigator).
Oleadas sugeridas: #44 primero; luego #43 y #45 en paralelo (archivos sin solape).
