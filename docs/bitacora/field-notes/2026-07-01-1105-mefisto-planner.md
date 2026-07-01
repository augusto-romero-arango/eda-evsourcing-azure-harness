---
fecha: 2026-07-01
hora: 11:05
sesion: mefisto-planner (desglose)
tema: Desglose de ADR-0024 en issues de implementacion; oleadas y dependencias
---

## Contexto

ADR-0024 ("Modelo de eventos de bus del Bounded Context") se acepto y mergeo a main (PR #159).
Sesion de desglose: convertir sus secciones "Enmiendas que este ADR ordena" y "Trabajo diferido"
en issues accionables con dependencias y oleadas. Sin escribir codigo; solo issues.

## Desglose (8 issues nuevos + 1 refinado)

- **#160** Enmendar ADR-0021: un solo namespace interno por BC.
- **#161** Enmendar ADR-0023 #2 y #5: un ns interno + OHS reencuadrado como caso diferido.
- **#162** Enmendar ADR-0003: wiring de broker interno default + N brokers nombrados por cadena.
- **#163** "Alcance" de ASB (propio/compartido/externo) en harness.config.json + _pipeline-common.sh.
- **#164** Realinear implementer.md: publico -> backbone compartido (no module service_bus_integracion por BC).
- **#165** infra-base-scaffolder: un ns interno por BC + custodia Key Vault del backbone.
- **#166** domain-scaffolder: wirear el backbone con cadena custodiada en Key Vault.
- **#167** Barrido de referencias secundarias al ns de integracion (ADRs 0001/0005/0012/0020/0022 +
  agentes reviewer/test-writer/planner).
- **#158** (refinado) Consumir eventos publicos de otro BC via backbone compartido.

## Grafo de dependencias

- Doctrina paralela (sin deps): #160, #161, #162.
- #162 -> #163 (config, base del wiring de N brokers).
- #160 + #163 -> #165 ; #163 -> #164 ; #162 + #163 -> #166.
- #161 + #162 -> #167.
- #163 + #164 + #166 -> #158.

## Oleadas

1. #160, #161, #162 (paralelo, tres ADRs distintos, sin solape).
2. #163 (config; gatea casi todo).
3. #164, #165, #166 (paralelo; comparten el nombre del app setting del backbone y el modelo de
   custodia Key Vault -> fijar ese nombre antes, o secuenciar #165 primero).
4. #167 (barrido; toca archivos distintos a los agentes de scaffolding).
5. #158 (final).

## Decisiones

- **Oleada 1 a estado:listo** (#160/#161/#162): cumplen DoR, sin dependencias, un ADR cada uno, CAs con
  la regla de "eliminar del cuerpo, no marcar obsoleto". El resto queda estado:borrador + bloqueado
  hasta cerrar sus dependencias.
- **#167 se mantiene** aunque no esta en el mandato explicito de ADR-0024: dejar lenguaje huerfano
  ("namespace de integracion del BC" como destino del publico) reintroduciria la deriva que se arreglo
  en #156. Se le agrego **CA-5**: el barrido NO es reemplazo ciego -- distinguir referencias que
  asumian integracion-ns como transporte por defecto (realinear al backbone) de las que describen el
  caso diferido P2/externo (dejar intactas). Cuidado especial con ADR-0022 (su mencion es la frontera
  de auth runtime cross-BC, diferida).
- **Scaffolders partidos** en #165 (infra-base) y #166 (domain) para respetar "un componente por issue".
- **Titulo de ADR-0023** ("...dos namespaces...") queda como decision abierta dentro de #161 (ajustar al
  enmendar, registrando en control de cambios).

## Fuera de alcance (diferido por ADR-0024)

- Diseno fino de la integracion verdaderamente externa (ambas direcciones) -- ADR-0024 decision #5.
- Migracion a managed identity (Alt 4) -- hasta que evolucione el paquete
  Cosmos.EventDriven.CritterStack.AzureServiceBus.
- Context Map completo (registro Evans de BCs externos) -- #163 solo introduce el minimo (el backbone).

## Referencias

- ADR-0024 (aceptado, mergeado en PR #159). Issues #158, #160-#167. issue #156 (criterio semantico).
