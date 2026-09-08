---
fecha: 2026-09-06
hora: 23:39
sesion: mefisto-planner
tema: modelos alternativos para OpenCode
---

## Contexto
Se consulto que proveedores y modelos de codificacion distintos de OpenAI y Anthropic admite OpenCode, y cuales son alternativas competitivas.

## Descubrimientos
- La documentacion oficial de OpenCode declara soporte para mas de 75 proveedores mediante AI SDK y Models.dev, ademas de modelos locales y proveedores personalizados compatibles con la API de OpenAI.
- El catalogo actual de OpenCode Zen incluye familias de Google, xAI, Alibaba/Qwen, DeepSeek, Moonshot AI, MiniMax, Z.AI y NVIDIA, entre otras.
- Para trabajo agente no basta con generar codigo: el soporte fiable de tool calling es un criterio central indicado por la propia documentacion de OpenCode.
- OpenCode Zen factura por tokens y no ofrece tarifa plana. Las suscripciones integrables revisadas se concentran en planes de coding de Google, Kimi, Qwen, GLM, MiniMax y Mistral; DeepSeek directo se mantiene principalmente como API por consumo.
- Una suscripcion de aplicacion web no implica acceso API ni compatibilidad con OpenCode: el plan debe entregar OAuth o una API key utilizable por el runtime.
- El historial local de agosto de 2026 cubre 147 corridas de pipeline, 133 issues unicos y 278 stages con metricas: 126.743 tokens de entrada directa, 34.497.509 de creacion de cache, 733.718.532 de lectura de cache y 8.012.900 de salida; costo API equivalente registrado: USD 627,06.
- El 95,5% de los tokens de prompt fueron lecturas de cache. Por ello, una comparacion de proveedor tiene que mostrar dos escenarios: conservar un cache hit equivalente frente a cobrar todo el prompt como entrada normal.

## Decisiones
- Presentar por separado fabricantes de modelos, proveedores de inferencia/gateways y ejecucion local para evitar confundir modelo con canal de acceso.
- Recomendar evaluar Gemini, Kimi, Qwen, DeepSeek, GLM, MiniMax y Grok por perfil `fast|balanced|deep`, sin afirmar un ranking universal.
- Estimar costos mediante replay fijo de tokens, sin afirmar que otro modelo producira el mismo numero de turnos o tokens: la calidad y eficiencia agente deben medirse en un piloto real.

## Descartado
- No se creo ningun issue: la consulta es informativa y no identifica un cambio necesario en Mefisto.
- No se considero que la mera presencia de un modelo en un catalogo pruebe paridad de calidad con OpenAI o Anthropic.

## Preguntas abiertas
- Falta definir si el objetivo concreto prioriza calidad maxima, costo, latencia, privacidad o ejecucion local.
- Una seleccion definitiva requiere una prueba sobre los pipelines y repositorios reales del mantenedor.

## Referencias
Issues creados: ninguno.

- https://opencode.ai/docs/models/
- https://opencode.ai/docs/providers/
- https://opencode.ai/docs/zen/
- MEF-ADR-0049
