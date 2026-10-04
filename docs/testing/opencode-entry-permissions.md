# Politica efectiva de entrada OpenCode

`src/published/scripts/adapters/lib/opencode-entry-permissions.jq` es una biblioteca
pura del adaptador publicado. Implementa el subconjunto verificable de
`Permission.evaluate`, `Permission.fromConfig` y `Wildcard.match` de OpenCode
v1.18.29: <https://github.com/anomalyco/opencode/blob/v1.18.29/packages/opencode/src/permission/index.ts>
y <https://github.com/anomalyco/opencode/blob/v1.18.29/packages/core/src/util/wildcard.ts>.
La forma de configuracion y la precedencia de la conversion legacy se fijan en
<https://github.com/anomalyco/opencode/blob/v1.18.29/packages/core/src/v1/config/permission.ts>
y <https://github.com/anomalyco/opencode/blob/v1.18.29/packages/opencode/src/config/config.ts#L567-L577>.

Recibe JSON por `stdin` y se invoca con `jq -L ... 'include
"opencode-entry-permissions"; entry_permissions'`. No lee configuracion, no
ejecuta comandos y no modifica sesiones. Su salida versionada contiene solo
datos de politica y decisiones. Sus diagnosticos contienen solo codigo, permiso
e indice; nunca reproducen candidatos, patrones ni payloads.

## Operaciones

- `normalize`: convierte `tools` legacy y `permission` a `rules` ordenadas. Las
  claves legacy `write`, `edit` y `patch` convergen en `edit`; las reglas
  explicitas siguen a las legacy y por tanto prevalecen.
- `evaluate`: aplica ultima coincidencia sobre candidatos ya resueltos.
- `compose`: materializa las restricciones globales sobre la politica gestionada.
  Un allow global no concede fuera de la gestionada y un deny conservado gana por
  posicion. Rechaza toda interseccion no representable o mas de 1024 reglas por
  permiso con un conflicto y sin devolver una politica parcial. Un `ask` global
  solo se convierte en `allow` cuando la entrada declara consentimiento vigente;
  `auto` no participa en esa decision.
- `certify-session`: exige consentimiento vigente y observacion de sesion. Un
  deny o ask efectivo sobre una operacion requerida rechaza la entrada; una
  sesion observada vacia conserva la decision gestionada. Las aprobaciones
  recordadas no son una autoridad adicional.

El matcher normaliza barras inversas, expande `~` y `$HOME` solo con el `home`
provisto, admite `*`, `?`, Unicode y el sufijo ` *` con argumentos opcionales.
`*` cruza `/`; las comillas son caracteres literales. Las intersecciones se
limitan a universal, identica, literal contra patron y prefijos terminales. No
se parsea shell ni se aproximan glob arbitrarios: `policy-not-representable`
falla cerrado. La politica es un control de herramientas, no un sandbox ni una
autorizacion administrativa.
