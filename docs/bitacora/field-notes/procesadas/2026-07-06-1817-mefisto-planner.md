---
fecha: 2026-07-06
hora: 18:17
sesion: mefisto-planner
tema: Desglose de la auditoria categorica del onboarding greenfield en 6 issues de tooling
---

## Contexto

Tras la correccion de ADRs de #207 (eje central del onboarding greenfield consistente), una
auditoria categorica verificada contra el codigo encontro 6 divergencias que bloquean o
degradan el flujo greenfield end-to-end y la narrativa "cero permisos de Azure" del flujo
ongoing del dev. El objetivo de la sesion fue hacer knowledge crunching sobre cada divergencia
(verificandolas de nuevo contra el codigo, con citas file:line), proponer un desglose y, tras
confirmacion del coordinador, crear los issues en el repo de Mefisto.

## Descubrimientos

- **El infra-cd.yml emitido no tiene fuente para las variables Terraform requeridas.** El `env`
  del workflow solo lleva `ARM_*` (infra-base-scaffolder.md:1197-1200); `plan`/`apply` corren
  con `-input=false` (`:1240`, `:1315`) y `alert_email`/`postgresql_admin_password`/
  `subscription_id` son requeridas sin default (`:842`, `:845-848`). Doble filo: sin fuente CI
  falla; con `terraform.tfvars` commiteado se viola ADR-0025 decision #1 (secreto en texto
  plano, que aplica tambien al estado de Terraform). No existe `.gitignore` de `terraform.tfvars`.
- **La narrativa "cero permisos = solo bootstrap" (ADR-0022:38, ADR-0025:52) tiene un tercer
  perfil no nombrado**: la siembra de secretos en Key Vault (`az keyvault secret set` tras cada
  apply y con cada `serviceBus.external[]` nuevo) es un privilegio de infra/admin *ongoing*,
  distinto del bootstrap de una sola vez y del cero-credenciales del dev.
- **Doctrina no-obsolete (feedback en memoria)** aplica a tres de los seis: al enmendar ADRs se
  elimina del cuerpo lo superado y solo queda en control de cambios. La tabla de modulos de
  ADR-0021:62 es un caso claro (fila function-app con inputs de access key ya prohibidos por la
  regla #9 del scaffolder y ADR-0025 decision #3).
- **Idempotencia parcial de la condicion ABAC**: `setup-github-ci.sh:146` afirma idempotencia de
  `az role assignment create`, pero con `--condition` (`:195`) no actualiza una asignacion previa
  sin condicion. Se documenta como caveat; el fix real del script se difiere.

## Decisiones

- **6 issues, uno por divergencia** (#208-#213), todos `tipo:tooling` + `estado:borrador`.
- **D1 unificado (#208)**, no partido: ruta critica atomica y co-dependiente. Se dejo en el body
  la nota de "candidato a partir si crece" con el corte natural (D1a wiring TF_VAR_/.gitignore en
  el agente; D1b provision del secret fuente en setup-github-ci.sh).
- **D2 (#209) sin `bloqueado`**: la dependencia de #208 es de VALOR (el apply-en-CI que orquesta
  falla sin el wiring de #208), no de archivos (`infra-bootstrap.md` vs `infra-base-scaffolder.md`
  no solapan). Declarada en `## Dependencias` para poder paralelizar la escritura. El label
  `bloqueado` se reserva para dependencias de archivo/merge reales.
- **D6 (#213) con `bloqueado`**: comparte `README.md` con D4 (#211) y `commands/onboard.md` con
  D5 (#212) -> solape de archivo real, riesgo de conflicto de merge. Depende de #211 y #212.
- **D3 (#210) separado de D6**, pese a que ambos "tocan docs": archivos disjuntos
  (`docs/adr/0021` vs `README`+`onboard.md`) y concerns distintos (enmienda de ADR con doctrina
  no-obsolete vs barrido de docs operativas). Fusionarlos violaria "un solo componente principal".
- **ABAC (D6.5) como doc dentro de #213**, no como issue-fix del script todavia. Nota en el body
  senalando la opcion del arreglo real de `setup-github-ci.sh` si aparecen consumidores migrados
  desde un estado pre-#195.

## Descartado

- Partir D1 en D1a/D1b ahora (co-dependientes; ninguna mitad desbloquea sola).
- Fusionar D3 con D6 (concerns y archivos distintos).
- Escindir ya el fix real de idempotencia ABAC de `setup-github-ci.sh` (diferido a que exista un
  consumidor migrado desde pre-#195).
- Marcar D2 como `bloqueado` (dependencia de valor, no de archivo).

## Preguntas abiertas

- D4 (#211): ¿la siembra de secretos se mecaniza (el SP de CI ya tiene acceso a Key Vault y
  podria sembrar valores derivados de outputs) o se difiere? El password de Postgres es input, no
  output, lo que complica una mecanizacion total. La decision se toma al refinar/implementar #211.
- Al refinar #208 se decidira si el provider deja de declarar `var.subscription_id` (dejando que
  azurerm lea `ARM_SUBSCRIPTION_ID` del env) o si se alimenta con `TF_VAR_subscription_id`.

## Grafo de dependencias y oleadas

Dependencias:
- #208 (D1): raiz, sin deps.
- #209 (D2): depende de VALOR de #208 (sin `bloqueado`).
- #210 (D3): independiente.
- #211 (D4): sin dep dura; coordinar merge por solape en README (#208, #213).
- #212 (D5): independiente; comparte `onboard.md` con #213.
- #213 (D6): depende de #211 y #212 (`bloqueado`, solape de archivo).

Oleadas (por solape de archivos):
- Fase 1: #208 (bloqueante).
- Fase 2 (paralelo): #209, #210, #212 (archivos disjuntos).
- Fase 3: #211 (README + ADR-0022/0025).
- Fase 4: #213 (README + onboard.md), tras #211 y #212.

## Referencias

Issues creados:
- #208 - Alimentar las variables Terraform requeridas del infra-cd.yml por TF_VAR y blindar terraform.tfvars (D1, critica/bloqueante)
- #209 - Completar la orquestacion greenfield del agente infra-bootstrap (labels, CI, infra-base) (D2, alta)
- #210 - Corregir la fila function-app de la tabla de modulos de ADR-0021 (storage por identidad) (D3, alta)
- #211 - Enmarcar la siembra de secretos en Key Vault como privilegio infra/admin ongoing (D4, media)
- #212 - Ampliar el diagnostico de /onboard a los tokens de CLAUDE.md y la estructura de carpetas (D5, media)
- #213 - Sanear la coherencia de la documentacion de onboarding greenfield (D6, baja/barrido)

ADRs anclados: ADR-0021, ADR-0022, ADR-0024, ADR-0025, ADR-0007.
