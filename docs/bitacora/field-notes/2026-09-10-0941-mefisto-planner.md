---
fecha: 2026-09-10
hora: 09:41
sesion: mefisto-planner
tema: Bootstrap del consumidor sin créditos Claude y config canónico de infra-base
---

## Contexto

Tras publicar Mefisto v0.37.3, el consumidor privado de certificación completó el bootstrap del backend y de CI OIDC. Al buscar una alternativa sin créditos Claude para generar la infraestructura base, comprobamos que `/infra-base` no tiene un script determinista: delega la escritura inline del HCL al agente `infra-base-scaffolder`.

## Descubrimientos

- La repetición de `setup-github-ci.sh` en v0.37.3 reutilizó la app/SP y dejó exactamente una asignación de cada rol esperado y dos credenciales federadas, sin client secret.
- GitHub Actions quedó con los cuatro nombres de secrets necesarios y la variable `ALERT_EMAIL`; ningún valor sensible se conservó en evidencia.
- `/onboard` pasó a `14 OK`, cero `FALTA` y tres `NO VERIFICADO`; los pendientes eran `src/`, `tests/` y el password de PostgreSQL. Tras configurar este último, solo queda materializar el baseline.
- OpenCode v1.18.29 instaló y activó Mefisto v0.37.3 desde el asset cuyo checksum se validó antes de extraer. El diagnóstico sigue `opencode_only` porque los markers Claude legítimos permanecen en v0.37.2 hasta una sesión nueva.
- El agente `infra-base-scaffolder` todavía leía directamente `.claude/harness.config.json`, pese a que MEF-ADR-0053 declaró `.mefisto/harness.config.json` como contrato canónico.
- El primer reviewer de #1212 quedó huérfano al expirar el timeout externo. Alcanzó a detectar que cada bloque bash independiente debía recomputar `REPO_ROOT` y `CONFIG`; el pipeline se retomó oficialmente desde Stage 2 y conservó esas correcciones.

## Decisiones

- No crear una copia legacy del config en el consumidor: habría ocultado el defecto y debilitado el gate fail-closed de #1180.
- Crear #1212 como bug publicado, enfocado exclusivamente en `/infra-base`, con precedencia canónico/fallback tanto en el agente como en el workflow generado.
- Corregir #1212 mediante el pipeline interno OpenCode. PR #1213 quedó mergeado después de pasar la prueba contractual (`13/0`) y guards (`202/0`).
- Sin créditos Claude, preparar el baseline mediante una ejecución OpenCode one-shot que use la doctrina exacta de una release corregida. Esta ejecución es bootstrap, no evidencia de paridad ni migración formal del catálogo.
- Mantener #1180 bloqueado: MEF-ADR-0053 exige una sesión Claude nueva para actualizar sus markers y obtener diagnóstico `aligned`; no se reescriben a mano.

## Descartado

- Ejecutar solo scripts para reemplazar `/infra-base`: no existe un generador determinista equivalente.
- Portar `/infra-base` formalmente a OpenCode antes del gate: MEF-ADR-0053 sección 6 prohíbe migrar el resto del catálogo antes de certificar el corte vertical `/mefisto:tooling`.
- Alimentar al agente v0.37.3 con una instrucción ad hoc que ignore la ruta legacy: sería un workaround sobre un defecto conocido.

## Preguntas abiertas

- Publicar e instalar el siguiente patch que contenga #1212.
- Ejecutar el agente corregido con OpenCode one-shot, revisar el Terraform y entregar el baseline mediante PR del consumidor.
- La certificación final seguirá esperando créditos Claude para una sesión nueva y los markers de la misma release.

## Referencias

Issues creados: #1212. Issues bloqueados: #1180. PRs: Mefisto #1213; consumidor #1. Releases verificadas: v0.37.3.
