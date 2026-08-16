---
fecha: 2026-08-13
hora: 08:26
sesion: mefisto-planner
tema: refinamiento del draft #621 (doctrina HTTP de comandos) y desglose en paquete de 4 issues
---

## Contexto

Refinar el draft #621, creado desde el consumidor Bitakora.ControlAsistencia tras una
investigacion con fuentes primarias (RFC 9110, Fielding, Zalando, Google AIP-136,
Microsoft Azure REST Guidelines, Greg Young, Oskar Dudycz) y una sesion de knowledge
crunching que destilo un test de precedencia para verbos y rutas HTTP de comandos en
sistemas event-sourced. El drift observado en el consumidor: casing mixto entre dominios,
estilos de comando conviviendo sin criterio, justificaciones por precedente interno.

## Descubrimientos

- **Colision doctrinal vigente no mencionada en el draft**: el ejemplo canonico de
  MEF-ADR-0006 es `Route = "Programacion/Turnos"` (PascalCase), incompatible con el
  kebab-case minusculo de la doctrina destilada. El ejemplo esta replicado en
  `agents/implementer.md` (~333) y `skills/projections/naming.md` (36/44/66/68).
- **La validacion programatica del DoR vive dentro del propio MEF-ADR-0011** (seccion
  "Validacion en /implement"): enmendar el ADR autopropaga el criterio nuevo al gate de
  `/implement` sin tocar `commands/implement.md`.
- **Consecuencia en el borde APIM**: MEF-ADR-0032 fija `<allowed-methods>` por enumeracion
  explicita (B3) y operaciones wildcard por verbo (B11). Si un BC adopta PUT/DELETE o
  rutas `:verbo`, el gateway debe cubrirlos o responde 404. Quedo anotado en #621 como
  consecuencia a documentar en el ADR nuevo; enmienda formal a MEF-ADR-0032 diferida.
- El planner ya tiene el molde de estilo para proponer contratos: el bloque "Sugerir el
  verbo, el filtro y la paginacion (MEF-ADR-0042)" — el lado comando sera su simetrico.

## Decisiones

1. **Desglose en 4 issues** (el draft pedia ADR + planner + reviewer + enmiendas en uno
   solo; supera ampliamente el limite de complejidad): #621 techo doctrinal (MEF-ADR-0043
   nuevo + enmiendas a 0006 y 0011), #622 generadores (implementer + naming.md), #623
   planner (contrato HTTP en el handoff), #624 reviewer (checklist). #622/#623/#624
   dependen de #621 y llevan `bloqueado`.
2. **El contrato HTTP entra al Definition of Ready** (enmienda a MEF-ADR-0011): issue con
   comando de trigger HTTP no llega a `estado:listo` sin verbo + ruta + precedencia
   aplicada. Racional del usuario: el planner es quien discute los issues; decidir la
   interfaz en el diseno aligera a los agentes TDD y bloquea estructuralmente el drift.
3. **Aplicabilidad de la doctrina: solo endpoints nuevos.** Los preexistentes no conformes
   nunca son hallazgo bloqueante; renames de viejos se sugieren con precaucion (pueden
   tener consumidores asociados a la URL vieja) y se discuten con el humano, jamas se
   fuerzan. La migracion es decision y calendario de cada consumidor.
4. Numeracion: el ADR nuevo sera MEF-ADR-0043 (el ultimo existente es 0042).

## Descartado

- **Doctrina retroactiva con migracion exigida por el reviewer**: descartada por riesgo de
  breaking change sobre clientes que el harness no conoce.
- **Fusionar los ejemplos de generadores (#622) dentro del issue doctrinal (#621)**: se
  mantuvo la separacion techo-doctrinal vs propagacion para conservar issues de un solo
  proposito.
- **Enmienda formal inmediata a MEF-ADR-0032 / apim-gateway-scaffolder**: diferida a issue
  propio si al escribir la seccion de consecuencias del ADR nuevo se revela trabajo real.

## Preguntas abiertas

- **NO VERIFICADO** (registrado como CA-3 de #621): soporte del literal `:` pegado a un
  parametro en route templates del worker aislado de Azure Functions (`{codigo}:terminar`
  es un complex segment de ASP.NET). Verificacion empirica en el primer endpoint que lo
  use, misma disciplina que los NO VERIFICADO de `skills/projections/naming.md`.
- Si el gate programatico del contrato HTTP en `/implement` necesitara un grep dedicado
  (mas alla del texto de la seccion "Validacion en /implement"), se descubrira al
  implementar #621/#623.

## Referencias

Issues creados/refinados:
- #621 — Escribir MEF-ADR-0043 (doctrina HTTP de comandos) y enmendar MEF-ADR-0006 y
  MEF-ADR-0011 (refinado de draft a `estado:listo`)
- #622 — Propagar la doctrina HTTP de comandos a los generadores (implementer y naming.md
  del Skill projections) (`estado:listo` + `bloqueado`)
- #623 — Extender el planner para proponer el contrato HTTP de comandos en el handoff
  (`estado:listo` + `bloqueado`)
- #624 — Dotar al reviewer del checklist verificable de endpoints HTTP de comando
  (`estado:listo` + `bloqueado`)

Orden de batch sugerido: #621 -> #622 -> #623 -> #624.
