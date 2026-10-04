# Contrato puro de la matriz de entrada publicada. Entrada:
# {matrix, commands:[{id,body}], agents:[id]}. Salida: catálogo y clausura.
def fail($message): error("command-entry: " + $message);
def required: ["capabilities","composes","delegates","evidence","id","mcp","resources","skills","writeScope"];
def identifier: type == "string" and test("^[a-z0-9]+(-[a-z0-9]+)*$");
def string_set: type == "array" and all(.[]; type == "string") and length == (unique | length);
def directives($body; $name):
  (if $name == "launch-agent" then " [^{}]+" else "" end) as $suffix |
  [$body | scan("\\{\\{mefisto:" + $name + " ([a-z0-9]+(?:-[a-z0-9]+)*)" + $suffix + "\\}\\}") | if type == "array" then .[0] else . end];
def closure($entries; $id; $seen):
  if $seen | index($id) then fail("ciclo de composicion en " + ($seen + [$id] | join(" -> ")))
  else ($entries | map(select(.id == $id)) | .[0]) as $entry |
    if $entry == null then fail("target compuesto inexistente: " + $id)
    else reduce $entry.composes[] as $child ([$entry]; . + closure($entries; $child; $seen + [$id]))
    end
  end;
def union($rows; $field): [$rows[] | .[$field][]] | unique | sort;
def valid_entry($entry_id):
  (type == "object") and (keys | sort) == required and (.id | identifier) and
  (.capabilities | string_set and all(.[]; . == "read" or . == "edit" or . == "shell" or . == "web" or . == "task")) and
  (.composes | string_set and all(.[]; identifier)) and
  (.delegates | string_set and all(.[]; identifier)) and
  (.skills | string_set and all(.[]; identifier)) and
  (.mcp | string_set and all(.[]; identifier)) and
  (.resources | string_set and all(.[]; . == "project" or . == "release" or . == "state" or . == "runtime-tool-output" or . == "nuget-packages")) and
  (.evidence | string_set and . == ["src/published/commands/" + $entry_id + ".md"]) and
  (.writeScope == "none" or .writeScope == "state" or .writeScope == "project") and
  ((.capabilities | index("edit")) != null) == (.writeScope != "none") and
  ((.writeScope == "state") == ((.resources | index("state")) != null));
def command_entry:
  (.matrix.commands) as $entries | (.commands) as $commands | (.agents // []) as $agents |
  if ((.matrix | keys | sort) != ["commands","schemaVersion"] or .matrix.schemaVersion != 1) then fail("matriz invalida")
  elif (($entries | map(.id) | length) != ($entries | map(.id) | unique | length)) then fail("id de matriz duplicado")
  elif (($commands | map(.id) | length) != ($commands | map(.id) | unique | length)) then fail("id de catalogo duplicado")
  elif (($entries | map(.id) | sort) != ($commands | map(.id) | sort)) then fail("ids de matriz y catalogo no coinciden")
  elif any($entries[]; .id as $entry_id | (valid_entry($entry_id) | not)) then fail("fila con campos, tipos o valores invalidos")
  elif any($commands[]; . as $command | ($entries | map(select(.id == ($command | .id))) | .[0]) as $entry | $entry == null or (directives(($command | .body); "command-doc") | unique | sort) != ($entry.composes | sort) or (directives(($command | .body); "launch-agent") | unique | sort) != ($entry.delegates | sort) or (($entry.delegates - $agents) | length) != 0) then fail("referencia de composicion o delegado invalida")
  else {schemaVersion: 1,
   commands: [$entries[] as $entry | (closure($entries; ($entry | .id); []) | unique_by(.id)) as $rows |
     $entry + {closure: {commands: ($rows | map(.id) | sort), delegates: union($rows; "delegates"), capabilities: union($rows; "capabilities"), resources: union($rows; "resources"), skills: union($rows; "skills"), mcp: union($rows; "mcp")}}] | sort_by(.id)} end;
command_entry
