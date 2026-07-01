---
fecha: 2026-07-01
hora: 10:23
sesion: mefisto-design (crunching coordinador + usuario)
tema: Replanteo del modelo de eventos publicos y privados de bus; consumo inter-BC; ADR-0024
---

## Contexto

Arranco como "invocar al planner para el consumo inter-BC de eventos publicos" (el trabajo que
ADR-0023 dejo diferido: Open Host Service + Context Map). El planner creo el draft ancla #158 y
recomendo "ADR primero" porque tres decisiones (propiedad de la subscription, RBAC cross-BC,
como compartir el contrato) las dejaron abiertas ADR-0023/0022 a proposito. Al conversar D1/D2/D5,
el usuario reencuadro dos veces el problema hasta reescribir el modelo de publico/privado completo.

## Descubrimientos / modelo replanteado

- **La topologia de "dos namespaces por BC always-on" (ADR-0023 #2) no encaja con la operacion
  real.** El caso normal es que el evento se quede en el BC. El publico comun se publica a un ASB
  externo/compartido (backbone del producto u otra app) al que se accede administrativamente. Hostear
  un namespace de integracion propio (OHS, ADR-0023 #5) tiene CERO casos hoy.
- **Dos formas de evento publico:** P1 (comun) = publicar a un ASB externo que no poseo pero me
  compartieron; el harness no lo provisiona, solo custodia la cadena de conexion. P2 (excepcion) =
  hostear mi propio namespace de integracion (dueno del topic + creo la subscription del consumidor).
- **Todo evento de bus cruza fisicamente el ASB**, aun intra-Function App: no hay entrega en memoria
  de Wolverine. Aplica a IPrivateEvent/IPublicEvent. Los comandos NO cambian (siguen mediados en
  proceso por Wolverine). Los eventos de event sourcing (Marten) quedan fuera (frontera ADR-0012).
- **El criterio semantico publico/privado NO cambia**: sigue siendo la frontera de BC (lo que
  arreglamos en #156). Lo que cambia es el TRANSPORTE, no el criterio.
- **#158 y el mecanismo de subscription/RBAC cross-BC** que el planner planteo quedan subsumidos:
  el acceso al ASB externo se gestiona administrativamente (no es preocupacion de implementacion);
  la unica responsabilidad del harness en ese eje es custodiar la cadena de conexion.

## Decisiones (cerradas en conversacion, 5 preguntas una a una)

1. **Alcance de "todo al ASB, sin mediacion en memoria": solo eventos.** Comandos sin cambio.
2. **Varios ASB externos:** si. El harness soporta N brokers nombrados + N cadenas custodiadas,
   cada una identificada por el ASB destino.
3. **Opt-in de P2: lo minimo.** Default-off duro (solo se provisiona el ASB propio del BC). P2 =
   flag explicito en harness.config.json, SIN ADR de justificacion. Maquinaria fina de P2 diferida
   (design-on-demand) — no se speccan features sin casos (Rule of Three, ADR-0018).
4. **Custodia de cadenas externas:** Azure Key Vault + referencia `@Microsoft.KeyVault(...)` en app
   settings. Nunca en texto plano en config/Terraform.
5. **Limite ES:** solo eventos de bus; los eventos de event sourcing (Marten) intactos.

**Regla editorial del usuario sobre ADRs:** al enmendar un ADR, el contenido obsoleto se ELIMINA
del cuerpo; no se marca "obsoleto". Solo puede quedar en el control de cambios. Motivo: evitar que
se lean por error decisiones superadas. (Guardada en memoria del coordinador.)

## Descartado

- Mantener "dos namespaces por BC always-on" (ADR-0023 #2): provisiona superficie ociosa.
- Entrega en memoria de eventos intra-proceso (Wolverine local): rompe uniformidad/trazabilidad.
- ADR de justificacion para habilitar P2: demasiada ceremonia para cero casos; basta el flag.
- Modelar ya la maquinaria fina de P2 (opt-in por-evento, provision de subscription del consumidor).

## Acciones

- ADR-0024 "Modelo de eventos de bus (privado por defecto, publico opt-in) y custodia de ASB
  externos" creado como `propuesta` en `docs/adr/0024-modelo-eventos-bus-privado-publico.md`.
  Enmienda ADR-0021, ADR-0023 (#2, #5) y ADR-0003; reafirma #156 y la frontera de ADR-0012.
- #158 reencuadrado sobre el modelo de ADR-0024.
- Entregado por rama `docs/adr-0024-modelo-eventos-bus` + PR (borrador para revision).

## Preguntas abiertas / trabajo diferido

- Diseno fino de P2 (declaracion por-evento, provision de topic + subscription del consumidor
  externo): cuando exista el primer caso real.
- Context Map con "alcance" de ASB (propio / externo-compartido / externo-ajeno) en
  harness.config.json: vehiculo para el consumo inter-BC (#158) y el wiring de N brokers externos;
  se descompone a partir de ADR-0024 una vez aceptado.
- Enmiendas concretas a ADR-0021/0023/0003 + implementer.md: issues de implementacion posteriores
  a la aceptacion de ADR-0024, honrando la regla de "eliminar, no marcar obsoleto".

## Revision del ADR-0024 (misma sesion)

Al revisar el borrador de ADR-0024 con el usuario, el modelo se simplifico y se cerraron detalles:

- **Los dos extremos verdaderamente externos son cero-caso y simetricos**, unificados en UNA
  excepcion diferida: (a) que una app ajena consuma de nosotros (hostear ns de integracion propio,
  el viejo P2) y (b) que consumamos de un ASB ajeno que no controlamos (el viejo "ajeno").
- **Alcance de ASB** como concepto: propio del BC (privado, comun) / compartido del producto
  (publico, comun; infra dueno del ns, productor crea topics, consumidor crea subscriptions) /
  verdaderamente externo (diferido).
- **Acceso al backbone compartido: por cadena de conexion; NO se toca el paquete.** Verificado
  contra el codigo: `Cosmos.EventDriven.CritterStack.AzureServiceBus` (WolverineFx.AzureServiceBus
  6.1.0) solo expone wiring por cadena; no referencia Azure.Identity ni acepta TokenCredential. El
  `[ServiceBusTrigger]` si soporta identidad nativa, pero la publicacion (Wolverine) no sin un
  overload nuevo. Decision: mantener cadenas; **managed identity queda como norte diferido** (Alt 4).
- **Custodia** en Key Vault + referencia en app settings + permiso de la MI de la Function App para
  leer el secreto; el valor lo coloca infra/admin. Queda en el camino comun (el backbone se accede
  por cadena), no en el bucket diferido.
- Un namespace interno **por BC, compartido por sus dominios** (no uno por dominio).
- ADR-0024 reescrito con todo esto; #158 reencuadrado sobre el caso comun (backbone compartido).

## Referencias

- ADR-0024 (nuevo, propuesta), ADR-0023 (#2/#4/#5), ADR-0021, ADR-0003, ADR-0012, ADR-0018, ADR-0022.
- issue #156 (criterio publico/privado BC-aware, mergeado). issue #158 (consumo inter-BC, borrador).
- Paquete Cosmos.EventDriven.CritterStack.AzureServiceBus (WolverineFx.AzureServiceBus 6.1.0):
  wiring solo por cadena de conexion; base de la decision de mantener cadenas (Alt 4).
