# Validador versionado del mapping abierto runtime -> {profiles, agents}.
def issue($path; $reason): "\($path): \($reason)";
def model_errors($path):
  if type != "string" then [issue($path; "se esperaba un string no vacio")]
  elif length == 0 then [issue($path; "se esperaba un string no vacio")]
  else [] end;
if type != "object" then
  [issue("."; "se esperaba un objeto")]
else
  [to_entries[]
   | .key as $runtime | .value as $config
   | if ($runtime | test("^[a-z0-9_]+$") | not) then
       issue($runtime; "id de runtime invalido")
     elif ($config | type) != "object" then
       issue($runtime; "se esperaba un objeto")
     else
       ([ $config | keys_unsorted[] | select(. != "profiles" and . != "agents")
          | issue("\($runtime).\(.)"; "campo desconocido") ]
        + (if ($config | has("profiles") | not) then []
           elif ($config.profiles | type) != "object" then [issue("\($runtime).profiles"; "se esperaba un objeto")]
           else [ $config.profiles | to_entries[]
                  | .key as $profile | .value
                  | if ($profile != "fast" and $profile != "balanced" and $profile != "deep")
                    then issue("\($runtime).profiles.\($profile)"; "perfil desconocido")
                    else model_errors("\($runtime).profiles.\($profile)")[] end ]
           end)
        + (if ($config | has("agents") | not) then []
           elif ($config.agents | type) != "object" then [issue("\($runtime).agents"; "se esperaba un objeto")]
           else [ $config.agents | to_entries[] | .key as $agent | .value
                  | model_errors("\($runtime).agents.\($agent)")[] ]
           end))[]
     end]
end | .[]
