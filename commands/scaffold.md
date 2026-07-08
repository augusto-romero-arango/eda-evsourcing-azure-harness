---
model: haiku
---

Lanza el pipeline de scaffold para crear un nuevo dominio, opcionalmente asociado a un issue de GitHub. Comunicate en **espanol**.

## Pre-condicion: cwd != Mefisto

Este skill es del plugin publicado y solo aplica al repo consumidor. Mefisto no crea dominios de negocio. Verifica antes de continuar:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /scaffold no aplica al repo de Mefisto."
    exit 1
fi
```

## Entrada

`$ARGUMENTS` puede ser:
- Un numero de issue: `42`
- Un numero de issue + dominio: `42 calculo-horas`
- Solo dominio (sin issue): `calculo-horas`

Si `$ARGUMENTS` esta vacio, responde: `Uso: /scaffold <numero-de-issue> o /scaffold <nombre-dominio>`

## Proceso

### 1. Parsear entrada

Analiza `$ARGUMENTS`:
- Si es un numero solo → `ISSUE_NUM=N`, `DOMAIN_NAME=""`
- Si son dos tokens y el primero es numero → `ISSUE_NUM=N`, `DOMAIN_NAME=segundo`
- Si es un string con letras → `ISSUE_NUM=""`, `DOMAIN_NAME=string`

### 2. Si hay issue, validar y extraer info

```bash
gh issue view $ISSUE_NUM --json number,title,state,labels,body -q '"#\(.number): \(.title) [\(.state)] labels: \([.labels[].name] | join(", "))"'
```

Si el issue no existe o esta cerrado (`CLOSED`), informa y detente.

Si no hay `DOMAIN_NAME`, extrae del body la linea `Dominio: nombre-kebab`:

```bash
gh issue view $ISSUE_NUM --json body -q '.body' | grep -ioP '(?<=Dominio:\s)[a-z][a-z0-9-]*' | head -1
```

### 3. Validar que hay dominio

Si no se pudo determinar el nombre del dominio de ninguna fuente, responde:

```
No se pudo determinar el nombre del dominio.
Opciones:
  /scaffold 42 calculo-horas        (issue + dominio explicito)
  /scaffold calculo-horas           (dominio sin issue)
  Agregar "Dominio: nombre" al body del issue
```

### 3b. Normalizar a kebab-case

Si el dominio viene en PascalCase (ej: `ControlHoras`), convertirlo a kebab-case (`control-horas`).
Guardar ambas formas: `DOMAIN_NAME_KEBAB` (para el script) y `DOMAIN_NAME_PASCAL` (para verificar directorio).

### 4. Verificar que el dominio no existe

Convierte a PascalCase (ej: `calculo-horas` -> `CalculoHoras`) y verifica:

```bash
test -d "src/<RootNamespace>.{PascalCase}/"
```

Si ya existe, informa y detente.

### 5. Confirmar con el usuario

Muestra exactamente lo que se va a crear y pregunta:

```
Se va a crear el scaffold del dominio "{domain-name}" ({PascalCase}):

  - Function App:   src/<RootNamespace>.{PascalCase}/
  - Tests:          tests/<RootNamespace>.{PascalCase}.Tests/
  - Smoke Tests:    tests/<RootNamespace>.{PascalCase}.SmokeTests/
  - Terraform:      infra/environments/dev/dominio-{kebab}.tf (archivo propio del dominio)
                    (Service Plan dedicado asp-...-{kebab} + Storage + Function App, ADR-0020)
  - GitHub Actions: .github/workflows/deploy-{kebab}.yml
                    (+ smoke-tests-dominio.yml y smoke-tests.yml la primera vez en el repo)
  - Smoke tests:    .github/smoke-tests/{kebab}.json (registro propio del dominio)
  - Label:          dom:{kebab}

Issue: #{N} (o "sin issue asociado")

El scaffold se ejecutara en un worktree aislado y creara un PR al terminar.
¿Continuar? (s/n)
```

Si dice no, detente.

### 6. Lanzar en tmux

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"

# Con issue:
"$PLUGIN_SCRIPTS/tmux-pipeline.sh" --scaffold $ISSUE_NUM --domain $DOMAIN_NAME

# Sin issue:
"$PLUGIN_SCRIPTS/tmux-pipeline.sh" --scaffold --domain $DOMAIN_NAME
```

### 7. Instrucciones de conexion

Responde con:

```
Pipeline de scaffold lanzado en tmux. Para monitorear:
  tmux -CC attach -t scaffold-{domain}

Usa /work-status para ver el progreso sin salir de aqui.
```

## Reglas

- **No esperes a que termine.** El script corre en background dentro de tmux. Devuelve el control inmediatamente.
- **No crees el dominio tu mismo.** Solo lanza el script.
- **Nunca crees un dominio sin confirmacion explicita del usuario.** La creacion implica Terraform e infraestructura en Azure.
- Si tmux no esta instalado, el script lo detecta y muestra el error. No intentes instalarlo.
