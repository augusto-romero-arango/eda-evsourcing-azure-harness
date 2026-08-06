# Migración de la capa EDA: qué hacer con tu `docs/eda/` existente

Esto es lo que le contarías a un compañero cuyo repo consumidor ya tenía `docs/eda/` poblado (catálogo, flujos, glosario, mapa de contextos…) antes de actualizar a la versión de Mefisto que retiró la capa de modelado EDA. No repite la doctrina — cada decisión enlaza a su ADR: **[MEF-ADR-0040](adr/mef-adr-0040-fuentes-conocimiento-dominio-sin-eda.md)** es la autoridad completa, esta guía solo la operacionaliza para tu repo. Si tu `docs/eda/` está vacío o no existe, no necesitas esta guía: no hay nada que migrar.

## Qué cambió y por qué no rompe nada

Tras el `/upgrade` que trae MEF-ADR-0040, tu `docs/eda/` queda exactamente como estaba: nadie lo borra, nadie lo actualiza, ningún agente lo vuelve a leer salvo el glosario (ver más abajo). Es "documentación muerta, no se borra" — decisión explícita del ADR, no un olvido (MEF-ADR-0040, decisión 5). **Nada del pipeline de entrega** (`/implement`, `/tooling`, `/infra`, el ciclo TDD, IaC) depende de ningún archivo bajo `docs/eda/`: esos pipelines siempre leyeron las fuentes de verdad ejecutables (código, Terraform, ADRs), nunca los YAMLs derivados que mantenía la capa de modelado.

Del harness en sí desaparecen, con ese mismo `/upgrade`:

- El agente `eda-modeler`
- El agente `event-stormer`
- El skill `/show-flow`
- El script `scripts/eda-lint.sh`

Que buscarlos después del `/upgrade` no encuentre nada en el plugin es lo esperado, no un error de instalación. Ninguno de los cuatro tiene reemplazo directo, y no lo necesita: ningún skill del pipeline de entrega (`/scaffold`, `/draft`, `/implement`, `/tooling`, `/infra`, `/infra-base`, `/parallel`, `/sequential`) los invoca ni depende de ellos. El `planner` ya cubría el knowledge crunching por issue (MEF-ADR-0008), y el conocimiento del dominio se sostiene ahora en las cuatro fuentes vigentes (MEF-ADR-0040, decisión 2): código por rol, glosario custodiado por el planner, field notes/bitácora y tus propios ADRs. Las tres últimas no necesitan un agente dedicado — se producen como efecto colateral del trabajo normal (escribir código, investigar un bug, documentar un ADR), no como un artefacto que alguien tiene que recordar sincronizar.

## El único paso con efecto activo: mover el glosario

Si tu `docs/eda/ubiquitous-language.yaml` tiene contenido real (términos, actores, preguntas abiertas), este es el único movimiento que vale la pena hacer pronto:

```bash
mkdir -p docs/ddd   # git mv aborta si el directorio destino todavia no existe
git mv docs/eda/ubiquitous-language.yaml docs/ddd/ubiquitous-language.yaml
```

**No es urgente.** El `planner` intenta primero la ruta nueva (`docs/ddd/ubiquitous-language.yaml`) y, si no la encuentra, hace *fallback* de lectura a la ruta vieja (`docs/eda/ubiquitous-language.yaml`) — el comportamiento documentado en el body del agente dentro del plugin (`agents/planner.md`, sección "Tu stack de conocimiento"). Mientras no ejecutes el `git mv`, el glosario sigue funcionando: el planner lo lee, lo usa como guardrail anti-sinónimos y, al detectar que entró por la ruta vieja, te sugiere ese mismo `git mv`.

Lo que sí importa mientras no lo muevas: **el glosario que se actualiza sigue siendo el de `docs/eda/`**, no uno nuevo en `docs/ddd/`. El planner nunca escribe una copia nueva en la ruta canónica mientras la vieja siga existiendo — hacerlo reintroduciría el riesgo de divergencia entre dos copias del mismo glosario que MEF-ADR-0040 elimina (decisión 4). Es la única operación que esta guía marca como **incorrecta**: mantener manualmente dos copias del glosario, una en cada ruta. Todo lo demás en esta guía es opcional.

## Limpieza opcional de los demás artefactos

El resto de `docs/eda/` (`catalog.yaml`, `flows/`, `messaging/topics.yaml`, `projections/`, `context-map.yaml`, `aggregates/`) no tiene ningún consumidor activo — puedes dejarlo donde está indefinidamente, o borrarlo cuando te sirva limpiar el historial documental. La decisión es enteramente tuya como consumidor (MEF-ADR-0040, Alternativa 2: el marco no prescribe ni ejecuta ninguna limpieza sobre tu repo). Si decides limpiar, esta tabla te dice dónde consultar hoy la misma información — detalle completo en MEF-ADR-0040, decisión 1:

| Artefacto en `docs/eda/` | Dónde vive esa información ahora |
|---|---|
| `catalog.yaml` (eventos, comandos, payloads) | El **código por rol** (MEF-ADR-0039): `src/<RootNamespace>.PublicEvents/{Dominio}/`, `*.PrivateEvents/{Dominio}/`, `*.{Dominio}.DomainEvents/` |
| `messaging/topics.yaml` (topología Service Bus) | **Terraform** (`dominio-{kebab}.tf`) + atributos `[ServiceBusTrigger]` en el código |
| `flows/*.yaml` (flujos end-to-end) | Semi-legible directamente del código: convención de naming `{Accion}Cuando{Evento}` (MEF-ADR-0006) + topics por evento |
| `projections/` (read models) | El worker de proyecciones (`<RootNamespace>.Projections`) + `<RootNamespace>.ReadModels` (MEF-ADR-0034) |
| `aggregates/*.yaml` (estado, invariantes) | El propio `AggregateRoot`: su factory `Crear`, sus invariantes y los eventos que consume vía `Apply` |
| `context-map.yaml` (mapa de contextos) | **Ninguna — pérdida aceptada.** No hay artefacto que lo reemplace; esa información pasa a vivir en tus propios ADRs y en tu bitácora cuando la consideres relevante. No es algo que "migrar", es algo que dejas de tener centralizado. |

`ubiquitous-language.yaml` no aparece en esta tabla porque no se limpia — se mueve (ver sección anterior).

## Limpiar referencias propias, si las tienes

Si tu `CLAUDE.md` o tus ADRs de consumidor (`docs/adr-proyecto/` o equivalente) mencionan `docs/eda/`, `/show-flow`, `eda-modeler` o `event-stormer` — por ejemplo, en instrucciones de onboarding o en un ADR que documentó cómo tu equipo adoptó el pipeline de conocimiento original (MEF-ADR-0010) — actualízalas para que reflejen el estado vigente. Esto es limpieza de tu propia documentación, no algo que Mefisto pueda hacer por ti: el marco solo controla sus propios archivos.
