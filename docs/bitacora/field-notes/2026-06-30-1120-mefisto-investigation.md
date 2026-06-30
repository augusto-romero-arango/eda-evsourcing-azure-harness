---
fecha: 2026-06-30
hora: 11:20
sesion: mefisto-investigator
tema: GAPS en los mecanismos de conexion/comunicacion de la topologia de dos namespaces ASB (publish, provisioning, consumo)
---

## Sintoma reportado

No es un bug puntual: revision transversal de "¿esta el ciclo completo de la topologia de dos
namespaces ASB (interno + integracion, ADR-0023) claro y especificado en el plugin?". Preguntas guia:
Q1 claridad al publicar (publico/privado + registro por tipo en Program.cs), Q2 ciclo de
aprovisionamiento y su disparador (always-on vs JIT, quien crea el topic, orquestacion codigo<->infra),
Q3 lado subscriptor/consumidor (intra-BC interno; inter-BC diferido), Q4 otros gaps (app settings duales,
string magico "integracion", DLQ, testing). Distinguir: (A) mecanismo claro / (B) ya cubierto por
#128/#130/#131 en vuelo / (C) gap real candidato a draft.

## Investigacion

Archivos leidos:
- ADRs: 0023 (raiz topologia), 0021 (infra base), 0001 (topic por evento), 0003 (stack ES + wiring
  Program.cs), 0012 (frontera serializacion).
- Agentes: implementer.md (completo), domain-scaffolder.md (completo, 1725 lineas),
  infra-base-scaffolder.md (completo), reviewer.md (antipatrones ADR-0012 + smoke), test-writer.md (6d/6e),
  smoke-test-writer.md (cobertura de efectos).
- Issues en vuelo: #128 (estado:listo, reforma ADR-0021), #130 (estado:borrador, scaffolders dos
  namespaces), #131 (estado:listo, concepto BC en config).
- Codigo fuente del paquete: Cosmos.BuildingBlocks/Cosmos.EventDriven.CritterStack.AzureServiceBus/
  WolverineExtensions.cs (verificado el wiring real) y Cosmos.EventDriven.Abstractions (jerarquia
  IEvent/IPublicEvent/IPrivateEvent).

Verificaciones de codigo:
- WolverineExtensions.cs: `HabilitarAzureServiceBusParaServerLess` (L24, broker DEFAULT) vs
  `AgregarAzureServiceBusNombradoServerless` (L34, named broker via AddNamedAzureServiceBusBroker).
  `PublicarEventoServerless<T>(topic)` L53 (default) vs `(nombreConexion, topic)` L76 (named). Bulk
  helper `PublicarEventosServerless(nombreConexion, topic, Assembly)` L116 filtra por
  `IsAssignableTo(typeof(IEvent))` (L119) -> captura privados Y publicos (caveat confirmado).
- El paquete ASB **no expone helper de listen/subscribe** (el de RabbitMQ si: ListenToRabbitQueue). El
  consumo en el harness se hace con `[ServiceBusTrigger]` de Azure Functions, mecanismo independiente del
  registro de brokers de Wolverine.

## Diagnostico

