---
fecha: 2026-10-13
hora: 16:14
sesion: mefisto-planner
tema: Politica de cero warnings nuevos (Pragmatic Programmer) como doctrina y proceso
---

## Contexto
El usuario quiere adoptar "tratar warnings como errores" (Hunt & Thomas, The Pragmatic Programmer): cada agente verifica no introducir warnings nuevos y remedia con su mejor criterio; sin bloquear el ciclo, el reviewer como ultima instancia abre un issue con la razon si no logra remediar.

## Descubrimientos
- La doctrina actual es difusa: `reviewer` lista "sin warnings del compilador" como atributo de elegancia; `implementer` corre `dotnet build`; `infra-*` exigen `terraform validate` verde pero ignoran sus warnings; ningun agente tiene salida para un warning no remediado.
- Las bases no estan limpias (shellcheck: 14 warnings + 45 info/style en scripts del repo): "nuevo" solo puede ser diferencial contra el commit base.
- `tdd-pipeline.sh` no expone el commit base a los agentes; tooling/iac si (`SNAPSHOT_COMMIT`).
- Ningun pipeline publicado enlaza hoy issues creados por un agente durante la corrida.

## Decisiones
- Alcance: solo lado consumidor; el pipeline interno de Mefisto queda diferido (decision del usuario).
- Diferencial contra commit base, multiconjunto de claves sin numero de linea, todo el proyecto.
- Helper determinista publicado `scripts/warnings-diff.sh` con baseline cacheado por SHA.
- Shellcheck `-S warning`; dotnet build warnings; `terraform validate -json` severity warning.
- Supresion NO es remediacion (mas estricto que SEI CERT MSC00-C); el helper detecta supresiones nuevas.
- Remanente: issue `estado:borrador` + label nuevo `warning` + tipo/dom del origen, deduplicado; PR lo enlaza via `.mefisto/pipeline/warnings-remanentes.txt`.
- Scaffolders son su propia ultima instancia y crean draft cross-repo en Mefisto.
- No se activa `TreatWarningsAsErrors` en el build.
- Label `warning` creado en el repo de Mefisto.

## Descartado
- Issues del lado interno (helper `mefisto-warnings-diff.sh`, prompts de `mefisto-writer`/`mefisto-reviewer`, `/mefisto-fix-review`).
- Supresion justificada como remediacion valida.
- Issues remanentes naciendo `estado:listo`.

## Preguntas abiertas
- Cuando extender la politica al pipeline interno de Mefisto (requiere limpiar o tolerar la linea base de shellcheck).

## Referencias
Issues creados: #2404, #2405, #2406, #2407, #2408, #2409, #2410, #2411, #2412 (todos estado:borrador, tipo:tooling).
