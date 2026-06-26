---
fecha: 2026-06-25
hora: 10:45
sesion: mefisto-planner
tema: Actualizar versiones de GitHub Actions emitidas por el scaffold
---

## Contexto

El usuario reporto que el scaffold de un nuevo dominio genera workflows de
GitHub Actions con versiones desactualizadas. Se pidio investigar el codigo del
harness, identificar cada `uses: <action>@<version>` y crear el issue.

## Descubrimientos

- El unico punto del harness que **emite** GitHub Actions es el Paso 5 de
  `agents/domain-scaffolder.md` (bloque YAML de `deploy-{kebab}.yml`,
  lineas ~1345-1434). No existe `.github/workflows/` en el repo de Mefisto
  porque es un harness, no se despliega.
- El workflow reutilizable `smoke-tests-dominio.yml` se **referencia**
  (linea 1427) pero el harness no lo genera; se asume en el consumidor.
  `scripts/tdd-pipeline.sh:141` solo lo menciona en un comentario (lo excluye
  de los gates del pipeline TDD). Fuera de alcance.
- Estado verificado contra la API de GitHub el 2026-06-25:
  - `actions/checkout`: harness `@v4`, mayor vigente `v7` (atrasado).
  - `actions/setup-dotnet`: harness `@v4`, mayor vigente `v5` (atrasado).
  - `azure/login`: harness `@v2`, mayor vigente `v3` (atrasado).
  - `Azure/functions-action`: harness `@v1`, mayor vigente `v1` (al dia).
- Breaking changes de los bumps mayores son solo subidas de runtime de Node
  en el runner (setup-dotnet v5 -> Node 24; login v3 -> Node 24). Bajo
  `ubuntu-latest` hosteado, el runner siempre esta al dia: seguros. Ningun
  input usado por el template cambia.

## Decisiones

- Issue creado en **estado:listo** (DoR de tooling, ADR-0011): un solo
  componente (`agents/domain-scaffolder.md`), CAs verificables, < 30 min,
  sin ambiguedad de ubicacion ni de version objetivo.
- Convencion fijada en el issue: mantener **tag mayor flotante** (`@vN`), no
  pin por SHA. Es coherente con lo que el harness ya emite; el pin por SHA es
  hardening del consumidor, fuera de alcance.

## Descartado

- No se trato como decision abierta el dilema tag-flotante vs SHA: la evidencia
  (el harness ya usa tags flotantes) y la guia de GitHub para actions de
  primera parte lo resuelven sin necesidad de consultar. Se documento como
  decision tomada, no como pregunta.

## Preguntas abiertas

- Ninguna bloqueante. CA-4 (comentario aclaratorio sobre `functions-action@v1`)
  queda marcado como opcional para que el implementador decida.

## Referencias

Issues creados: #90 - "Actualizar las versiones de los GitHub Actions que emite
el scaffold de dominio"
