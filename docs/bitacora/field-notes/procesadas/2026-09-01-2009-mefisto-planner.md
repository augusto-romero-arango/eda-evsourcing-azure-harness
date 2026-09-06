---
fecha: 2026-09-01
hora: 20:09
sesion: mefisto-planner
tema: incidente ProxyTenantResolver (refinamiento y desglose), excepciones de precondicion tipadas, doctrina MCP absorbida del pionero, refinamientos 799/800 y limpieza
---

## Contexto

Sesion larga de planeacion en tres arcos: (1) refinar el draft #802 del incidente de tenancy
etapa (b) en el consumidor Bitakora.ControlAsistencia (ProxyTenantResolver roto en el worker
aislado); (2) refinar su hallazgo secundario (#805, el 409 que enmascara fallas de
infraestructura); (3) revisar el backlog, refinar los drafts faciles (#799, #800) y decidir el
destino de #797 (tenancy MCP) tras revisar lo desarrollado por el pionero.

## Descubrimientos

- **La prescripcion de `AgregarTenantResolverHibrido()` estaba en 4 componentes** (MEF-ADR-0028,
  `/install-apim`, `/install-auth`, `domain-scaffolder`): el patron esta probado roto en el worker
  aislado (la rama HTTP/Wolverine se decide en el constructor de `ProxyTenantResolver` con
  `HttpContext` null; catch-22 de `TenancyDelivery.Build`). El reemplazo es el patron AsyncLocal +
  `IFunctionsWorkerMiddleware` de Cosmos.ControlPlane.
- **El 404 tambien estaba enredado en el catch del 409**: `TurnoNoEncontrado` lanza la misma
  `InvalidOperationException` que `TurnoYaExiste`, asi que el borde respondia 409 a ambos.
- **El gate MEF-ADR-0029 no atrapa fallos de runtime por timing de scope**: el contenedor
  construye bien con `HttpContext` null; documentado en la enmienda, sin relajar el gate.
- **El pionero ya valido la doctrina MCP completa** (sus #539/#554/#558/#560/#561 mergeados):
  propagador de identidad por DelegatingHandler, gate OAuth en el borde APIM (limite estructural:
  las tool calls llegan al worker sin `Authorization`), politica por-API sin `<base/>`, y la
  trampa del dominio AuthKit (authorization server e issuer de tokens Connect = dominio AuthKit
  del entorno, nunca el issuer de login `user_management/{client_id}`).
- **La poda de panes Herdr ya existia** (`acquire_report_pane` en `herdr-pipeline.sh`): #799 solo
  la expone como modo invocable desde `/merge`, sin correlacion por labels.
- `caffeinate -i <comando>` muere con el comando envuelto: sin huerfanos por construccion (#800).

## Decisiones

- **Scaffoldear, no empaquetar**: tanto la biblioteca TenantResolver (etapa b) como las
  excepciones de precondicion viven como codigo scaffoldeado en el consumidor; el NuGet queda
  como opcion futura.
- **Excepciones de precondicion tipadas**: base `PrecondicionComandoException` + derivadas
  `RecursoYaExisteException` (409) y `RecursoNoEncontradoException` (404); el endpoint captura la
  base y toda otra excepcion sube como 500. Se conserva "No se adopta Result Pattern"
  (MEF-ADR-0004). Regimen de migracion: rige codigo nuevo (precedente MEF-ADR-0043 seccion 7).
- **Doctrina MCP absorbida en dos fases**: hoy solo lo validado (interinidad por settings + gate
  en el borde); la derivacion del tenant por usuario (su #540) queda como evolucion documentada,
  no doctrina. Primero se opto por esperar (opcion B) y en la misma sesion, al mergear el #558
  del pionero con sus correcciones empiricas, se paso a refinar (opcion A ampliada).
- Desgloses espejo en ambos arcos: issue de ADR primero, issues de implementacion dependientes.
- `/install-apim` invertira la deteccion del paso 9: `AgregarTenantResolverHibrido()` pasa de
  "ya migrado" a estado roto que tambien se migra (#803, ya implementado).

## Descartado

- **#812 cerrado como duplicado**: draft del incidente creado desde el consumidor cuando
  #802/#803 ya estaban implementados; lo restante lo cubre #804.
- Matriz de impacto por archivo para el orden de batch: no aplica al lado interno (solo
  existe `mefisto-sequential` con sync verificado entre eslabones).
- Reporte upstream del bug de `ProxyTenantResolver` (`Cosmos.MultiTenancy.CritterStack`): fuera
  de este repo; pendiente de canalizar con el dueno del paquete. La decision de rama deberia ser
  lazy por acceso, aunque el AsyncLocal es estructuralmente superior de todos modos.

## Preguntas abiertas

- **#798 (smoke tests etapa b)**: probablemente resuelto por el lado del consumidor tras el
  patron AsyncLocal; falta la evaluacion rapida para cerrarlo o acotarlo.
- **#801 (multi-entorno con GitHub Environments)**: requiere sesion propia con desglose; conecta
  con la deuda del truncado de nombre de Storage que asume env=dev.
- Ubicacion exacta de los tipos de excepcion en el consumidor (proyecto compartido vs por
  dominio): la decide #806 siguiendo el precedente de `IRequestValidator`.
- Cuando el pionero cierre su #540: issue nuevo para la derivacion del tenant por usuario en la
  doctrina MCP.

## Referencias

Issues creados: #803, #804, #806, #807, #819, #820
Issues refinados a listo: #802, #805, #797, #799, #800
Issues cerrados: #812 (duplicado)
Comentarios: #797 (estado del pionero, luego refinado), #798 (premisa falsificada)
Implementados y cerrados durante la misma sesion (por pipelines): #802, #803, #805, #806, #807
