# Biblioteca pura para el borde OpenCode, basada en Permission/Wildcard v1.18.29.
# Entrada: {action, home, ...}; salida: {version, policy|rules|decisions, conflicts}.
# Las reglas son arrays ordenados: la ultima coincidencia decide.

def entry_permissions_version: "1";
def _result($body): $body + {version: entry_permissions_version};
def _diag($code; $permission; $index):
  {code: $code, permission: $permission, rule_index: $index};
def _value: if . == "allow" or . == "deny" or . == "ask" then . else null end;
def _legacy_value: if . == true then "allow" elif . == false then "deny" else null end;
def _permission:
  if . == "write" or . == "apply_patch" or . == "patch" then "edit" else . end;
def _home($home):
  gsub("\\\\"; "/")
  | ($home | gsub("\\\\"; "/")) as $h
  | if . == "~" or . == "$HOME" then $h
    elif startswith("~/") then ($h + .[1:])
    elif startswith("$HOME/") then ($h + .[5:])
    else . end;
def _regex_escape:
  if test("^([\\\\.^$|()\\[\\]{}+])$") then "\\" + . else . end;
def _glob_regex:
  reduce (explode[]) as $c
    (""; ($c | [.] | implode) as $s |
      if $s == "*" then . + ".*"
      elif $s == "?" then . + "."
      else . + ($s | _regex_escape) end);
def wildcard_match($pattern; $candidate; $home):
  ($pattern | _home($home)) as $p |
  ($candidate | gsub("\\\\"; "/")) as $c |
  if ($p | endswith(" *")) then
    ($p[0:-2] as $bare | ($c == $bare or ($c | test("^(?s:" + ($p | _glob_regex) + ")$"))))
  else ($c | test("^(?s:" + ($p | _glob_regex) + ")$"))
  end;
def _literal: test("[?*]") | not;
def _prefix:
  if endswith(" *") then {prefix: .[0:-1], optional: true}
  elif (endswith("*") and (.[0:-1] | test("[?*]") | not)) then {prefix: .[0:-1], optional: false}
  else null end;

# Resultado exacto para el subconjunto soportado: null significa disjuncion
# demostrada y unsupported evita aproximar una interseccion de globs.
def _intersection($left; $right; $home):
  ($left | _home($home)) as $l | ($right | _home($home)) as $r |
  if $l == "*" then {pattern: $r}
  elif $r == "*" then {pattern: $l}
  elif $l == $r then {pattern: $l}
  elif ($l | _literal) and ($r | _literal) then null
  elif ($l | _literal) and wildcard_match($r; $l; $home) then {pattern: $l}
  elif ($r | _literal) and wildcard_match($l; $r; $home) then {pattern: $r}
  elif (($l | _prefix) != null and ($r | _prefix) != null) then
    ($l | _prefix) as $lp | ($r | _prefix) as $rp |
    if ($lp.prefix | startswith($rp.prefix)) then {pattern: $l}
    elif ($rp.prefix | startswith($lp.prefix)) then {pattern: $r}
    else null end
  else {unsupported: true} end;
