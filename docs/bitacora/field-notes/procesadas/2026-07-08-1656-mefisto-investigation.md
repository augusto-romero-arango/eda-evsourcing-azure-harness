---
fecha: 2026-07-08
hora: 16:56
sesion: mefisto-investigator
tema: Bootstrap no determinista (.gitignore raiz y smoke-tests-dominio.yml) que rompe el scaffold paralelo (issue #238)
---

## Sintoma reportado

Al scaffoldear varios dominios en paralelo (5 dominios en Cosmos.ControlPlane / SincoERP,
mismo episodio que motivo #234), dos archivos de bootstrap compartido salen con contenido
distinto entre corridas del agente `domain-scaffolder`:

- El `.gitignore` **raiz** del repo consumidor: una corrida versiono `local.settings.json`
  (con `Password=postgres`), otra lo ignoro.
- El reutilizable `.github/workflows/smoke-tests-dominio.yml` (presuntamente).

Como dos ramas paralelas parten del mismo `origin/main` donde el archivo aun no existe,
ambas lo generan; un add/add que deberia resolverse sin diff se vuelve conflicto add/add real.

## Investigacion

Repo Mefisto confirmado (`.claude-plugin/plugin.json` presente). Working tree limpio.

Archivos y evidencia auditados:

- `grep -rn "gitignore" agents/ commands/ scripts/ hooks/ README.md` + `.claude/` (internos)
  y `docs/`, mas `commands/scaffold.md`, `commands/infra-base.md`, `commands/onboard.md`
  y `docs/greenfield-quickstart.md`.
- `agents/domain-scaffolder.md`: Paso 1 (lineas 118-141), Paso 8 (commit, 1768-1790),
  Paso 9 (`local.settings.json`, 318-326), Paso 6 (workflows smoke, 1584-1706).
- `agents/infra-base-scaffolder.md`: Paso 2.5 (`.gitignore` del entorno, 1160-1190),
  Paso 5 (reporte, 1507-1522), reglas absolutas (1524-1536).
- `docs/adr/0021-infraestructura-base.md` (reparto de responsabilidades greenfield).
- Historial: `git log` sobre ambos agentes (sin regresion reciente que introduzca el gap;
  el gap es estructural, preexistente).

Correlacion de la cadena causal del `.gitignore` raiz (confirmada leyendo el codigo):

1. `func init --worker-runtime dotnet-isolated` (Paso 1) genera dentro del proyecto un
   `src/<Ns>.{Dominio}/.gitignore` estandar de Functions (ignora `local.settings.json`,
   `bin/`, `obj/`, etc.) y un `local.settings.json`.
2. Paso 1 (linea 138): `rm -f "$REPO_ROOT/src/<Ns>.{PascalCase}/.gitignore"` **borra ese
   guard per-proyecto**, apoyandose textualmente en "ya cubiertos por el .gitignore raiz"
   (linea 135) -> asume que el raiz existe.
3. Paso 9 (lineas 318-326): agrega `MartenConnectionString=Host=...;Password=postgres` a
   `local.settings.json`.
4. Paso 8 (linea 1772-1773): `git add "src/<Ns>.{PascalCase}/"` stagea el directorio
   completo. Que `local.settings.json` entre o no al repo depende **enteramente del
   `.gitignore` raiz**.
5. Ningun componente del harness emite ese `.gitignore` raiz (ver Diagnostico). El LLM lo
   improvisa cada corrida -> contenido divergente -> una corrida ignora `local.settings.json`
   y otra lo versiona (fuga de secreto de dev).

Reproduccion del efecto add/add (simulacion git en scratchpad, no el agente completo):
- Dos ramas desde una base sin el archivo, con `.gitignore` de contenido **divergente**
  -> `CONFLICT (add/add)`. Coincide con el sintoma de campo.
- Mismas dos ramas con `.gitignore` **byte-identico** -> merge limpio, sin conflicto.
  Confirma que la determinacion byte-a-byte desde una unica fuente es el fix real (no el guard
  "solo si no existe").

## Diagnostico

**Dos causas raiz distintas, una por archivo.**

### `.gitignore` raiz -- HIPOTESIS CONFIRMADA (gap: no hay fuente)

- Ningun agente / skill / script / hook / README / doc de onboarding emite el `.gitignore`
  raiz del consumidor. Unicas menciones: `infra-base-scaffolder` Paso 2.5 genera
  `infra/environments/<env>/.gitignore` (del entorno Terraform, NO el raiz); `domain-scaffolder`
  Paso 1 solo **borra** el per-proyecto de `func init` y **asume** el raiz.
- El `.gitignore` de la raiz del propio repo Mefisto (224 bytes, ignora `.claude/pipeline/`)
  es del plugin, no del consumidor: irrelevante.
- `docs/greenfield-quickstart.md` (camino de 10 pasos) no crea un `.gitignore` raiz en ningun
  paso: `/infra-base` (paso 7) solo escribe `infra/` + `infra-cd.yml`; `/scaffold` (paso 10)
  asume el raiz.
- Conclusion CA-1: **no existe generacion explicita del `.gitignore` raiz**. Aparece hoy por
  improvisacion del LLM (o aporte manual del consumidor). Es estructuralmente no determinista:
  no hay fuente byte-fija de donde derivarlo.
- La evidencia de campo (`local.settings.json` versionado vs ignorado) mapea exactamente a
  este raiz, via la cadena Paso 1 (borra guard) -> Paso 8 (`git add src/...`). Con lectura de
  ADR-0025: cuando el raiz no ignora `local.settings.json`, un secreto de dev
  (`Password=postgres`) se commitea.

### `smoke-tests-dominio.yml` -- HIPOTESIS MATIZADA (fuente byte-fija; riesgo = deriva de transcripcion)

- `domain-scaffolder` Paso 6.1 (lineas 1603-1650) SI incluye una plantilla literal completa
  del workflow (idem 6.2 `smoke-tests.yml`, 1667-1704). No es "ausencia de fuente".
- Conclusion CA-2: el riesgo NO es no determinismo estructural sino, a lo sumo, **deriva de
  transcripcion** del LLM (normalizacion de espacios, comentarios, orden). El sintoma de campo
  NO confirma divergencia real del workflow (el issue lo marca "presuntamente"); la divergencia
  confirmada mapea al `.gitignore`. Un add/add byte-identico mergea limpio (ver simulacion), asi
  que si la transcripcion es fiel el conflicto es benigno; si deriva, conflicto real pero de baja
  probabilidad.

### Alcance publicado vs interno

El bug vive en el **lado publicado** (`agents/domain-scaffolder.md`,
`agents/infra-base-scaffolder.md`). No hay equivalente interno de estos scaffolders
(`.claude/agents/` no los replica), asi que no hay divergencia publicado/interno que reconciliar.

## Acciones

- Field notes creadas (este archivo). CA-4 cubierto.
- Ningun issue creado aun: pendiente de confirmacion del usuario (ver "Preguntas abiertas" y la
  propuesta de fix). NO se modifico codigo del plugin.

### Recomendacion de fix (CA-5, a confirmar)

1. **`.gitignore` raiz -> emitirlo byte-fijo desde `infra-base-scaffolder` (greenfield).**
   Encaja en ADR-0021 (base greenfield del repo/entorno, corrida unica no paralelizada, se
   ejecuta en el paso 7 ANTES del primer `/scaffold` paso 10). Al ser corrida unica, elimina el
   add/add de raiz: no hay dos ramas creandolo. La plantilla debe incluir como minimo
   `local.settings.json` (blindaje ADR-0025), `bin/`, `obj/`, artefactos .NET/VS y `*.log`.
   Alternativa mas debil: emitirlo en el "primer arranque" de `domain-scaffolder` con guard
   "solo si no existe" + contenido byte-fijo; pero sigue expuesta al add/add paralelo (solo
   benigno si la transcripcion es identica). Preferible la primera opcion.
   - Dado que `domain-scaffolder` Paso 1 depende de que el raiz exista, ademas conviene que el
     agente NO borre el per-proyecto de `func init` sin garantia de que el raiz ya cubre
     `local.settings.json` (o que el `git add` del Paso 8 sea selectivo). A afinar en el issue.

2. **`smoke-tests-dominio.yml` (y `smoke-tests.yml`) -> reforzar transcripcion literal.**
   ADR-0019/ADR-0021 rechazan un directorio `templates/` de blobs copiables (los agentes emiten
   inline), asi que "extraer a archivo estatico" contradice la doctrina. Fix realista: reforzar
   la instruccion de transcripcion byte-a-byte. Opcion mas robusta (mayor alcance): hoistear la
   emision de estos dos workflows compartidos a `infra-base-scaffolder` (corrida unica greenfield,
   como `infra-cd.yml`), eliminando el add/add paralelo igual que el `.gitignore`. Evaluar contra
   el alcance de #234.

### Issue de implementacion propuesto (NO creado; requiere confirmacion)

- Titulo: "Emitir el .gitignore raiz del consumidor de forma determinista en infra-base-scaffolder"
- Labels: `tipo:tooling`, `bug`, `estado:listo` (o `estado:borrador` para refinar el alcance del
  workflow). Sin `dom:` (no aplica en Mefisto).
- Cuerpo: fix (1) como nucleo; fix (2) como sub-tarea o issue separado enlazado a #234; referencia
  a #238 (Closes) y a #234 (relacionado, no bloqueante).

## Preguntas abiertas

- CA-2/CA-3 del workflow: nadie confirmo en campo si `smoke-tests-dominio.yml` divergio de verdad.
  Vale la pena pedir a @luisfelipediaz el diff real del conflicto del workflow (si lo hubo) para
  cerrar si fue add/add benigno o deriva. Sin ese dato, la conclusion es "riesgo de deriva, baja
  probabilidad, benigno si identico".
- El fix del `.gitignore` raiz en `infra-base-scaffolder` introduce una dependencia de orden
  suave (infra-base debe correr antes del primer scaffold). Ya existe de facto (Paso 4 de
  domain-scaffolder asume los modulos base), pero conviene documentarla explicitamente o poner un
  guard en domain-scaffolder que emita el raiz si falta (con el mismo contenido byte-fijo, fuente
  unica compartida) para el caso de que alguien scaffoldee sin infra-base.
- Coordinar con #234 (paralelizacion del scaffold): decidir si el hoist de los workflows
  compartidos a infra-base entra en #234 o en el issue de este fix.
