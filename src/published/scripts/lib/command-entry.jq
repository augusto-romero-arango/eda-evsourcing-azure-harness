# Contrato puro de la matriz de entrada publicada. Entrada:
# {matrix, commands:[{id,body}], agents:[id]}. Salida: catálogo y clausura.
def fail($message): error("command-entry: " + $message);
def required: ["capabilities","composes","delegates","evidence","id","mcp","resources","skills","writeScope"];
def unique_or_fail($label): if length == (unique | length) then . else fail($label + " duplicado") end;
def ids: map(.id);
def directives($body; $name):
  [$body | scan("\\{\\{mefisto:" + $name + " ([a-z0-9]+(?:-[a-z0-9]+)*)") | if type == "array" then .[0] else . end];
def closure($entries; $id; $seen):
  if $seen | index($id) then fail("ciclo de composicion en " + ($seen + [$id] | join(" -> ")))
  else ($entries | map(select(.id == $id)) | .[0]) as $entry |
    if $entry == null then fail("target compuesto inexistente: " + $id)
    else reduce $entry.composes[] as $child ([$entry]; . + closure($entries; $child; $seen + [$id]))
    end
  end;
def union($rows; $field): [$rows[] | .[$field][]] | unique | sort;
def command_entry:
  (.matrix.commands) as $entries | (.commands) as $commands | (.agents // []) as $agents |
  if ((.matrix | keys | sort) != ["commands","schemaVersion"] or .matrix.schemaVersion != 1) then fail("matriz invalida")
  elif (($entries | map(.id) | length) != ($entries | map(.id) | unique | length)) then fail("id de matriz duplicado")
  elif (($commands | map(.id) | length) != ($commands | map(.id) | unique | length)) then fail("id de catalogo duplicado")
  elif (($entries | map(.id) | sort) != ($commands | map(.id) | sort)) then fail("ids de matriz y catalogo no coinciden")
  elif any($entries[]; (keys | sort) != required or (.capabilities | all(. == "read" or . == "edit" or . == "shell" or . == "web" or . == "task") | not) or (.writeScope != "none" and .writeScope != "state" and .writeScope != "project")) then fail("fila con campos o capacidades invalidos")
  elif any($commands[]; . as $command | ($entries | map(select(.id == ($command | .id))) | .[0]) as $entry | $entry == null or (directives(($command | .body); "command-doc") | unique | sort) != ($entry.composes | sort) or (directives(($command | .body); "launch-agent") | unique | sort) != ($entry.delegates | sort) or (($entry.delegates - $agents) | length) != 0) then fail("referencia de composicion o delegado invalida")
  else {schemaVersion: 1,
   commands: [$entries[] as $entry | (closure($entries; ($entry | .id); []) | unique_by(.id)) as $rows |
     $entry + {closure: {commands: ($rows | map(.id) | sort), capabilities: union($rows; "capabilities"), resources: union($rows; "resources"), skills: union($rows; "skills"), mcp: union($rows; "mcp")}}] | sort_by(.id)}
  | . + {fingerprint: ([.commands[] | {id:.id, closure:.closure}] | tojson | @base64)} end;
command_entry
