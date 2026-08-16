---
fecha: 2026-08-16
hora: 18:17
sesion: mefisto-planner
tema: refinamiento de #652 - doctrina de always_on (MEF-ADR-0020) y wiring roto hasta el site_config
---

## Contexto

Sesion corta de modo refinar sobre el draft #652, creado desde el consumidor
Bitakora.ControlAsistencia (su issue #400 aplica `always_on = true` en dev
documentando la desviacion del ADR). El draft denunciaba que el fundamento de
costo de `always_on = false` en MEF-ADR-0020 ("en dev se acepta OFF para
ahorrar") es factualmente falso en tiers dedicados: en Basic/Standard/Premium
la VM se factura por hora este la app despierta o dormida, y la doc de
Functions recomienda ON en planes dedicados.

## Descubrimientos

- **Output huerfano confirmado durante la verificacion de causa raiz**: el
  modulo `service-plan` (infra-base-scaffolder seccion 1.5) acepta `always_on`
  y lo expone como output "para que la Function App lo aplique en su
  `site_config`", y MEF-ADR-0021 promete que "el valor no se pierde" -- pero el
  modulo `function-app` (seccion 1.7) nunca gano el input, y el bloque HCL del
  `domain-scaffolder` (Paso 4) tampoco se lo pasa. Como el default de
  `site_config.always_on` en `azurerm_linux_function_app` es `false`, el valor
  del usuario muere sin efecto: hoy `always_on` no llega a ninguna parte.
  El draft solo pedia "fijar el mecanismo"; la verificacion en el repo lo
  elevo a bug de wiring (label `bug` agregado).
- El razonamiento de ahorro era correcto en Consumption (escala a cero) pero
  el propio MEF-ADR-0020 proscribe Y1 y fija piso B1 dedicado: no existe
  escenario del marco donde `false` ahorre, y si uno donde dana (interrumpe el
  poll del outbox de Wolverine en `DurabilityMode.Solo`).

## Decisiones

1. **Default unico `always_on = true`**, sin distincion dev/prod. Se elimina
   del cuerpo del ADR toda la retorica de "ahorro en dev" (convencion del
   repo: lo obsoleto se elimina del cuerpo, nunca se marca "obsoleto"; el
   registro queda solo en Control de cambios).
2. **Mecanismo de wiring: cerrar la cadena ya prometida** (opcion a). El
   contrato de 4 inputs del modulo `service-plan` queda intacto; el modulo
   `function-app` gana input `always_on` (bool, `default = true`) aplicado en
   `site_config.always_on`; el `domain-scaffolder` pasa
   `always_on = module.service_plan_{snake_case}.always_on` al
   `module function_app_{snake_case}`. Retrocompatible: los `dominio-*.tf`
   heredados siguen validando y regenerar el modulo con `/infra-base`
   (idempotente) corrige el entorno en el siguiente `apply`.
3. **Issue unico** (2 ADRs + 2 agentes): eje homogeneo, 6 CAs, ediciones
   puntuales <30 min. Partir en enmienda + propagacion (patron #643) dejaba
   una propagacion trivial acoplada 1:1 y un estado intermedio contradictorio.

## Descartado

- **Opcion (b) de wiring**: mover `always_on` al modulo `function-app`
  quitandolo del contrato del `service-plan`. Mas "honesto" con donde vive el
  argumento en `azurerm`, pero rompe la firma del modulo: los `dominio-*.tf`
  heredados que le pasan `always_on` fallarian `terraform validate` al
  regenerar, y la enmienda a los dos ADRs seria mas invasiva.
- **Partir en dos issues** (enmendar ADRs -> propagar a scaffolders).
- **Mantener la distincion dev/prod** del default.

## Preguntas abiertas

- Ninguna. El issue quedo autocontenido y sin dependencias.

## Referencias

Issues creados: ninguno.
Issues refinados: #652 (borrador -> listo, labels `tipo:tooling` + `bug`),
titulo nuevo "Corregir el default y fundamento de costo de always_on en
MEF-ADR-0020 y cerrar su wiring hasta el site_config de la Function App".
Origen preservado: Bitakora.ControlAsistencia #400.
