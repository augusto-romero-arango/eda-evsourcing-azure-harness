# Contrato puro de verificacion de fuentes. Entrada:
# {matrix,registry,roles:[{id,capabilities,mcp}],requiredCases:["role/case"]}.
def fail($message): error("source-verification: " + $message);
def identifier: type == "string" and test("^[a-z0-9]+(-[a-z0-9]+)*$");
def strings: type == "array" and all(.[]; type == "string") and length == (unique | length);
def required_case($role; $case): $case.when == "always" or ((.requiredCases // []) | index($role.id + "/" + $case.caseId) != null);
def option_declared($role; $servers):
  .reference as $reference |
  if .kind == "local-artifact" then (($role.capabilities | index("read")) != null or ($role.capabilities | index("shell")) != null)
  elif .kind == "package-cli" then ($role.capabilities | index("shell") != null)
  elif .kind == "web" then ($role.capabilities | index("web") != null)
  elif .kind == "bundled-mcp" then (($role.mcp | index($reference)) != null and ($servers | map(select(.id == $reference and .provisioning == "bundled")) | length == 1))
  else false end;
def option_external($role; $servers): .reference as $reference | .kind == "external-mcp" and ($role.mcp | index($reference)) != null and ($servers | map(select(.id == $reference and .provisioning == "external")) | length == 1);
def valid_option($servers):
  (type == "object") and (keys | sort) == ["kind","reference"] and
  (.kind == "local-artifact" or .kind == "package-cli" or .kind == "bundled-mcp" or .kind == "external-mcp" or .kind == "web") and
  (.reference | type == "string" and length > 0) and
  (if .kind == "bundled-mcp" then .reference as $reference | ($servers | any(.id == $reference and .provisioning == "bundled"))
   elif .kind == "external-mcp" then .reference as $reference | ($servers | any(.id == $reference and .provisioning == "external"))
   else true end);
def valid_case($servers):
  (type == "object") and (keys | sort) == ["caseId","onMissing","options","subject","when"] and
  (.caseId | identifier) and (.subject | type == "string" and length > 0) and
  (.when == "always" or .when == "conditional") and (.onMissing == "block" or .onMissing == "not-verified") and
  (.options | type == "array" and length > 0 and ([.[] | .kind + "\u001f" + .reference] | length == (unique | length)) and all(.[]; valid_option($servers)));
def valid_row($servers):
  (type == "object") and (keys | sort) == ["cases","evidence","id"] and (.id | identifier) and
  (.evidence | strings) and (.cases | type == "array" and length > 0 and ([.[].caseId] | length == (unique | length)) and all(.[]; valid_case($servers)));
def valid_role: (type == "object") and (keys | sort) == ["capabilities","id","mcp"] and (.id | identifier) and (.capabilities | strings) and (.mcp | strings);
def source_verification:
  . as $input | .matrix.roles as $rows | .roles as $roles | .registry.servers as $servers |
  if ((.matrix | keys | sort) != ["roles","schemaVersion"] or .matrix.schemaVersion != 1) then fail("matriz invalida")
  elif ((.registry | keys | sort) != ["schemaVersion","servers"] or .registry.schemaVersion != 1) then fail("registro MCP invalido")
  elif ($rows | type != "array" or ($rows | map(.id) | length) != ($rows | map(.id) | unique | length)) then fail("ids de matriz duplicados o invalidos")
  elif ($roles | type != "array" or ($roles | map(.id) | length) != ($roles | map(.id) | unique | length)) then fail("ids de frontmatter duplicados o invalidos")
  elif (($rows | map(.id) | sort) != ($roles | map(.id) | sort)) then fail("roles de matriz y frontmatter no coinciden")
  elif (($servers | map(.id) | length) != ($servers | map(.id) | unique | length)) then fail("ids MCP duplicados")
  elif any($roles[]; valid_role | not) then fail("frontmatter invalido")
  elif any($rows[]; valid_row($servers) | not) then fail("fila, caso u opcion invalida")
  elif any(($input.requiredCases // [])[]; type != "string" or test("^[a-z0-9]+(?:-[a-z0-9]+)*/[a-z0-9]+(?:-[a-z0-9]+)*$") | not) then fail("requiredCases invalido")
  elif any(($input.requiredCases // [])[]; . as $required | (any($rows[]; .id as $id | any(.cases[]; ($id + "/" + .caseId) == $required)) | not)) then fail("requiredCase desconocido")
  else {schemaVersion:1,cases: [$rows[] as $row | ($roles | map(select(.id == $row.id)) | .[0]) as $role | $row.cases[] as $case | {id:$row.id,caseId:$case.caseId,when:$case.when,onMissing:$case.onMissing,options:$case.options,evidence:$row.evidence} + {status:(if ($input | required_case($row; $case) | not) then "not-required" elif any($case.options[]; option_declared($role; $servers)) then "declared" elif any($case.options[]; option_external($role; $servers)) then "external-unobserved" else "capability-missing" end)}] | sort_by(.id,.caseId)} end;
source_verification
