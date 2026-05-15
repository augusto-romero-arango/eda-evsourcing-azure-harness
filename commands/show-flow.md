# Skill: show-flow

Visualiza un flujo EDA como sequence diagram de Eraser. Lee el YAML del flujo, genera el DSL de Eraser y renderiza el diagrama.

## Uso

```
/show-flow <nombre-del-flujo>
```

Donde `<nombre-del-flujo>` es el nombre del archivo sin extensión en `architecture/flows/`.
Ejemplo: `/show-flow calcular-horas-empleado`

Si no se especifica nombre, lista los flujos disponibles.

## Paso 1 - Verificar flujos disponibles

```bash
ls docs/eda/flows/ 2>/dev/null || echo "No hay flujos en docs/eda/flows/"
```

Si no se especificó nombre o el archivo no existe, muestra los disponibles y pide que elija uno.

## Paso 2 - Leer el flujo

Lee el archivo `docs/eda/flows/<nombre>.yaml`.

## Paso 3 — Generar el DSL de Eraser (sequence diagram)

Traduce los steps del YAML a la sintaxis de Eraser sequence diagrams:

**Reglas de traducción:**
- Cada `context` del flujo se convierte en un participante (columna)
- Los actores externos también son participantes
- Un `command` se muestra como: `Actor > Dominio: NombreComando`
- Un `event` interno (sin `published_to`) se muestra como: `Dominio --> Dominio: NombreEvento`
- Un `event` con `published_to` (cross-context) se muestra como:
  ```
  Dominio > "Service Bus" [icon: azure-service-bus]: NombreEvento
  "Service Bus" > OtroDominio: NombreEvento
  ```
- Una `policy` se muestra como una nota: `Dominio --> Dominio: [Policy] NombrePolicy`
- Los activations (`activate`/`deactivate`) envuelven el procesamiento dentro de un dominio

**Iconos disponibles para dominios:**
- Dominios .NET: `azure-functions`
- Service Bus: `azure-service-bus`
- Actor externo/reloj: `monitor`
- Usuario: `user`

**Ejemplo de DSL para un flujo EDA:**

```
typeface clean
colorMode pastel

RelojBiometrico [icon: monitor] > Depuracion [icon: azure-functions]: RegistrarMarcaciones
activate Depuracion
Depuracion --> Depuracion: MarcacionesRegistradas
Depuracion --> Depuracion: [Policy] DepuracionAutomatica
Depuracion --> Depuracion: MarcacionesDepuradas
Depuracion > "Service Bus" [icon: azure-service-bus]: MarcacionesDepuradas
deactivate Depuracion
"Service Bus" > CalculoHoras [icon: azure-functions]: MarcacionesDepuradas
activate CalculoHoras
CalculoHoras --> CalculoHoras: HorasCalculadas
deactivate CalculoHoras
```

## Paso 4 — Renderizar con Eraser API

```bash
curl -s -X POST https://app.eraser.io/api/render/elements \
  -H "Content-Type: application/json" \
  -H "X-Skill-Source: claude" \
  -H "Authorization: Bearer ${ERASER_API_TOKEN}" \
  -d "{
    \"elements\": [{
      \"type\": \"diagram\",
      \"id\": \"flow-diagram\",
      \"code\": \"<DSL_GENERADO>\",
      \"diagramType\": \"sequence-diagram\"
    }],
    \"scale\": 2,
    \"theme\": \"dark\",
    \"background\": true
  }"
```

## Paso 5 — Mostrar resultado

Muestra:

```
## Flujo: <nombre>

## Diagrama
![<nombre del flujo>](<imageUrl de la respuesta>)

## Editar en Eraser
[Abrir editor](<createEraserFileUrl de la respuesta>)

## DSL generado
\`\`\`eraser
<el DSL>
\`\`\`
```

Si el API falla por falta de token (`ERASER_API_TOKEN` no está configurada), muestra el DSL igualmente y explica que se puede pegar en https://app.eraser.io para renderizarlo manualmente.
