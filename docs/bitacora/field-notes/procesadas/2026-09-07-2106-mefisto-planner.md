---
fecha: 2026-09-07
hora: 21:06
sesion: mefisto-planner
tema: Revalidacion del refinamiento del contrato comun de eventos
---

## Contexto

Se solicito refinar el issue #1044. El issue ya estaba marcado como
`estado:listo`, por lo que se revalido su causa raiz, alcance, dependencias y
Definition of Ready contra el estado actual de `main`.

## Descubrimientos

- `run-events.schema.json` y los nueve fixtures canonicos de eventos siguen
  viviendo bajo `src/internal/contract/`; `src/runtime/` aun no existe.
- Los tests del runner, Claude, OpenCode y hold consumen la ubicacion interna;
  MEF-ADR-0051 tambien conserva una referencia activa que debe migrarse.
- #1042 y #1043 permanecen abiertos. #1044 conserva correctamente el label
  `bloqueado` por su dependencia directa de #1043, que a su vez depende de
  #1042.
- No existe un PR abierto ni mergeado que implemente #1044.

## Decisiones

- Mantener #1044 en `estado:listo`: el body ya cumple el template del harness y
  sus labels `tipo:tooling`, `estado:listo` y `bloqueado` son correctos.
- Mantener los seis criterios de aceptacion como un issue homogeneo: todos
  verifican la reubicacion sin cambio semantico de un unico contrato de runtime.
- No editar el issue solo para producir una mutacion nominal; la revalidacion no
  encontro ambiguedades ni informacion faltante.

## Descartado

- Partir schema, fixtures y documentacion en issues separados: perderian la
  atomicidad de la unica fuente canonica del protocolo.
- Incluir el movimiento del runner o de los adaptadores: pertenece a #1045.
- Introducir un validador nuevo o cambiar el protocolo `v: 1`.

## Preguntas abiertas

- Ninguna para #1044. Debe esperar el cierre de #1042 y #1043 antes de entrar en
  implementacion.

## Referencias

Issues creados: ninguno.

Issue refinado: #1044 — Extraer el contrato de eventos al nucleo comun de runtime.
