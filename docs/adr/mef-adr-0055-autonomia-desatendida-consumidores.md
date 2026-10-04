# MEF-ADR-0055: Autonomia desatendida de Mefisto en consumidores

- **Fecha**: 2026-10-03
- **Estado**: aceptado
- **Aplica a**: el contrato publicado, neutral a runtime, de consumidores que adopten explicitamente la autonomia desatendida. Complementa la distribucion y el contrato canonico de MEF-ADR-0053; no modifica la politica interna de MEF-ADR-0049.

## Contexto

Un lote admitido puede detenerse por una solicitud de permiso o una denegacion accidental, aunque sus tareas sean conocidas. Cambiar una solicitud por una denegacion no lo hace autonomo: conserva el impedimento. El origen es la operacion dark factory solicitada por el mantenedor y la auditoria posterior al PR #1808; el caso vivo fue una lectura de la release instalada que requirio intervencion durante `/sequential`.

Este ADR documenta decisiones acordadas. No implementa permisos, preflight, worker, schemas ni registros operativos; esos artefactos pertenecen a los issues bloqueados #1821--#1826. La certificacion posterior es #1827.

## Decision

### 1. Perfil por proyecto y entrada controlada

La autonomia se activa **explicitamente por proyecto**, no por tool call ni por lote. El perfil neutral vive en `.mefisto/harness.config.json` y declara capacidades, recursos y operaciones, sin secretos. La evidencia y el estado de autorizacion/ejecucion viven en `.mefisto/pipeline/`. El schema y el formato del registro se materializaran en los issues de implementacion.

La declaracion versionada no es consentimiento por si sola: antes de la etapa se captura una autorizacion aprobada y su revision. No sirven como autorizacion nueva una edicion del worktree, texto de issue ni una respuesta del agente. La configuracion efectiva se comprueba con la precedencia real del runtime; una restriccion ajena explicita en conflicto se diagnostica y no se sobreescribe.

El adaptador OpenCode aportara una entrada controlada para comandos Mefisto y permisos coherentes de coordinacion, delegacion y ejecucion headless, sin exigir que el usuario elija manualmente un agente ni confiar en permisos recordados de otra sesion. El binding concreto corresponde a #1823. No cambia configuracion global, proveedores, modelos ni credenciales del usuario, ni edita releases instaladas. En particular, el campo neutral `agent` no se trasladara automaticamente a comandos del adaptador Claude para resolver solo la necesidad del otro adaptador (MEF-ADR-0050).

### 2. Capacidades, recursos y operaciones autorizables

La autorizacion se expresa por funcion y recurso, no como una lista universal de binarios ni como acceso al home completo.

| Funcion | Autorizacion objetivo |
|---|---|
| Desarrollo | Lectura de release, ADRs, Skills, fuentes del consumidor y dependencias; edicion en scope; restore, build, test, cobertura, formato y toolchains declarados. |
| Coordinacion | Entrada, agentes delegados, etapas, worktrees registrados, temporales, tool-output, logs y summaries propios del pipeline, y reanudacion. |
| Entrega | Git en ramas de trabajo; PR, revision, merge, observacion y reintentos de CI ya autorizados, sujetos a permisos remotos y politica del repo. |
| Administracion acotada | Bootstrap, auth, registro/cableado de secretos, mantenimiento y purgas enumerados previamente por operacion, entorno y recurso. Una entrada generica «administrar» no basta. |

Leer la release es capacidad basica: cubre macOS con espacios, Linux y la resolucion de roots XDG/config efectivos para ubicar los recursos autorizados, ademas del cache de paquetes y las salidas del runtime, sin conceder lectura general de esas raices ni de auth stores. Los decompilados son estado propio del consumidor. La release es solo lectura para desarrollo; mantenimiento autorizado puede instalar una release inmutable, cambiar el puntero o podar versiones no usadas, pero nunca editar su contenido ni modificar la release cargada por una corrida.

