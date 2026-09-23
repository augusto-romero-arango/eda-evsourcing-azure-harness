---
fecha: 2026-09-09
hora: 21:34
sesion: mefisto-planner
tema: Preparacion de la validacion final del corte tooling multi-runtime
---

## Contexto

Se reviso que hacer con #1066 despues de integrar la cadena funcional del corte
publicado `/mefisto:tooling`. El objetivo era determinar si ya podia emitirse el
veredicto o si primero habia que crear el consumidor de certificacion y ejecutar
la evidencia real exigida por MEF-ADR-0053.

## Descubrimientos

- #1180 y #1181 estaban cerrados por los `Closes` de sus PRs documentales, aunque
  la evidencia versionada y los summaries de esos PRs dicen que las corridas no
  comenzaron y debian repetirse.
- La ultima release observable sigue siendo `v0.37.0` y la identidad efectiva
  recibe HTTP 404 al consultar `mefisto-consumer-certification`.
- El preflight local dejo verdes guards, adaptadores base, empaquetado, instalador,
  proyector, diagnostico de identidad, hooks y Herdr, pero encontro nueve fallos:
  cinco en snapshots/salidas OpenCode de agentes tooling, uno en la salida del
  plugin de observabilidad y tres en una regresion de `harness_version` anterior
  al objeto neutral `identity` de tooling.
- `/mefisto-next-order` interpretaba la negacion `no depende de #1066` de #1074
  como una dependencia real. La seccion `## Dependencias` no debe contener esa
  forma negativa con un numero de issue.

## Decisiones

- Reabrir #1180 y #1181. #1181 y #1066 quedan con label `bloqueado`; #1066
  conserva `estado:borrador` hasta que exista evidencia real.
- Crear #1197 y #1198 como bugs pequenos e independientes y declararlos
  dependencias de #1180. No se publica la release candidata con esos gates rojos.
- Mantener para `mefisto-consumer-certification` el perfil de consumidor completo
  minimo: repositorio privado, un BC y dominio `certificacion`, estrategia
  `mono-tenant-transitorio`, proyecciones deshabilitadas, sin autenticacion ni ASB
  externos, y recursos aislados en la suscripcion de desarrollo actual.
- Preparar el esqueleto del consumidor en paralelo a #1197/#1198. La instalacion
  final, el `/mefisto:onboard` definitivo y el SHA baseline se fijan despues de
  publicar la candidata posterior a `v0.37.0`.
- Gestionar la creacion, onboarding, infraestructura e issues fixture desde el
  propio repositorio consumidor con el planner publicado; el planner interno no
  opera cross-repo.

## Descartado

- Ejecutar #1066 solo porque el codigo funcional ya esta integrado: MEF-ADR-0053
  exige una release instalada y corridas reales, no presencia de archivos.
- Cerrar #1180/#1181 como tareas documentales completadas: sus criterios de
  aceptacion son operacionales y todavia no se cumplieron.
- Restaurar en tooling el campo plano historico `harness_version` para satisfacer
  un test obsoleto: perderia el commit fuente y el estado de identidad neutral.
- Crear o administrar el consumidor desde el repo de Mefisto.

## Preguntas abiertas

- Elegir durante el onboarding del consumidor la region efectiva de PostgreSQL
  soportada por la suscripcion y los valores finales de naming sin persistir IDs
  sensibles en la evidencia.
- Decidir si #1074 entra en la release candidata o queda fuera de la ruta critica;
  el issue es independiente del gate y no corrige ninguno de los fallos del
  preflight.

## Referencias

Issues creados: #1197, #1198.

Issues reabiertos: #1180, #1181.

Issue final: #1066.
