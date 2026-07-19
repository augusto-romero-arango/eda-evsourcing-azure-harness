# MEF-ADR-0010: Pipeline de conocimiento del dominio

**Estado**: Aceptado
**Fecha**: 2026-04-04
**Autores**: augusto-romero-arango

---

## Contexto

El proyecto necesita un flujo estructurado para convertir el conocimiento descubierto en sesiones de dominio en issues ejecutables por el pipeline TDD.

Sin este flujo, el conocimiento queda disperso en field notes narrativas (formato libre, dificil de consumir por agentes), y el planner no tiene informacion estructurada sobre actores, invariantes de aggregates, ni el mapa de relaciones entre dominios. El resultado: sesiones de dominio valiosas que no se traducen en issues precisos.

Adicionalmente, el agente `event-stormer` (antes llamado `proyecto`) no tenia capacidad de investigar fuentes externas, lo que llevaba a tomar decisiones con informacion superficial cuando el tema requeria consulta de legislacion colombiana, patrones DDD, o frameworks tecnicos.

## Decision

Crear un **knowledge hub** en `docs/eda/` con artefactos YAML estructurados y un pipeline de tres fases para gestionarlos.

### Pipeline de tres fases

```
Fase 1 - Descubrimiento (agente event-stormer)
  Sesion conversacional con WebSearch/WebFetch para investigacion cuando se necesite
  Output obligatorio:
    - field notes en docs/bitacora/field-notes/
    - actualizacion de docs/eda/ubiquitous-language.yaml
    - actualizacion de docs/eda/aggregates/ (si se descubren invariantes)
    - actualizacion de docs/eda/context-map.yaml (si cambia el mapa)

Fase 2 - Modelado (agente eda-modeler, opcional)
  Para flujos cross-domain o casos de uso complejos
  Output:
    - docs/eda/flows/*.yaml
    - actualizacion de docs/eda/catalog.yaml
    - actualizacion de docs/eda/messaging/topics.yaml

Fase 3 - Planificacion (agente planner)
  Lee todos los artefactos de docs/eda/ antes de crear issues
  Output:
    - Issues de GitHub con "Modelo de eventos" usando vocabulario del catalogo
    - actualizacion de docs/eda/catalog.yaml con eventos/comandos nuevos
```

### Artefactos del knowledge hub

| Artefacto | Ubicacion | Que documenta | Quien actualiza |
|---|---|---|---|
| Glosario de lenguaje ubicuo | `docs/eda/ubiquitous-language.yaml` | Terminos, actores/roles, sistemas externos, preguntas abiertas | agente `event-stormer` |
| Catalogo EDA | `docs/eda/catalog.yaml` | Eventos, comandos, policies, value objects | agente `eda-modeler`, `planner` |
| Mapa de contextos | `docs/eda/context-map.yaml` | Bounded contexts y relaciones entre ellos | agente `event-stormer`, `eda-modeler` |
| Aggregate Design Canvas | `docs/eda/aggregates/*.yaml` | Estado, invariantes, comandos y eventos por aggregate | agente `event-stormer`, `eda-modeler` |
| Flujos EDA | `docs/eda/flows/*.yaml` | Flujos end-to-end (Event Storming Process Modeling) | agente `eda-modeler` |
| Topologia Service Bus | `docs/eda/messaging/topics.yaml` | Topics y subscriptions de Azure Service Bus | agente `eda-modeler` |
| Projections | `docs/eda/projections/` | Read models (cuando existan) | agente `eda-modeler` |

### Formato YAML

Los artefactos usan YAML en lugar de Markdown porque:
- Son consumibles programaticamente por los agentes sin parsear texto libre
- El linter `scripts/eda-lint.sh` puede validarlos automaticamente
- Git diff sobre YAML es mas limpio que sobre tablas Markdown

### Roles de investigacion

- **agente `event-stormer`**: puede investigar fuentes externas (WebSearch, WebFetch) cuando el tema lo requiera. Ejemplo: legislacion laboral colombiana, patrones DDD, documentacion de Marten/Wolverine.
- **agente `planner`**: NO investiga. Consume los artefactos ya producidos y cristaliza en issues.
- **agente `eda-modeler`**: NO investiga. Modela flujos a partir de lo ya descubierto.

## Alternativas consideradas

### Todo en field notes (Markdown narrativo)
Descartado: las field notes son excelentes para la bitacora (el historiador las consume bien) pero no son consumibles por el planner sin leer prosa libre y extraer informacion manualmente.

### Artefactos en Markdown estructurado
Descartado: Markdown es menos parseable que YAML. Las tablas en Markdown son fragiles y dificiles de actualizar incrementalmente.

### Un solo artefacto monolitico
Descartado: un solo archivo grande se vuelve inmanejable. Separar por tipo (glosario, catalogo, aggregates, flows) permite que cada agente actualice solo su parte sin conflictos.

### Herramientas externas (Miro, Notion, Confluence)
Descartado: rompen el flujo del proyecto (requieren salir de la terminal), no son versionables con git, y no pueden ser leidas directamente por los agentes.

### Event Storming formal con post-its
Descartado: requiere un equipo multidisciplinario para sacarle valor. Para un solo desarrollador, el `eda-modeler` provee los mismos beneficios del Process Modeling level de Event Storming en formato YAML.

## Consecuencias

**Positivas**:
- El planner puede crear issues mas precisos usando vocabulario establecido e invariantes documentadas
- Las decisiones de diseno (terminos descartados, relaciones entre contextos) no se pierden en field notes
- Los agentes de TDD (test-writer, implementer) tienen mas contexto para escribir tests y codigo correctos
- WebSearch en el agente `event-stormer` permite investigar legislacion colombiana con fuentes reales

**Negativas / Riesgos**:
- Los artefactos pueden quedar desactualizados si el agente `event-stormer` no los actualiza diligentemente
- El catalogo puede divergir del codigo real si no se valida con el linter periodicamente
- Overhead inicial: los artefactos semilla requieren ser creados y mantenerlos requiere disciplina

**Mitigaciones**:
- La actualizacion del glosario es **obligatoria** en la Fase 3.5 del agente `event-stormer` (como las field notes)
- El linter `scripts/eda-lint.sh` detecta divergencias entre el catalogo y los flows
- Si un artefacto no se usa en 4 semanas, evaluar si eliminarlo

## Referencias

- ADR del proyecto consumidor sobre Function App por dominio (define los bounded contexts base)
- ADR del proyecto consumidor sobre Contracts compartidos (el shared kernel)
- MEF-ADR-0001: Topics de Service Bus por evento
- MEF-ADR-0005: Naming y versionado de eventos
- MEF-ADR-0003: Event Sourcing con Marten y Wolverine
- MEF-ADR-0008: Knowledge Crunching como proposito del planner
- ddd-crew/aggregate-design-canvas: https://github.com/ddd-crew/aggregate-design-canvas
- ddd-crew/eventstorming-glossary-cheat-sheet: https://github.com/ddd-crew/eventstorming-glossary-cheat-sheet
- Oskar Dudycz - Projections and Read Models: https://event-driven.io/en/projections_and_read_models_in_event_driven_architecture/
