# Biblioteca pura para el borde OpenCode, basada en Permission/Wildcard v1.18.29.
# Entrada: {action, home, ...}; salida: {version, policy|rules|decisions, conflicts}.
# Las reglas son arrays ordenados: la ultima coincidencia decide.

def entry_permissions_version: "1";
def _result($body): $body + {version: entry_permissions_version};
def _diag($code; $permission; $index):
  {code: $code, permission: $permission, rule_index: $index};
def _value: if . == "allow" or . == "deny" or . == "ask" then . else null end;
def _legacy_value: if . == true then "allow" elif . == false then "deny" else null end;
def _home($home):
  gsub("\\\\"; "/")
  | if . == "~" then $home
    elif startswith("~/") then ($home + .[1:])
    elif startswith("$HOME/") then ($home + .[5:])
    else . end;
def _regex_escape:
  gsub("([\\\\.^$|()\\[\\]{}+])"; "\\\\\\\\\\1");
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
def _rules_from_map($permission; $map; $start; $home):
  if ($map | type) != "object" then
    [{diagnostic: _diag("policy-not-representable"; $permission; $start)}]
  else (([ $map | to_entries[] | {permission: $permission, pattern: (.key | _home($home)), value: (.value | _value)} ]
       | to_entries | map(. as $entry | $entry.value + {index: ($start + ($entry.key | tonumber))})
       | map(if .value == null then {diagnostic: _diag("policy-not-representable"; $permission; .index)} else . end)))
  end;
def _legacy_rules($tools; $home):
  if (($tools // null) == null) then []
  elif ($tools | type) != "object" then [{diagnostic: _diag("policy-not-representable"; "tools"; 0)}]
  else (([ $tools | to_entries[] | {permission: (if (.key == "write" or .key == "edit" or .key == "patch") then "edit" else .key end), pattern: "*", value: (.value | _legacy_value)} ]
       | to_entries | map(. as $entry | $entry.value + {index: ($entry.key | tonumber)})
       | map(if .value == null then {diagnostic: _diag("policy-not-representable"; .permission; .index)} else . end)))
  end;
def normalize_policy($raw; $home):
  (_legacy_rules($raw.tools; $home)) as $legacy |
  if (($raw.permission // {}) | type) != "object" then
    _result({rules: [], conflicts: [_diag("policy-not-representable"; "permission"; 0)]})
  else
    [ ($raw.permission // {}) | to_entries[] | _rules_from_map(.key; .value; 0; $home)[] ] as $explicit |
    # Permission explicito se coloca despues de tools legacy por permiso.
    ($legacy + $explicit) as $all |
    _result({rules: ($all | map(select(has("permission")))), conflicts: ($all | map(select(has("diagnostic")) | .diagnostic))})
  end;
def evaluate_rules($rules; $candidates; $home):
  [ $candidates[] as $candidate |
    ([ $rules[] | select(.permission == $candidate.permission and wildcard_match(.pattern; $candidate.candidate; $home)) ] | last) as $winner |
    {permission: $candidate.permission, decision: ($winner.value // "ask")} ];
def rules_to_map($rules):
  reduce $rules[] as $rule ({}; del(.[$rule.pattern]) + {($rule.pattern): $rule.value});
def _grant_proven($managed; $grant; $home):
  if ($grant.pattern | _literal) then
    (evaluate_rules($managed; [{permission: $grant.permission, candidate: $grant.pattern}]; $home)[0].decision == "allow")
  else
    any(range(0; ($managed | length)); . as $i |
      $managed[$i] as $base |
      ($base.permission == $grant.permission and $base.value == "allow" and
       ((_intersection($base.pattern; $grant.pattern; $home).pattern // "") == ($grant.pattern | _home($home))) and
       all(range($i + 1; ($managed | length)); . as $later |
          (_intersection($managed[$later].pattern; $grant.pattern; $home) == null))))
  end;
def compose_policy($managed; $global; $home):
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
       else $fr + {pattern: $i.pattern} end)
    end
  ] as $rows |
  ($rows | map(select(has("diagnostic")) | .diagnostic)) as $conflicts |
  ($rows | map(select(has("permission")))) as $rules |
  ([ $rules[] | .permission ] | unique) as $permissions |
  ($permissions | map(. as $permission | select(([$rules[] | select(.permission == $permission)] | length) > 1024))) as $over |
  _result({policy: {rules: $rules}, conflicts: ($initial + $conflicts + ($over | map(_diag("policy-expansion-limit"; .; 1024))))});
def certify_session($managed; $session; $required; $consent; $home):
  normalize_policy($managed; $home) as $m |
  if $consent != true then _result({accepted: false, conflicts: [_diag("consent-required"; "consent"; 0)]})
  elif $session == null then _result({accepted: false, conflicts: [_diag("session-not-observed"; "session"; 0)]})
  else
    evaluate_rules($m.rules; $required; $home) as $base |
    evaluate_rules($session; $required; $home) as $seen |
    ([ range(0; ($session | length)) as $i | $session[$i] as $grant |
       if $grant.value == "allow" and (_grant_proven($m.rules; $grant; $home) | not) then _diag("session-grant-not-provable"; $grant.permission; $i)
       else empty end ] +
     [ range(0; ($required | length)) as $i |
      if $base[$i].decision != "allow" then _diag("managed-operation-not-allowed"; $required[$i].permission; $i)
      elif $seen[$i].decision == "deny" or $seen[$i].decision == "ask" then _diag("session-operation-not-allowed"; $required[$i].permission; $i)
      else empty end ]) as $conflicts |
    _result({accepted: ($conflicts | length == 0), decisions: $seen, conflicts: ($m.conflicts + $conflicts)})
  end;
def entry_permissions:
  . as $input | ($input.home // "") as $home |
  if .action == "normalize" then normalize_policy(.policy; $home)
  elif .action == "evaluate" then _result({decisions: evaluate_rules(.policy.rules; .candidates; $home), conflicts: []})
  elif .action == "serialize" then _result({permission: rules_to_map(.rules), conflicts: []})
  elif .action == "compose" then compose_policy(.managed; .global; $home)
  elif .action == "certify-session" then certify_session(.managed; .session; .required; .consent; $home)
  else _result({conflicts: [_diag("invalid-action"; "action"; 0)]}) end;
