Lanza el pipeline de tooling para un issue de GitHub dentro de una sesion tmux. Comunicate en **espanol**.

## Entrada

El numero de issue esta en: $ARGUMENTS

Si `$ARGUMENTS` esta vacio, responde: `Uso: /tooling <numero-de-issue>`

## Proceso

### 1. Validar el issue

```bash
gh issue view $ARGUMENTS --json number,title,state,labels -q '"#\(.number): \(.title) [\(.state)] labels: \([.labels[].name] | join(", "))"'
```

Si el issue no existe o esta cerrado (`CLOSED`), informa y detente.

### 2. Validar que es una tarea de tooling

Extrae labels del issue:

```bash
gh issue view $ARGUMENTS --json labels -q '[.labels[].name] | join(",")'
```

Verifica que tenga el label `tipo:tooling`. Si no lo tiene, advierte al usuario:

```
Este issue no tiene el label tipo:tooling.
Si es logica de dominio, usa /implement en su lugar.
¿Continuar de todos modos? (s/n)
```

### 2.5. Verificar label bloqueado

Si el issue tiene el label `bloqueado`, lee la seccion `## Dependencias` del body y extrae todos los numeros de issue/PR referenciados (patron `#NNN`).

Para cada referencia, consulta su estado:

```bash
gh issue view <num> --json state -q '.state'
gh pr view <num> --json state -q '.state'
```

- Si **todas** las dependencias estan cerradas (`CLOSED`) o mergeadas (`MERGED`): quita el label y continua:

```bash
gh issue edit $ARGUMENTS --remove-label "bloqueado"
```

- Si **alguna** dependencia sigue abierta: muestra cuales y **detente**:

```
El issue #$ARGUMENTS esta bloqueado. Dependencias abiertas:
  - #42: [titulo] (OPEN)
  - #55: [titulo] (OPEN)

Resuelve estas dependencias antes de lanzar el pipeline.
```

### 3. Mostrar info y lanzar

Muestra una linea con el issue:

```
#18: Implementar smoke tests para Service Bus triggers
Tipo: tooling | Estado: listo
```

Luego lanza el pipeline en tmux:

```bash
./scripts/tmux-pipeline.sh --tooling $ARGUMENTS
```

### 4. Instrucciones de conexion

Responde con:

```
Pipeline tooling lanzado en tmux. Para monitorear:
  tmux -CC attach -t tooling-<numero>

Usa /work-status para ver el progreso sin salir de aqui.
```

## Reglas

- **No esperes a que termine.** El script corre en background dentro de tmux. Devuelve el control inmediatamente.
- **No implementes nada tu mismo.** Solo lanza el script.
- Si tmux no esta instalado, el script lo detecta y muestra el error.