`tool-output` autoriza lectura de todo el directorio global de resultados del runtime, incluso resultados de otras sesiones o proyectos del mismo usuario. Es un riesgo residual aceptado: ese contenido puede ser sensible. No concede escritura ni lectura de auth stores, logs, bases de sesiones ni el resto de datos/configuracion del runtime. La retencion y aplicacion corresponden a #1846/#1847.

### 3. Administracion preautorizada

Un lote puede contener administracion, pero antes de admitirla deben conocerse accion, entorno, recursos afectados, revision del plan y condiciones o limites aprobados. Una purga u otra accion irreversible exige autorizacion especifica ligada al diagnostico, plan o dry-run disponible; produccion no queda implicita por activar el perfil.

Si falta consentimiento, dato o privilegio remoto, la admision se rechaza con causa concreta: ninguna etapa comienza para esperar aprobacion. Cambiar accion, destino, alcance destructivo o limites invalida la autorizacion relevante; la nueva autorizacion ocurre fuera de la etapa. Un cambio de worktree o release dentro de las mismas capacidades aprobadas no la invalida por si solo, aunque la evidencia tecnica se revalida al cambiar runtime, release, perfil o entorno.

Los actores que custodian credenciales continuan usandolas sin revelar valores al modelo. Un permiso del runtime no concede RBAC de Azure ni derechos de GitHub; `plan` y `apply` ordinarios continúan en CI conforme a MEF-ADR-0022 y MEF-ADR-0025.

### 4. Admision, ejecucion y evidencia

La secuencia es: **activar/autorizar perfil -> resolver identidad y recursos -> verificar capacidades/requisitos -> admitir -> ejecutar/observar -> verificar resultado**. La admision captura snapshot de repo, runtime/version, release cargada, revision de perfil/autorizacion, recursos, toolchain y agentes. Una corrida conserva una identidad de release coherente y no toma la ultima version del cache en cada paso.

Invariante de una corrida admitida: **cero prompts y cero denegaciones de capacidades requeridas**. No se omite una lectura o comprobacion obligatoria para aparentar continuidad. Un cambio externo o una operacion fuera del alcance falla o no se admite explícitamente, de forma recuperable, sin autoampliacion, espera interactiva silenciosa ni reintento ciego. Esto no promete eliminar fallos de red, proveedor, credenciales expiradas o autorizacion externa cambiante. La politica existente del orquestador sigue gobernando cola, dependencias y reanudacion.

Cada corrida/etapa deja evidencia sanitizada de identidad, comprobaciones, solicitudes o denegaciones observadas y resultados requeridos. Desconocido no equivale a cero; exit 0 no demuestra por si solo tarea completa.

| Escenario | Resultado esperado |
|---|---|
| `Grep` de ADR/fuente dentro de la release cargada | **Permitir** como lectura basica; sin prompt extraordinario. |
| Bootstrap exacto, entorno y recurso incluidos en autorizacion vigente | **Permitir** tras admision; la etapa no pide aprobacion. |
| Purga sin consentimiento especifico | **No admitir**, con causa de autorizacion faltante. |
| Operacion cambia a entorno o recurso no aprobado | **No admitir/fallar** con causa; no autoampliar permisos. |
| Denegacion observada o conteo de solicitudes desconocido durante etapa | **Completitud no demostrada**; fallar con evidencia, sin ocultarlo como exito. |

### 5. Local primero; aislamiento despues

La primera adopcion corrige el entorno local actual mediante capacidades explicitas y admision verificable. No exige contenedor ni VM para los fixes puntuales. El modo local **no es un sandbox**: OpenCode declara expresamente que no ejecuta en sandbox [1], y los controles del harness tampoco aislan el proceso frente al host. `--auto` tampoco elimina reglas de denegacion [2]. El perfil no concede shell universal, `sudo` ni elimina controles del host.

El worker aislado de #1824 es una evolucion posterior: workspace y caches propios, release de solo lectura y custodia acotada. La autonomia amplia de shell de ese worker requiere aislamiento y certificacion. Elegir Docker, VM u otra plataforma queda para su refinamiento; #1824 no bloquea la adopcion local inicial.

