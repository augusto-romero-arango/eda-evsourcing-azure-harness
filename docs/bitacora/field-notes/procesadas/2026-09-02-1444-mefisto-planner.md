---
fecha: 2026-09-02
hora: 14:44
sesion: mefisto-planner
tema: Refinar drafts #826 y #827 (deriva skill/agente de /scaffold-mcp y regresiones del modulo apim-mcp-api)
---

## Contexto
Dos drafts creados desde el consumidor Bitakora.ControlAsistencia (planner publicado, field notes 2026-09-02-1056) tras la salida de 0.35.0: #826 (el skill `/scaffold-mcp` informa el alcance de 0.34.0 aunque el agente ya genera identidad/OAuth app-side, #819) y #827 (el modulo `apim-mcp-api` de `apim-gateway-scaffolder`, reconstruido sin acceso al pionero, regresiona cuatro trampas que el pionero ya habia pagado). Se pidio llevarlos a `estado:listo`.

## Descubrimientos
- **Deriva estructural skill/agente**: los skills con bloque "1. Informar que se va a generar" (`scaffold-mcp`, `scaffold-projections`) duplican en prosa la lista de artefactos del agente. Sin fuente unica declarada, cada extension del agente exige recordar tres lugares (parrafo de apertura del skill, bloque Informar, fila del catalogo en `CLAUDE.md`). Decision: mantener la lista + frase explicita "lista canonica = parrafo *Alcance* del agente"; guard automatico descartado (prosa contra prosa).
- **Pinnear version del plugin**: `.claude/pipeline/.plugin-root` (hook SessionStart) + `jq -r .version $PLUGIN_ROOT/.claude-plugin/plugin.json` basta para que un skill informe con que version corre; util para issues del consumidor que dependen del alcance de un scaffold.
- **Orden de hijos de `validate-jwt`** verificado en Microsoft Learn (policy statement): `openid-config -> issuer-signing-keys -> decryption-keys -> audiences -> issuers -> required-claims`. B6 de MEF-ADR-0032 esta bien para login (sin `audiences`); el error fue extrapolar "issuers -> audiences" a la variante MCP/Connect.
- **Reconstruir HCL sin el repo de referencia es caro**: las cuatro regresiones de #827 son invisibles para `validate`/`plan` (orden XSD, hostname regionalizado, concatenacion de sufijo del wildcard, key inexistente hasta el primer deploy). El pionero ya tenia cada una documentada en comentarios del infra-reviewer. Con el clon local disponible (`../Bitakora.ControlAsistencia`), el diff tomo minutos.
- La forma de `azapi_resource_action` aplicada por el pionero (`Microsoft.Web/sites/host@2023-12-01` + `resource_id .../host/default` + `action = "listkeys"` + `method = "POST"`) difiere de la que Mefisto verifico solo contra el registry (`Microsoft.Web/sites@2024-04-01` + `action = "host/default/listkeys"`). Se adopta la aplicada.

## Decisiones
- #826: un solo issue con (a) alinear las listas y (b) imprimir la version del plugin, acotado a `/scaffold-mcp`; incluye la fila del catalogo de `CLAUDE.md`. Se implemento y mergeo (PR #828) durante la misma sesion.
- #827: un solo issue (el usuario descarto separar). La nota "NO VERIFICADO" del path del PRM con punto inicial se reduce de forma determinista al unico punto sin evidencia, citando el issue #575 del pionero (abierto, sin apply) como la corrida que lo cerrara; el punto del `<rewrite-uri>` se da por verificado porque es la misma mecanica que el pionero aplico.
- Se conserva del lado de Mefisto el PRM compartido por servidor (RFC 9728 seccion 3.1) y los outputs `resource_uri`/`prm_url`; no se adopta del pionero su PRM como API propia, `prm_path`, `resource_audience` ni `protocol_methods`.

## Descartado
- Issue transversal de "imprimir version del plugin" en todos los scaffolders (el usuario prefirio acotarlo a `/scaffold-mcp`).
- Que `mcp-scaffolder` registre la version en el README generado (segundo componente).
- Guard de deriva skill<->agente en `test-guards.sh`.
- Draft aparte `bloqueado` para cerrar el NO VERIFICADO del path del PRM (absorbido en #827).
- Unificar el `on-error` (`error="invalid_token"`) con el del pionero: ambos validos, fuera de alcance.

## Preguntas abiertas
- Si APIM acepta `path = ".well-known/oauth-protected-resource"` (punto inicial + barra interna) sigue sin evidencia hasta que #575 del pionero aplique. Si lo rechaza, la salida documentada es path sin punto + `<rewrite-uri>` equivalente.
- `scaffold-projections` tiene el mismo patron de bloque "Informar"; no se detecto deriva hoy, pero no hay mecanismo que la prevenga.

## Referencias
Issues refinados: #826 (cerrado por PR #828), #827 (`estado:listo`)
Issues creados: ninguno
