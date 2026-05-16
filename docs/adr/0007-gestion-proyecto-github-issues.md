# ADR-0007: Gestion de proyecto con GitHub Issues

**Fecha**: 2026-04-02  
**Estado**: Aceptado

---

## Contexto

El proyecto tenia la gestion de GitHub completamente sin configurar: sin labels propios, sin templates, sin convenciones de titulos. El resultado era naming inconsistente (EMP001, prefijos aleatorios), falta de visibilidad sobre dependencias entre issues, y no habia forma de capturar ideas rapidamente sin pasar por el proceso completo de refinamiento del planner.

El proyecto es de un solo desarrollador en fase de exploracion y aprendizaje. La solucion debe ser **liviana** — no debe demandar planificacion a largo plazo ni introducir herramientas de gestion que generen mas overhead que valor.

---

## Decision

### 1. Labels dimensionales (4 ejes + especiales)

Reemplazar los 9 labels default de GitHub con un esquema por facetas:

- **Tipo** — indica el pipeline de implementacion (`tipo:feature`, `tipo:infra`, `tipo:refactor`, `tipo:tooling`)
- **Origen** — indica por que existe el issue (`bug`)
- **Dominio** (`dom:programacion`, `dom:contracts`, `dom:asistencia`, + nuevos conforme crecen)
- **Estado** (`estado:borrador`, `estado:listo`)
- **Especiales** (`bloqueado`, `epic`)

El label `bug` es ortogonal al `tipo:`: un issue de bug siempre lleva un `tipo:` que indica que pipeline lo implementa (ej: `bug` + `tipo:refactor` + `dom:asistencia`).

### 2. Convencion de titulos sin prefijos

Formato: `[verbo en infinitivo] [que cosa]`

El numero del issue es el identificador. No se usan prefijos como EMP001, PROG-, HU-, feat:.

### 3. Task Graph con mecanismos nativos de GitHub

Sin GitHub Projects (overhead excesivo para solo dev). En cambio:

- Issues `epic` con task lists que referencian sub-issues → GitHub muestra progreso automatico
- Seccion "Dependencias" en el body de cada issue → GitHub crea links bidireccionales
- Label `bloqueado` como semaforo → el planner lo gestiona al crear y al revisar el backlog

### 4. Flujo borrador -> listo

- `/draft [idea]` — crea issue `estado:borrador` sin friccion, sin preguntas
- Planner modo `refinar` — refina el borrador con contexto tecnico, lo eleva a `estado:listo`
- El pipeline TDD/IaC solo procesa issues `estado:listo` (por convencion, no por codigo)

---

## Alternativas consideradas

**GitHub Projects**: descartado. Funciona bien para equipos, pero para un solo developer en exploracion es overhead puro. La visibilidad que aporta se puede obtener con `gh issue list` y labels.

**Milestones**: descartados. Implican planificacion temporal que no aplica en esta fase.

**Prefijos en titulos** (EMP001, feat:): descartados. Los labels cumplen la funcion de categorizar. El numero del issue ya es el identificador unico.

---

## Consecuencias

- El planner es responsable de asignar labels consistentemente al crear issues
- Issues `estado:borrador` no deben enviarse al pipeline TDD/IaC — son borradores, no estan refinados
- Cuando se crea un nuevo dominio con `domain-scaffolder`, se debe agregar su label `dom:X` a GitHub con `gh label create`
- El flujo de trabajo correcto es: brain dump con `/draft` → refinamiento con planner → implementacion con pipeline
