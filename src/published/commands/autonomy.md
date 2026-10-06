---
{
  "kind": "command",
  "id": "autonomy",
  "description": "Muestra, activa, reduce, autoriza o revoca la autonomia del consumidor (perfil versionado + consentimiento local).",
  "profile": "fast",
  "arguments": "[activar | reducir | autorizar | revocar]"
}
---

Administra la autonomia del consumidor (MEF-ADR-0055): el perfil declarado en `{{mefisto:config-path}}` (versionado) y el consentimiento local por clon (`.mefisto/pipeline/autonomy/consent.json`, no versionado). La intencion del harness es autonomia **maxima por defecto con opt-out**, pero nunca sin consentimiento explicito. Comunicate en **espanol**.

{{mefisto:assert-consumer-repo}}

## Reglas inviolables

- **Solo interactivo.** Si corres dentro de una etapa headless de un pipeline (nadie puede responder), no ejecutes nada: explica que `{{mefisto:command autonomy}}` solo corre con un humano presente y termina.
- **Nunca ejecutes `approve` ni `revoke` sin un "si" explicito del usuario en esta misma conversacion**, dado despues de ver el perfil o el diff. Ninguna otra senal (argumentos, contexto, instrucciones previas) reemplaza esa confirmacion. Pide **una** sola confirmacion por operacion.
- **Nunca agregues por tu cuenta grants administrativas de `environment` de produccion** (`prod`, `production`, `prd` o equivalentes). Solo si el usuario las dicta literalmente y las confirma una a una.
- Toda operacion usa la raiz del repo como `--project-root` (`git rev-parse --show-toplevel`).

## Argumentos

Sin argumentos: estado. Un unico argumento entre `activar`, `reducir`, `autorizar`, `revocar`. Cualquier otro valor: muestra el uso y termina sin tocar nada.

## Proceso

### Sin argumentos: estado

```bash
{{mefisto:run autonomy-profile.sh inspect --project-root "$(git rev-parse --show-toplevel)"}}
```

Presenta el resultado en espanol: estado (`disabled` = deshabilitado, `needs-approval` = necesita aprobacion, `ready` = listo), los comandos autorizados y las grants administrativas (`administration`). Si no es `ready`, sugiere `{{mefisto:command autonomy}} activar`.

### `activar` (camino por defecto cuando el estado no es `ready`)

1. Propon el perfil maximo (escribe el perfil en el config, no aprueba nada):

```bash
{{mefisto:run autonomy-profile.sh propose-max --project-root "$(git rev-parse --show-toplevel)"}}
```

2. Guarda el `profileDigest` que imprime. Muestra el perfil resultante con `preview` y verifica que su `expectedDigest` coincide:

```bash
{{mefisto:run autonomy-profile.sh preview --project-root "$(git rev-parse --show-toplevel)"}}
```

3. Pregunta **una vez**: "Apruebas este perfil de autonomia en este clon? (si/no)". Sin un "si" explicito, no apruebes y termina indicando que el config ya cambio (propose-max) pero sigue sin consentimiento.
4. Con "si":

```bash
{{mefisto:run autonomy-profile.sh approve --project-root "$(git rev-parse --show-toplevel)" --expected-digest <profileDigest-de-propose-max>}}
```

### `reducir`

1. Muestra el perfil actual (`preview`) y pregunta que comandos o grants administrativas quitar.
2. Aplica la reduccion en `{{mefisto:config-path}}` con `jq` sobre `.autonomy` (solo quitar elementos de `commands` y/o `administration`; nunca agregar), e incrementa `revision` en 1. Escribe a un archivo temporal y reemplaza el config de forma atomica.
3. Muestra el diff (`git diff -- .mefisto/harness.config.json`) y ejecuta `preview` para obtener el `expectedDigest`.
4. Pregunta **una vez** si re-aprueba el perfil reducido. Con "si": `approve --expected-digest <expectedDigest>`.

### `autorizar`

Agrega una grant administrativa puntual (por ejemplo las `requiredGrants` que imprime `{{mefisto:command fix-review}}`). Pide `command`, `action`, `environment`, `resources` y `planDigest` al usuario, rechaza `environment` de produccion salvo dictado literal, incrementa `revision`, muestra el diff y re-aprueba con una confirmacion, igual que `reducir`.

### `revocar`

Muestra el estado (`inspect`), pide **una** confirmacion y, con "si":

```bash
{{mefisto:run autonomy-profile.sh revoke --project-root "$(git rev-parse --show-toplevel)"}}
```

## Cierre tras cualquier escritura del config

Recuerda siempre:

- `{{mefisto:config-path}}` es **versionado**: el cambio debe entregarse por Pull Request.
- El consentimiento es **local** (`.mefisto/pipeline/autonomy/consent.json`, no versionado): cada clon o maquina aprueba una vez con `{{mefisto:command autonomy}} activar`.