Mapa end-to-end "publicar un evento publico":
1. decidir publico/privado -> CLARO (implementer tabla, planner).
2. forma del payload plano/portable -> CLARO Y BLINDADO (ADR-0012 + test-writer 6e + reviewer #7;
   cascada #134/#139/#140 ya mergeada).
3. registrar tipo en Program.cs con broker correcto -> cubierto por #130 CA-7/8/9 (B).
4. provisionar namespace+topic+RBAC -> doctrina #128 + HCL #130 (B) PARA EL SCAFFOLD; pero el implementer
   agrega topics por flujo a `module "service_bus"` singular -> GAP (C).
5. publish runtime (sender agnostico) -> CLARO (spike #129 verificado).
6. consumir el evento -> GAP (C) grande.

GAPS REALES (C):
- G1 [ALTA]: implementer.md L629-648 agrega topics a `module "service_bus"` sin distinguir interno vs
  integracion. Tras #130 existiran service_bus_interno/service_bus_integracion; el implementer manda al
  modulo equivocado -> un IPublicEvent registrado al broker "integracion" publica a un topic que no
  existe en ese namespace. #130 NO toca implementer.md (alcance: solo scaffolders).
- G2 [ALTA]: lado consumidor no wireado para dos namespaces. El consumo usa `[ServiceBusTrigger]`
  (no Wolverine). El atributo `Connection = "ServiceBusConnectionString"` (implementer L284) NO coincide
  con el app setting real `SERVICE_BUS_CONNECTION` (domain-scaffolder L1322/L203): string huerfano YA hoy
  con un namespace. Con dos namespaces hacen falta dos app settings y elegir cual por origen del topic.
  #130 CA-6 introduce _INTERNO/_INTEGRACION solo en el lado PUBLISH (Program.cs), no toca el trigger.
- G3 [MEDIA]: asimetria real no es "intra cubierto / inter diferido" sino "publish cubierto / subscribe
  roto incluso intra-BC". Falta nota de alcance explicita.
- G4 [MEDIA]: ADR-0003 L79/L108 describe el wiring como "dos calls a HabilitarAzureServiceBusParaServerLess"
  -> INCORRECTO segun spike #129 y codigo (es Habilitar... + Agregar...Nombrado...). Texto aun en
  condicional ("spike #129 valida") cuando ya cerro positivo. Ningun issue en vuelo vuelve sobre ADR-0003
  (#137 lo enmendo dejando la imprecision).
- G5 [BAJA]: "integracion" es string magico sin centralizar; riesgo de typo -> publish silencioso al
  default. Se absorbe en draft de G1/G2.
- G6 [BAJA, NO gap]: DLQ por namespace no diferenciado; ADR no pide diferenciacion. Mecanismo suficiente
  hoy (categoria A).

CUBIERTO (B): #128 doctrina ADR-0021; #130 HCL + app settings publish + Program.cs + caveat bulk; #131
concepto BC en config. Forma payload ya mergeada (#134/#139/#140).

Causa raiz transversal: #128/#130/#131 cubrieron provisioning + publish del scaffold inicial, pero el
flujo iterativo (dominio que gana su primer evento publico DESPUES del scaffold) pasa por el implementer,
que quedo sin actualizar para dos namespaces en publish-infra (G1) y consumo (G2).

## Acciones

Ninguna ejecutada (el usuario pidio ver el analisis antes de crear issues). Drafts propuestos, pendientes
de confirmacion, todos en el repo de Mefisto (sin -R):
1. [prio 1] Draft publicado/agente: actualizar implementer.md para enrutar topics al namespace correcto
   (G1). Gateado por #128/#130.
2. [prio 2] Draft publicado/agente: wirear lado consumidor a dos namespaces -- corregir Connection del
   ServiceBusTrigger, app setting de consumo intra-BC, nota de alcance inter-BC diferido (G2/G3/G5).
   Gateado por #130.
3. [prio 3] Draft interno/ADR: enmendar ADR-0003 -- corregir wiring (Agregar...Nombrado..., no dos
   Habilitar...) y pasar lenguaje del spike #129 a afirmativo (G4).

## Preguntas abiertas

- ¿G1 y G2 son drafts nuevos o enmiendas al alcance de #130 (ampliar #130 para que toque implementer.md)?
  El usuario debe decidir; #130 hoy es explicito en NO tocar implementer.md.
- Coordinacion de nombres de app setting entre publish (#130: _INTERNO/_INTEGRACION) y consumo (G2): hay
  que asegurar que el trigger lea el MISMO nombre que el Program.cs, para no reintroducir el desajuste
  ServiceBusConnectionString vs SERVICE_BUS_CONNECTION en la nueva forma dual.
- Provisioning del topic: ¿always-on o JIT? ADR-0021/#128 implican que los namespaces son always-on
  (infra base crea ambos), pero los TOPICS los agrega el implementer por flujo (JIT, ADR-0001). Wolverine
  con SendInline no auto-provisiona topic; el topic debe existir en Terraform antes del publish. Confirmar
  que esta orquestacion codigo<->infra quede documentada al cerrar G1.

## Correccion (2026-06-30, misma sesion)

Tras crear los drafts, el usuario cuestiono que G2 fuera un bug desplegado ("funciona en mis ambientes
de Azure"). Se VERIFICO contra el codigo real del consumidor `Bitakora.ControlAsistencia` y la premisa de
severidad de G2/G3 quedo DESMENTIDA:

- `Bitakora.ControlAsistencia/.../ControlHoras/.../FunctionEndpoint.cs` L19-22 usa
  `Connection = "SERVICE_BUS_CONNECTION"`, coherente con su `Program.cs` L22
  (`GetEnvironmentVariable("SERVICE_BUS_CONNECTION")`) y con el app setting que provisiona Terraform.
  Es el UNICO `Connection = "..."` del repo. El trigger se conecta y funciona; NO hay bug desplegado.
- El `Connection = "ServiceBusConnectionString"` que motivo G2 vive SOLO en el EJEMPLO ilustrativo de
  `agents/implementer.md` L284, desincronizado del resto del harness. El `implementer` real NO copio ese
  string al generar el proyecto: uso el nombre correcto. Es una trampa de copy-paste en el doc, no un
  fallo de runtime.

Reclasificacion de los hallazgos afectados:
- **G2a (#146)**: de "[ALTA] connection string huerfano roto YA hoy" -> **[BAJA] higiene de documentacion**:
  corregir el ejemplo de `implementer.md` L284. Sin label `bug`. El codigo generado es correcto.
- **G3 (#147)**: la asimetria NO es "subscribe roto incluso intra-BC". El subscribe funciona hoy con un
  namespace; la asimetria real es "publish wireado a dos namespaces (#130), subscribe aun apunta a uno".
  El gap de #147 es la AUSENCIA DE DISENO para elegir entre dos namespaces, no una brokenness.

NO afectados (siguen validos tal como se diagnosticaron): G1 (#145, implementer enruta topics al modulo
equivocado), G4 (#148, ADR-0003 con wiring incorrecto y condicional), G5 (string magico, absorbido en
#147), G6 (DLQ, no gap).

Leccion de proceso: el analisis verifico contra el doc del harness y el codigo del paquete, pero NO contra
un proyecto consumidor desplegado. Cruzar hallazgos de "deployed broken" con el codigo real del consumidor
ANTES de clasificar severidad. Los issues #146 y #147 ya quedaron corregidos en GitHub.
