# Subconjunto autocontenido de JSON Schema para el contrato publicado.
def jtype:
    if type == "object" then "object" elif type == "array" then "array"
    elif type == "string" then "string" elif type == "number" then "number"
    elif type == "boolean" then "boolean" else "null" end;
def pfx($path; $key): if $path == "" then $key else ($path + "." + $key) end;
def validate($schema; $instance; $path):
    [
       (if ($schema | has("type")) and (($schema.type | if type == "array" then index($instance | jtype) == null else . != ($instance | jtype) end)) then "\($path): tipo esperado \($schema.type | tojson), encontrado \($instance | jtype)" else empty end),
      (if ($schema | has("enum")) and (($schema.enum | index($instance)) == null) then "\($path): valor \($instance | tojson) no esta en el vocabulario permitido \($schema.enum | tojson)" else empty end),
      (if ($schema | has("minLength")) and (($instance | jtype) == "string") and (($instance | length) < $schema.minLength) then "\($path): longitud minima \($schema.minLength), encontrado \($instance | length)" else empty end),
      (if ($schema | has("minItems")) and (($instance | jtype) == "array") and (($instance | length) < $schema.minItems) then "\($path): cantidad minima de elementos \($schema.minItems), encontrados \($instance | length)" else empty end),
      (if ($schema | has("pattern")) and (($instance | jtype) == "string") and (($instance | test($schema.pattern)) | not) then "\($path): '\($instance)' no coincide con el patron \($schema.pattern)" else empty end),
      (if ($schema | has("required")) and (($instance | jtype) == "object") then ($schema.required[] as $req | if ($instance | has($req)) then empty else "\(pfx($path; $req)): campo requerido ausente" end) else empty end),
      (if ($schema | has("additionalProperties")) and ($schema.additionalProperties == false) and (($instance | jtype) == "object") then ($instance | keys_unsorted[] as $k | if (($schema.properties // {}) | has($k)) then empty else "\(pfx($path; $k)): propiedad adicional no permitida" end) else empty end),
      (if ($schema | has("properties")) and (($instance | jtype) == "object") then ($schema.properties | keys_unsorted[] as $k | if ($instance | has($k)) then validate($schema.properties[$k]; $instance[$k]; pfx($path; $k))[] else empty end) else empty end),
       (if ($schema | has("items")) and (($instance | jtype) == "array") then (range(0; ($instance | length)) as $i | validate($schema.items; $instance[$i]; pfx($path; ($i | tostring)))[]) else empty end),
       (if ($schema.uniqueItems // false) and (($instance | jtype) == "array") and (($instance | unique | length) != ($instance | length)) then "\($path): elementos duplicados no permitidos" else empty end),
      (if ($schema | has("oneOf")) then (if ($instance | jtype) != "object" then ["\(if $path == "" then "(raiz)" else $path end): se esperaba un objeto JSON, encontrado \($instance | jtype)"] elif ($instance | has("kind")) | not then ["\(pfx($path; "kind")): campo requerido ausente"] else (($schema.oneOf | map(select((.properties.kind.enum // []) | index($instance.kind)))) as $matches | if ($matches | length) == 0 then ["\(pfx($path; "kind")): valor \($instance.kind | tojson) no coincide con ningun 'kind' declarado en oneOf"] else validate($matches[0]; $instance; $path) end) end)[] else empty end)
    ];
validate($schema; $instance; "")
