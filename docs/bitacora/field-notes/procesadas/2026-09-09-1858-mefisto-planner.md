---
fecha: 2026-09-09
hora: 18:58
sesion: mefisto-planner
tema: Refinamiento del gate consumidor multi-runtime de tooling
---

## Contexto

Se retomó el draft #1066 después de cerrar su cadena funcional para decidir cómo certificar el corte publicado `/mefisto:tooling` bajo Claude Code y OpenCode. La última release disponible, v0.37.0, precede esa implementación y no existe todavía un consumidor seguro para la prueba real.

## Descubrimientos

- Las suites actuales cubren generación, empaquetado, instalación y proyección con fixtures, pero no una instalación versionada real desde un consumidor ajeno al checkout.
- El pipeline tooling ejercita `tooling-writer` y `tooling-reviewer`; Agent Skills y MCP deben comprobarse por discovery porque esos agentes los niegan deliberadamente.
- El dogfooding OpenCode existente certifica el paquete interno de Mefisto y declara explícitamente que no certifica el corte publicado para consumidores.
- La evidencia completa combina instalación e identidad, discovery, dos PRs reales, sesiones/hooks, observabilidad y separación de pools Herdr. Todo eso excede un único issue menor a treinta minutos.

## Decisiones

- Usar `augusto-romero-arango/mefisto-consumer-certification` como repositorio privado, persistente y reutilizable; aún debe crearse y onboardearse.
- Publicar primero un patch posterior a v0.37.0 y registrar el tag, checksum y commit fuente efectivos en vez de inferir `latest`.
- Separar el trabajo en #1179 para el protocolo, #1180 para instalación/discovery y #1181 para las corridas E2E/Herdr.
- Mantener #1066 como veredicto final fail-closed y frontera explícita de soporte, dependiente de las tres evidencias.
- Crear dos issues/ramas/PRs independientes en el consumidor, uno por runtime, con cambios documentales deterministas; cerrarlos sin merge al terminar para conservar el baseline.
- Mantener `estado:listo` solo en #1179. #1180, #1181 y #1066 permanecen `estado:borrador`/`bloqueado` hasta materializar sus prerrequisitos.

## Descartado

- Ejecutar la certificación sobre Bitakora.ControlAsistencia u otro producto real.
- Certificar ambos runtimes con una variante local que no abra PR.
- Forzar Skills o MCP dentro de los agentes tooling para aparentar cobertura.
- Mantener #1066 como una tarea monolítica de preparación, ejecución, corrección y veredicto.
- Declarar soporte desde v0.37.0 o desde artefactos del checkout.

## Preguntas abiertas

- Tag exacto de la primera release certificable, previsto como patch posterior a v0.37.0.
- URL y SHA baseline del consumidor una vez creado/onboardeado.
- Números de los dos issues y PRs fixture, que se crearán desde el propio consumidor al ejecutar #1181.

## Referencias

Issues creados: #1179, #1180, #1181

Draft refinado y desglosado: #1066