### 6. Compatibilidad y certificacion futura

Sin perfil nuevo, Claude conserva flujo, argumentos, modelos, herramientas/Skills, delegacion, fallbacks y reanudacion; no requiere instalar ni configurar OpenCode ni una migracion silenciosa. Una compensacion exclusiva de OpenCode no altera Claude. Todo cambio neutral declara su delta y exige pruebas en ambos adaptadores: regenerar artefactos no prueba no regresion funcional.

Las implementaciones futuras deben aportar tests deterministas de contratos y regresiones, sin LLM ni red real; un smoke separado y controlado de la release instalada con OpenCode; un control TDD equivalente de Claude hasta verificaciones/PR; y coexistencia sin contaminacion. Los invariantes incluyen consumidor solo Claude, contratos legacy, eventos conocidos y desconocidos, y coexistencia de adaptadores. #1827 registrara plataformas, versiones, casos, evidencia y limitaciones. Este ADR fija la obligacion, no afirma certificacion runtime realizada.

## Alternativas consideradas

### Alt a: permiso por tool call o por lote

**Descartada**: reintroduce interaccion y no permite admision verificable antes de ejecutar.

### Alt b: excluir administracion de la dark factory

**Descartada**: impide operaciones necesarias que pueden acotarse por accion, entorno y recurso con consentimiento previo.

### Alt c: aislamiento obligatorio desde la primera adopcion

**Descartada**: retrasa los bloqueos locales actuales y confunde el objetivo inmediato con la evolucion de #1824.

### Alt d: ampliar permisos ante una denegacion

**Descartada**: convierte la etapa en su propia autoridad y contradice MEF-ADR-0019 y la evidencia previa exigida por MEF-ADR-0031.

## Consecuencias

### Positivas

- La admision puede decidir antes de ejecutar si un lote tiene capacidades, consentimiento y evidencia suficientes.
- Desarrollo, entrega y administracion acotada comparten un contrato sin exponer secretos ni ampliar derechos remotos.
- La compatibilidad de consumidores solo Claude queda como invariante verificable.

### Negativas y limites

- El acceso a `tool-output` global conserva el riesgo residual de contenido sensible de otras sesiones.
- Local primero no proporciona aislamiento frente al host.
- Una corrida admitida puede fallar por condiciones externas; el contrato exige evidencia y recuperabilidad, no exito artificial.
- Los mecanismos ejecutables y la certificacion quedan deliberadamente pendientes de los issues dependientes.

## Referencias

- MEF-ADR-0019: separacion publicado/interno; una etapa no amplia el control que la gobierna.
- MEF-ADR-0022 y MEF-ADR-0025: autorizacion remota, CI y custodia de secretos permanecen en sus actores.
- MEF-ADR-0030: identificacion `MEF-ADR-0055`.
- MEF-ADR-0031: admision y certificacion basadas en evidencia reproducible.
- MEF-ADR-0049, seccion 5: `--auto` no elimina denegaciones y su politica interna no cambia aqui.
- MEF-ADR-0050: intenciones neutrales y bindings por adaptador.
- MEF-ADR-0053, secciones 2, 4 y 5: releases inmutables, contrato canonico/fallback y paridad distribuida.
- [1] OpenCode, [Security: No Sandbox](https://github.com/anomalyco/opencode/blob/v1.18.29/SECURITY.md), version 1.18.29; fuente del limite del modo local.
- [2] OpenCode, [Permissions](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/web/src/content/docs/permissions.mdx), version 1.18.29; fuente del limite de `--auto`.
- Issue #1820: origen y decisiones del mantenedor; #1821--#1827: implementacion y certificacion posteriores.

## Control de cambios

- 2026-10-03: creacion como `aceptado` (issue #1820). Fija perfil opt-in por proyecto, entrada controlada, administracion preautorizada y acotada, ciclo de admision con evidencia, local primero sin promesa de sandbox y compatibilidad/certificacion futura; no implementa permisos ni declara certificacion runtime.