def _contains($outer; $inner; $home):
  (_intersection($outer; $inner; $home)) as $i |
  (($i.pattern // null) == ($inner | _home($home)));

def _rules_from_value($permission; $value; $home):
  ($permission | _permission) as $p |
  if ($value | _value) != null then
    [{permission: $p, pattern: "*", value: ($value | _value), index: 0}]
  elif ($value | type) != "object" then
    [{diagnostic: _diag("policy-not-representable"; $p; 0)}]
  else
    [ $value | to_entries[] |
      {permission: $p, pattern: (.key | _home($home)), value: (.value | _value), index: 0} ]
    | to_entries
    | map(.value + {index: .key})
    | map(if .value == null then {diagnostic: _diag("policy-not-representable"; $p; .index)} else . end)
  end;
def _legacy_rules($tools):
  if (($tools // null) == null) then []
  elif ($tools | type) != "object" then [{diagnostic: _diag("policy-not-representable"; "tools"; 0)}]
  else
    [ $tools | to_entries[] |
      {permission: (.key | _permission), pattern: "*", value: (.value | _legacy_value)} ]
    | to_entries
    | map(.value + {index: .key})
    | map(if .value == null then {diagnostic: _diag("policy-not-representable"; .permission; .index)} else . end)
  end;
def normalize_policy($raw; $home):
  if ($raw | type) != "object" or (($raw.permission // {}) | type) != "object" then
    _result({rules: [], conflicts: [_diag("policy-not-representable"; "permission"; 0)]})
  else
    (_legacy_rules($raw.tools)) as $legacy |
    [ ($raw.permission // {}) | to_entries[] | _rules_from_value(.key; .value; $home)[] ] as $explicit |
    ($legacy + $explicit) as $all |
    ($all | map(select(has("diagnostic")) | .diagnostic)) as $conflicts |
    _result({rules: (if ($conflicts | length) == 0 then ($all | map(select(has("permission")))) else [] end),
             conflicts: $conflicts})
  end;

def _rule_valid:
  (type == "object") and (.permission | type == "string") and
  (.pattern | type == "string") and ((.value | _value) != null);
def _normalize_rule:
  . + {permission: (.permission | _permission)};
def _validate_rules($rules; $permission):
  if ($rules | type) != "array" then [_diag("policy-not-representable"; $permission; 0)]
  else [ range(0; $rules | length) as $i |
         select(($rules[$i] | _rule_valid) | not) |
         _diag("policy-not-representable"; $permission; $i) ]
  end;
def evaluate_rules($rules; $candidates; $home):
  [ $candidates[] as $candidate |
    ($candidate.permission | _permission) as $permission |
    ([ $rules[] | _normalize_rule |
       select(.permission == $permission and wildcard_match(.pattern; $candidate.candidate; $home)) ] | last) as $winner |
    {permission: $permission, decision: ($winner.value // "ask")} ];
def rules_to_map($rules):
  reduce $rules[] as $rule ({}; del(.[$rule.pattern]) + {($rule.pattern): $rule.value});

def compose_policy($managed; $global; $home; $consent):
  normalize_policy($managed; $home) as $m |
  normalize_policy($global; $home) as $f |
  ($m.conflicts + $f.conflicts) as $initial |
  [ $m.rules[] as $mr |
    if $mr.value != "allow" then $mr
    else $mr,
      ($f.rules[] | select(.permission == $mr.permission) as $fr |
       _intersection($mr.pattern; $fr.pattern; $home) as $i |
       if $i == null then empty
       elif $i.unsupported then {diagnostic: _diag("policy-not-representable"; $mr.permission; $fr.index)}
       else $fr + {pattern: $i.pattern,
                   value: (if $fr.value == "ask" and $consent == true then "allow" else $fr.value end)} end)
    end
  ] as $rows |
  ($rows | map(select(has("diagnostic")) | .diagnostic)) as $intersection_conflicts |
  ($rows | map(select(has("permission")))) as $rules |
  ([ $rules[] | .permission ] | unique |
   map(. as $permission |
       select(([$rules[] | select(.permission == $permission)] | length) > 1024) |
       _diag("policy-expansion-limit"; $permission; 1024))) as $limits |
  ($initial + $intersection_conflicts + $limits) as $conflicts |
  _result({policy: (if ($conflicts | length) == 0 then {rules: $rules} else null end), conflicts: $conflicts});

# Un allow de sesion completamente tapado por una regla posterior no es un
# grant efectivo. Los demas deben estar contenidos en un tramo allow gestionado
# sin excepciones posteriores que intersecten su dominio.
def _session_allow_effective($session; $index; $home):
  ($session[$index] | _normalize_rule) as $grant |
  all(range($index + 1; $session | length); . as $later |
      (($session[$later] | _normalize_rule) as $rule |
       (($rule.permission != $grant.permission) or
        ($rule.value == "allow") or
        ((_contains($rule.pattern; $grant.pattern; $home)) | not))));
def _grant_proven($managed; $grant; $home):
  ($grant | _normalize_rule) as $g |
  if ($g.pattern | _literal) then
    (evaluate_rules($managed; [{permission: $g.permission, candidate: $g.pattern}]; $home)[0].decision == "allow")
  else
    any(range(0; $managed | length); . as $i |
      ($managed[$i] | _normalize_rule) as $base |
      ($base.permission == $g.permission and $base.value == "allow" and
       _contains($base.pattern; $g.pattern; $home) and
       all(range($i + 1; $managed | length); . as $later |
          (($managed[$later] | _normalize_rule) as $rule |
           (($rule.permission != $g.permission) or
            ($rule.value == "allow") or
            (_intersection($rule.pattern; $g.pattern; $home) == null))))))
  end;
def certify_session($managed; $session; $required; $consent; $home):
  normalize_policy($managed; $home) as $m |
  if $consent != true then _result({accepted: false, conflicts: [_diag("consent-required"; "consent"; 0)]})
  elif $session == null then _result({accepted: false, conflicts: [_diag("session-not-observed"; "session"; 0)]})
  elif ($required | type) != "array" then _result({accepted: false, conflicts: [_diag("policy-not-representable"; "required"; 0)]})
  else
    (_validate_rules($session; "session")) as $session_conflicts |
    if (($m.conflicts + $session_conflicts) | length) > 0 then
      _result({accepted: false, conflicts: ($m.conflicts + $session_conflicts)})
    else
      ($session | map(_normalize_rule)) as $s |
      evaluate_rules($m.rules; $required; $home) as $base |
      evaluate_rules($m.rules + $s; $required; $home) as $effective |
      ([ range(0; $s | length) as $i | $s[$i] as $grant |
         if $grant.value == "allow" and _session_allow_effective($s; $i; $home) and
            ((_grant_proven($m.rules; $grant; $home)) | not)
         then _diag("session-grant-not-provable"; $grant.permission; $i)
         else empty end ] +
       [ range(0; $required | length) as $i |
         if $base[$i].decision != "allow" then _diag("managed-operation-not-allowed"; ($required[$i].permission | _permission); $i)
         elif $effective[$i].decision != "allow" then _diag("session-operation-not-allowed"; ($required[$i].permission | _permission); $i)
         else empty end ]) as $conflicts |
      _result({accepted: ($conflicts | length == 0), decisions: $effective, conflicts: $conflicts})
    end
  end;

def entry_permissions:
  . as $input | ($input.home // "") as $home |
  if .action == "normalize" then normalize_policy(.policy; $home)
  elif .action == "evaluate" then
    (_validate_rules(.policy.rules; "policy")) as $conflicts |
    _result({decisions: (if ($conflicts | length) == 0 then evaluate_rules(.policy.rules; .candidates; $home) else [] end),
             conflicts: $conflicts})
  elif .action == "serialize" then _result({permission: rules_to_map(.rules), conflicts: []})
  elif .action == "compose" then compose_policy(.managed; .global; $home; (.consent // false))
  elif .action == "certify-session" then certify_session(.managed; .session; .required; .consent; $home)
  else _result({conflicts: [_diag("invalid-action"; "action"; 0)]}) end;
