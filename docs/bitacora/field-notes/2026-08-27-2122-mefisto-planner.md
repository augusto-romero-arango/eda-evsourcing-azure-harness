---
fecha: 2026-08-27
hora: 21:22
sesion: mefisto-planner
tema: Refinamiento del draft de enriquecimiento coreografiado por el dueno del dato (#747)
---

## Contexto
Draft cross-repo #747 (consumidor Bitakora.ControlAsistencia, gran planning de sedes): cuando un dominio necesita un dato cuya verdad pertenece a otro dominio y no hay front que lo resuelva (marcacion de biometrico enriquecida con sede/CC del dispositivo), el planner deberia proponer el enriquecimiento coreografiado por el dueno (Content Enricher, Hohpe & Woolf) como opcion preferida sobre la replica local (Event-Carried State Transfer, Fowler 2017).

## Descubrimientos
- El draft encaja en un patron ya establecido de `agents/planner.md`: la familia de secciones "Reconocer la senal" (proyecciones ~527, identidad del evento persistido ~633) que detectan la situacion, proponen la receta en estilo generativo (MEF-ADR-0008) y citan el ADR sin duplicarlo.
- La mecanica de soporte ya existe completa en ADRs vigentes: eventos privados por bus interno (MEF-ADR-0024), ensamblado `PrivateEvents` (MEF-ADR-0039), reaccion `{Accion}Cuando{Evento}` (MEF-ADR-0006), resolucion contra read model propio (MEF-ADR-0034/0035), fallo como evento (MEF-ADR-0004), transporte (MEF-ADR-0026/0027). El ADR nuevo compone, no inventa.
- Numeracion: el siguiente ADR del marco es MEF-ADR-0046.

## Decisiones
- **Alcance doctrina + mecanica** (eleccion del usuario, sobre la alternativa doctrina-de-decision sola): el ADR fija ademas la forma canonica del flujo en cuatro pasos y el perfil de fallo.
- **Desglose en dos issues por capa**: #747 reconvertido en el ADR (MEF-ADR-0046, doctrina + mecanica anclada en ADRs previos, estilo MEF-ADR-0042/0043) y #748 nuevo para la seccion "Reconocer la senal" del planner, dependiente de #747 con label `bloqueado`.
- La guidance del planner ensena a partir el trabajo en dos issues (dueno resuelve/publica, consumidor estampa) con `dom:` correctos — el mismo corte que el consumidor hizo a mano (#467/#463 de Bitakora).
- La replica local queda como ultimo recurso con costo de sincronizacion declarado en el issue que la elija (reconciliacion, backfill, tombstones, drift — Kleppmann DDIA cap. 5).

## Descartado
- Issue unico para ADR + guidance: con el alcance doctrina + mecanica no pasa la revision de complejidad.
- Duplicar la mecanica de transporte en el ADR nuevo: remite a MEF-ADR-0026/0027.

## Preguntas abiertas
- Batch sugerido sin ejecutar: `/mefisto-sequential 747 748`, combinable con lo pendiente de la sesion anterior (`725 743 747 748`).

## Referencias
Issues creados: #748 (Ensenar al planner a reconocer la senal de dato ajeno entre dominios)
Issues refinados: #747 (draft -> Crear MEF-ADR-0046: enriquecimiento coreografiado por el dueno del dato, `estado:listo`)
Relacionados: issues #467/#463 del consumidor Bitakora.ControlAsistencia
