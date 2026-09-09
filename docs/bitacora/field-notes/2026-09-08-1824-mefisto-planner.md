---
fecha: 2026-09-08
hora: 18:24
sesion: mefisto-planner
tema: procedencia commit de las distribuciones publicadas
---

## Contexto

La continuacion tomo el draft #1126, creado durante el refinamiento de observabilidad, para resolver como pueden Claude y OpenCode exponer un mismo `commit` sin intentar incrustar en un archivo versionado el SHA del commit que contiene ese archivo.

## Descubrimientos

- El pipeline de release ya ofrece una frontera verificable: crea la rama desde `origin/main`, produce cambios mecanicos de release y mergea por squash antes de etiquetar.
- El manifiesto OpenCode usa hoy `git rev-parse HEAD` durante el empaquetado; ese valor seria el commit mecanico etiquetado, no una procedencia embebible en Claude.
- El modelo oficial de Git confirma la circularidad: el commit se crea desde el tree y padres; cambiar un manifiesto dentro del tree cambia el SHA. Fuente: https://git-scm.com/docs/git-commit-tree.
- El generador publicado reclama `dist/<runtime>` completo. El manifiesto Claude debe entrar como asset suplementario de #1104, no escribirse por fuera y quedar huerfano.
- Mientras marketplace apunte a `./`, el diagnostico Claude necesita ademas un mirror raiz. Esa ruta exacta aun no estaba registrada en los gates y debe seguir la secuencia de dos PRs de MEF-ADR-0019.E.

## Decisiones

- `commit` pasa a significar **commit fuente del release**: el `origin/main` exacto del que parte prepare, antes de version/changelog/manifiestos.
- El tag apunta al commit squash mecanico posterior; su padre directo debe ser el commit fuente. Si main avanza o la relacion cambia, publish aborta y exige regenerar.
- El delta entre commit fuente y tag queda limitado a metadata mecanica de release; no puede esconder cambios ejecutables o doctrinales.
- #1126 quedo refinado y `estado:listo` como una enmienda exclusiva de MEF-ADR-0053.
- #1131 generara `dist/claude/mefisto-manifest.json` desde `src/published/release-identity.json`, usando el protocolo de assets suplementarios.
- #1134 hara que el packager OpenCode consuma esa misma identidad en vez de `HEAD`.
- #1135 registrara primero el mirror raiz `mefisto-manifest.json` en ambos gates.
- #1132 actualizara fuente, mirror raiz y salida Claude durante prepare, y verificara ambos manifests y la relacion padre antes del tag.
- #1058, #1059 y #1066 recibieron dependencias explicitas hacia las materializaciones que necesitan.

## Descartado

- SHA del propio commit etiquetado dentro del manifiesto: autorreferencial.
- Usar solo SemVer, nombre de cache, Git del consumidor o una consulta de red por tag: no satisface metadata local verificable.
- Llamar `commit` a un hash de contenido: cambia la semantica pactada y no es un commit Git.
- Crear el manifiesto Claude por fuera del generador: `--check` lo trataria como huerfano.
- Poblar el mirror raiz en el mismo PR que registra el path: se autobloquearia por la regla de carga externa de gates de MEF-ADR-0019.E.

## Preguntas abiertas

- La raiz Claude autocontenida completa y el retarget de marketplace siguen fuera de este corte; el mirror raiz es transitorio mientras `source` sea `./`.
- #1129 aun requiere verificar como obtener el modelo efectivo de una sesion interactiva: `session.created` de OpenCode 1.18.29 no lo incluye en `Session`.

## Referencias

Issues creados: #1131, #1132, #1134 y #1135.

Issues refinados/actualizados: #1126, #1058, #1059 y #1066.
