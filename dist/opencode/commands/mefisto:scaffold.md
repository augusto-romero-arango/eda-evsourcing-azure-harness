---
description: "Lanza el pipeline de scaffold para crear un nuevo dominio, opcionalmente asociado a un issue de GitHub."
---
<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/scaffold.md. No editar a mano. -->
```bash
mefisto_opencode_data_root() {
    if [ -n "${XDG_DATA_HOME:-}" ]; then printf '%s/mefisto\n' "$XDG_DATA_HOME"
    elif [ "$(uname -s)" = Darwin ]; then printf '%s/Library/Application Support/mefisto\n' "$HOME"
    else printf '%s/.local/share/mefisto\n' "$HOME"; fi
}
mefisto_opencode_launcher="$(mefisto_opencode_data_root)/active/bin/mefisto-opencode"
if [ ! -f "$mefisto_opencode_launcher" ] || [ -L "$mefisto_opencode_launcher" ] || [ ! -x "$mefisto_opencode_launcher" ]; then
    printf '%s\n' 'ERROR OpenCode: no hay una release activa valida; instale o active la release OpenCode.' >&2; exit 1
fi
MEFISTO_PACKAGE_ROOT="$("$mefisto_opencode_launcher" package-root)" || {
    printf '%s\n' 'ERROR OpenCode: no se pudo resolver la release activa; instale o active la release OpenCode.' >&2; exit 1;
}
case "$MEFISTO_PACKAGE_ROOT" in
    /*) ;;
    *) printf '%s\n' 'ERROR OpenCode: la release activa no devolvio una raiz absoluta; reinstale o active la release OpenCode.' >&2; exit 1 ;;
esac
MEFISTO_PACKAGE_ROOT="$(cd "$MEFISTO_PACKAGE_ROOT" 2>/dev/null && pwd -P)" || {
    printf '%s\n' 'ERROR OpenCode: la release activa no existe; reinstale o active la release OpenCode.' >&2; exit 1;
}
export MEFISTO_PACKAGE_ROOT
```
```bash
if [ -f ".mefisto/harness.config.json" ]; then
    if [ -f ".claude/harness.config.json" ]; then
        printf '%s\n' 'AVISO: se usara el config canonico .mefisto/harness.config.json; se ignora el legacy .claude/harness.config.json. Migra o elimina conscientemente el archivo legacy para evitar divergencias.' >&2
    fi
    MEFISTO_CONFIG_PATH=".mefisto/harness.config.json"
elif [ -f ".claude/harness.config.json" ]; then
    MEFISTO_CONFIG_PATH=".claude/harness.config.json"
else
    printf '%s\n' 'ERROR: no se encontro el config canonico requerido .mefisto/harness.config.json.' >&2
    printf '%s\n' '  Se acepta solo para lectura el fallback legacy .claude/harness.config.json.' >&2
    exit 1
fi
export MEFISTO_CONFIG_PATH
```

Antes de continuar, aborta si existe `src/internal/scripts/generate-internal-adapters.sh`: ese directorio es el repositorio de Mefisto, no un consumidor.

Lanza el pipeline de scaffold para crear un nuevo dominio, opcionalmente asociado a un issue de GitHub. Comunicate en **espanol**.

## Entrada

`$ARGUMENTS` puede ser:
- Un numero de issue: `42`
- Un numero de issue + dominio: `42 calculo-horas`
- Solo dominio (sin issue): `calculo-horas`

Si `$ARGUMENTS` esta vacio, responde: `Uso: /mefisto:scaffold <numero-de-issue> o /mefisto:scaffold <nombre-dominio>`

## Proceso

### 1. Parsear entrada

Analiza `$ARGUMENTS`:
- Si es un numero solo → `ISSUE_NUM=N`, `DOMAIN_NAME=""`
- Si son dos tokens y el primero es numero → `ISSUE_NUM=N`, `DOMAIN_NAME=segundo`
- Si es un string con letras → `ISSUE_NUM=""`, `DOMAIN_NAME=string`

### 2. Si hay issue, validar y extraer info

```bash
gh issue view <issue> --json number,title,state,labels,body -q '"#\(.number): \(.title) [\(.state)] labels: \([.labels[].name] | join(", "))"'
```

Si el issue no existe o esta cerrado (`CLOSED`), informa y detente.

