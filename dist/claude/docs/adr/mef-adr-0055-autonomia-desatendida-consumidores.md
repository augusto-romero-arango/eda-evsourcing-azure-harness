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

Leer la release es capacidad basica: cubre macOS con espacios, Linux y la resolucion de roots XDG/config efectivos para ubicar los recursos autorizados, ademas del cache de paquetes y las salidas del runtime, sin conceder lectura general de esas raices ni de auth stores. Los decompilados son estado propio del consumidor. La release es solo lectura para desarrollo; mantenimiento autorizado puede instalar una release inmutable, cambiar el puntero o podar versiones no usadas, pero nunca editar su contenido. El mantenimiento se coordina entre corridas y no convierte una etapa en mantenimiento.

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

### 7. Enmienda: mantenimiento entre corridas y recuperación conservadora

La instalación distingue tres clases de uso. **Retener** una release cargada e
idle la protege de la poda, pero no impide actualizar la instalación. **Ejecutar**
una corrida comprende cola, etapas, hold y reintento: bloquea los cambios
compartidos mientras exista uso vivo. **Mantener** la instalación se admite solo
en quiescencia; no es permiso para interrumpir trabajo ni para transformar una
etapa en mantenimiento. `busy` es una respuesta de coordinación, no éxito ni
autorización para forzar una operación.

| Evidencia observada | Cambio de `active` o proyección | Poda de su release | Recuperación automática |
|---|---|---|---|
| `execute` vivo | `busy` | No | No |
| `retain` idle | Puede proceder | No | No aplica |
| Muerte comprobada de propietario y todo descendiente pertinente | Puede proceder tras liberar el uso recuperado | Según las demás retenciones | Sí |
| Hijo o metadata desconocidos | Retener | No | No |
| Consentimiento revocado | No admitir una nueva corrida | No otorga excepción | No |

La recuperación automática exige demostrar que el propietario y los
descendientes pertinentes terminaron. Registra identidad de host y boot,
identidad estable de cada proceso, relaciones de lanzamiento y cobertura del
grafo; reobserva esa evidencia antes de recuperar. Un TTL, un PID aislado, el
PPID actual, una sesión idle o `exit 0` no prueban por sí solos la terminación
ni la completitud. Ante incertidumbre conserva la retención. La recuperación no
envía señales a procesos ni poda por su cuenta, y no promete recuperar un mutex
legado abandonado cuando no haya evidencia suficiente.

El registro global de esos usos es metadata de la **instalación** bajo la raíz
de datos de Mefisto, no estado de negocio ni consentimiento del consumidor. El
contexto por proyecto, su evidencia y autorización permanecen bajo
`.mefisto/pipeline/`; ningún registro global contiene secretos ni permite a una
etapa escribir sus controles. Este límite no promete aislamiento frente al
mismo usuario local ni soporte distribuido o sobre NFS.

El guard que aplica este modelo es síncrono y observa al actor que realmente
ejecuta. En OpenCode, un fallo de configuración puede ignorarse y la CLI puede
caer a un valor por defecto [3][4]; por ello el modo headless preparado exige un
handshake de la misma instancia antes del prompt y una revalidación posterior.
Los parámetros de chat deben observarse en la petición efectiva, no inferirse
de una configuración deseada [5]. Un servicio local privado no equivale al
worker aislado de #1824 ni a un sandbox: OpenCode declara que no proporciona
sandbox [1].

La ausencia de perfil (`NO_PROFILE`) conserva el flujo legacy. Una respuesta
`CONSENT_REVOKED`, o un contexto controlado inválido, no se convierte en
fallback para una corrida automática: conserva firma y códigos del validador
actual y se reporta al caller para que distinga la causa. El lease coordina uso
de instalación, no reemplaza la autorización administrativa, los modelos o el
flujo existente del adaptador Claude, ni la administración acotada de este ADR.

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
- [3] OpenCode, [carga de plugins y disparo de configuración](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/opencode/src/plugin/index.ts), versión 1.18.29; un fallo de configuración no es evidencia de que el guard se aplicó.
- [4] OpenCode, [fallback de la CLI `run`](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/opencode/src/cli/cmd/run.ts), versión 1.18.29; la instancia efectiva puede diferir del valor preparado.
- [5] OpenCode, [parámetros efectivos de petición de chat](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/opencode/src/session/llm/request.ts), versión 1.18.29; fundamento para observar la petición de la misma instancia.
- Issue #1820: origen y decisiones del mantenedor; #1821--#1827: implementacion y certificacion posteriores.

## Control de cambios

- 2026-10-03: creacion como `aceptado` (issue #1820). Fija perfil opt-in por proyecto, entrada controlada, administracion preautorizada y acotada, ciclo de admision con evidencia, local primero sin promesa de sandbox y compatibilidad/certificacion futura; no implementa permisos ni declara certificacion runtime.
- 2026-10-04: enmienda (issue #1862). Precisa la convención de mantenimiento entre corridas, la recuperación automática solo con terminación demostrable del grafo pertinente, la separación entre metadata global de instalación y controles del consumidor, el guard síncrono sobre la instancia efectiva y el tratamiento no fallback de `CONSENT_REVOKED`; no implementa ni certifica esos mecanismos.
