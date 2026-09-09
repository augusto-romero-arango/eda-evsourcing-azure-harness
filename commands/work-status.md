---
model: haiku
---

Eres un dashboard unificado de los pipelines del consumidor (TDD, Tooling e IaC). Descubre las corridas activas y muestra un panel consolidado. El estado canónico es `.mefisto/pipeline/`; durante el corte vertical también lees `.claude/pipeline/`, sin copiar, migrar ni escribir nada.

## Pre-condicion: cwd != Mefisto

Este skill publicado solo aplica al repositorio consumidor. Para pipelines internos de Mefisto usa `/mefisto-work-status`:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /work-status no aplica al repo de Mefisto. Usa /mefisto-work-status para ver pipelines internos."
    exit 1
fi
```

## Paso 1: Leer y combinar los datos

Define, en este orden fijo, los roots de **solo lectura**:

1. canónico: `.mefisto/pipeline/`;
2. legacy: `.claude/pipeline/`.

No elijas un directorio ni uses uno como sustituto del otro: ambos pueden contener poblaciones activas distintas mientras Tooling migra y TDD/IaC permanecen legacy. Ejecuta en paralelo:

1. `Glob .mefisto/pipeline/pipeline-status-*.json`, luego `Read` cada resultado;
2. `Glob .claude/pipeline/pipeline-status-*.json`, luego `Read` cada resultado;
3. `Read .mefisto/pipeline/pipeline-history.jsonl` y `Read .claude/pipeline/pipeline-history.jsonl` si existen;
4. `Read .mefisto/pipeline/events.log` y `Read .claude/pipeline/events.log` si existen (solo si hay corridas legacy `running` que puedan necesitar fallback de hold);
5. `Bash(date '+%Y-%m-%d %H:%M:%S')`.

Después aplica el fallback **por clase de dato y por root**, sin hacer que la presencia de historial oculte status ni viceversa:

- si un root no tiene status modernos, busca allí `status*.json`, `tooling-status*.json` e `infra-status.json`;
- si un root no tiene historial moderno con contenido, lee allí `history.jsonl`, `tooling-history.jsonl` e `infra-history.jsonl`.

Para un registro antiguo sin `pipeline`, infiere `tdd`, `tooling` o `infra` desde el nombre de su archivo de status **o historial**. Así, los historiales separados antiguos también entran en la combinación.

Conserva el origen de cada registro. Para formar las claves, normaliza `variant` ausente a cadena vacía. Deduplica los status por `(pipeline, issue, variant)`; si existe la misma clave en ambos roots, conserva el canónico. Conserva todos los status disjuntos. Deduplica el historial por `(pipeline, issue, variant, started)` con la misma precedencia canónica y ordena las entradas retenidas de más reciente a más antigua. Las entradas antiguas sin `started` siguen siendo visibles después de las fechadas, preservando entre ellas el orden de más nueva a más vieja de cada archivo. No modifiques ningún archivo durante esta lectura.

### Paso 1b: Hold y actividad

Un status moderno puede declarar su hold estructurado (por ejemplo, causa y próxima sonda). Atribúyelo únicamente a **esa** corrida: nunca propagues un hold estructurado a otra fila, aunque coincidan checkout, issue o runtime. Para una fila `running`, aplica esta prioridad:

1. hold estructurado vigente de su propio status: `EN ESPERA`;
2. solo para un status legacy sin hold estructurado, el fallback textual de `events.log` de **su mismo root**;
3. sin hold: si `updated` lleva más de 35 minutos sin cambiar, `SIN NOVEDADES`;
4. en otro caso, muestra el stage normal.

El fallback textual es exclusivamente legacy. En la cola del `events.log` legacy busca la última línea `[HH:MM:SS][hold] <FAMILIA>: esperando, proxima sonda HH:MM:SS (techo HH:MM)`, ignorando `[hold][resume]`. Si la hora del anuncio es futura o la próxima sonda ya pasó, no está activo. Traduce `RATE_LIMIT` como `limite de uso` y `PROVIDER_UNAVAILABLE` como `proveedor caido`.

Ese texto no identifica de forma fiable corrida ni runtime: aplícalo únicamente cuando haya **una sola** fila legacy `running` elegible en ese root. Si hay dos o más, no atribuyas el hold textual a ninguna; conserva el stage o aplica `SIN NOVEDADES`. Nunca lo uses para una fila canónica ni para propagar una espera entre runtimes. `SIN NOVEDADES` conserva prioridad posterior al hold.

## Paso 2: Generar el dashboard

Ancho máximo 78 columnas y únicamente ASCII (`-`, `|`, `+`). Encabezado:

```
Work Status - {{fecha hora}}
```

En cada fila muestra `pipeline`, `issue` (sufija `/{{variant}}` cuando exista), título truncado, `runtime`, stage y tiempo. `runtime` se muestra tal como viene en status/history; cuando falta, muestra `-`. Nunca lo infieras desde modelo, path, extensión o proveedor.

```
+----------------------------------------------------------------------------+
| EN CURSO  N pipelines activos                                               |
+----------------------------------------------------------------------------+
|  TOOLING  #18/a  Migrar runner neutral  opencode  EN ESPERA       12m 40s  |
|  TDD      #42    Registrar marcacion   -         IMPLEMENTER       3m 20s |
+----------------------------------------------------------------------------+
```

Para `running`, `EN ESPERA` reemplaza el stage y muestra debajo causa, próxima sonda y techo; `SIN NOVEDADES` reemplaza el stage. Si solo hay una corrida activa y no está en espera ni sin novedades, muestra barra de progreso: TDD (`test-writer` 10%, `implementer` 40%, `smoke-test-writer` 55%, `reviewer` 70%, `coverage-gate` 90%), Tooling (`writer` 25%, `reviewer` 70%) e Infra (`infra-writer` 30%, `infra-reviewer` 80%). `projection-test-writer` y `projection-implementer` usan los porcentajes TDD equivalentes.

Incluye los `failed` en el panel. Si no hay `running` ni `failed`, muestra la última entrada del historial deduplicado. Muestra hasta cinco entradas del historial reciente deduplicado, con pipeline, issue/variante, runtime, resultado, duración y detalle (tests, ambiente o PR). Si no existe ningún status ni historial en ambos roots, muestra `(sin pipelines registrados)`; si existe estado pero no historial, muestra `  (sin pipelines completados aun)`. Los formatos antiguos sin `variant` o `runtime` siguen siendo válidos y se presentan con `-` para runtime.

## Paso 3: Responder preguntas (drill-down)

Primero usa el path `log` declarado en el status o la entrada del historial seleccionada. Respeta literalmente paths entrecomillados, incluidos espacios. Para errores, usa `last_error` y luego `Read <log declarado>` con un offset cercano al final.

Solo si falta `log` o ese `Read` no existe, reconstruye el nombre legacy a partir de `pipeline`, `stage`, `started`, `issue` y `variant`; prueba el mismo nombre primero bajo `.mefisto/pipeline/logs/` y después bajo `.claude/pipeline/logs/`. Patrones legacy: TDD `stage-{N}-{agent}-{TIMESTAMP}-issue-{N}.log`, Tooling `tooling-stage-{N}-{agent}-{TIMESTAMP}.log`, Infra `iac-stage-{N}-{agent}-{TIMESTAMP}.log`.

Para una corrida neutral en vuelo, si el log legible aún no existe, remite al `*.events.jsonl` hermano del log declarado o reconstruido y léelo como eventos normalizados. No intentes interpretar `*.stream.jsonl`, stderr ni salida raw de OpenCode o Claude desde este comando. Para duración y PR usa los campos `agents` y `pr` del status o historial. Si el usuario no especifica issue, usa el activo o el historial más reciente; si hay varios activos ambiguos, pide el issue/variante.

Responde en español, conciso, con listas o tablas cuando aplique.