Si no hay `DOMAIN_NAME`, extrae del body la linea `Dominio: nombre-kebab` con una expresion portable (sin `grep -P`, que el `grep` BSD de macOS no admite):

```bash
gh issue view <issue> --json body -q '.body' | sed -n 's/^[[:space:]]*Dominio:[[:space:]]*\([a-z][a-z0-9-]*\).*/\1/p' | head -1
```

### 3. Validar que hay dominio

Si no se pudo determinar el nombre del dominio de ninguna fuente, responde:

```
No se pudo determinar el nombre del dominio.
Opciones:
  /mefisto:scaffold 42 calculo-horas        (issue + dominio explicito)
  /mefisto:scaffold calculo-horas           (dominio sin issue)
  Agregar "Dominio: nombre" al body del issue
```

### 3b. Normalizar a kebab-case

Si el dominio viene en PascalCase (ej: `ControlHoras`), convertirlo a kebab-case (`control-horas`).
Guardar ambas formas: `DOMAIN_NAME_KEBAB` (para el script) y `DOMAIN_NAME_PASCAL` (para verificar directorio).

### 4. Verificar que el dominio no existe

Lee `namespacePrefix` desde `${MEFISTO_CONFIG_PATH}`; es el `<RootNamespace>`. Si la configuracion no es consultable o `namespacePrefix` falta o esta vacio, informa el error y detente. Convierte el dominio a PascalCase (ej: `calculo-horas` -> `CalculoHoras`) y verifica:

```bash
jq -r '.namespacePrefix // empty' "${MEFISTO_CONFIG_PATH}"
test -d "src/<namespacePrefix>.{PascalCase}/"
```

Si ya existe, informa y detente.

### 5. Confirmar con el usuario

Muestra exactamente lo que se va a crear (con `<RootNamespace>` sustituido por `namespacePrefix`) y pregunta:

```
Se va a crear el scaffold del dominio "{domain-name}" ({PascalCase}):

  - Function App:   src/<RootNamespace>.{PascalCase}/
  - Tests:          tests/<RootNamespace>.{PascalCase}.Tests/
  - Smoke Tests:    tests/<RootNamespace>.{PascalCase}.SmokeTests/
  - Terraform:      infra/environments/dev/dominio-{kebab}.tf (archivo propio del dominio)
                    (Service Plan dedicado asp-{kebab}-... + Storage + Function App, MEF-ADR-0020)
  - GitHub Actions: .github/workflows/deploy-{kebab}.yml
                    (+ smoke-tests-dominio.yml y smoke-tests.yml la primera vez en el repo)
  - Smoke tests:    .github/smoke-tests/{kebab}.json (registro propio del dominio)
  - Label:          dom:{kebab}

Issue: #{N} (o "sin issue asociado")

El scaffold se ejecutara en un worktree aislado y creara un PR al terminar.
¿Continuar? (s/n)
```

Si dice no, detente.

### 6. Lanzar el pipeline

Con `DOMAIN_NAME_KEBAB` como dominio confirmado:

```bash
# Con issue:
MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/tmux-pipeline.sh" --scaffold <issue> --domain <dominio-kebab-confirmado>

# Sin issue:
MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/tmux-pipeline.sh" --scaffold --domain <dominio-kebab-confirmado>
```

### 7. Instrucciones de conexion

Dentro de Herdr (`HERDR_ENV=1` en el entorno), el script delega en la interfaz Herdr y no hay nada que adjuntar: el pipeline queda corriendo en un pane de este mismo workspace con el visor en vivo del agente. En ese caso responde con:

```
Pipeline de scaffold corriendo en un pane de este workspace (visor en vivo del agente).
Log: .mefisto/pipeline/logs/scaffold-<timestamp>-<pid>.log
```

Fuera de Herdr responde con:

```
Pipeline de scaffold lanzado en tmux. Para monitorear:
  tmux -CC attach -t scaffold-<dominio>

Log: .mefisto/pipeline/logs/scaffold-<timestamp>-<pid>.log
```

## Reglas

- **No esperes a que termine.** El script corre en background (en un pane Herdr o una sesion tmux). Devuelve el control inmediatamente.
- **No crees el dominio tu mismo.** Solo lanza el script.
- **Nunca crees un dominio sin confirmacion explicita del usuario.** La creacion implica Terraform e infraestructura en Azure.
- Si tmux no esta instalado (y no estas dentro de Herdr), el script lo detecta y muestra el error. No intentes instalarlo.
