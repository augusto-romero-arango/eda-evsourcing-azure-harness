include "opencode-entry-permissions";
. as $in
| ($in.home) as $home
| ($man.roles | map({key: .id, value: .}) | from_entries) as $roles
| ($in.snapshot) as $snap
| ($snap.resources) as $res
| ($snap.protectedRoots) as $prot
| ($snap.project.executionRoot) as $exec
| (if $in.globalPolicy == null then null else normalize_policy($in.globalPolicy; $home) end) as $F
| def err($c; $s): {code: $c, subject: $s};
  def starp: if . == "" then "*" else . + "/*" end;
  def rel_ok: startswith("..") | not;
  def pats($r):
    ([$r] + $r.aliases)
    | map(. as $x
          | [ (if ($x.relativeRoot | rel_ok) then ($x.relativeRoot | starp), (if $x.relativeRoot == "" then empty else $x.relativeRoot end) else empty end),
              $x.root, ($x.root + "/*") ])
    | flatten | unique;
  def abs_pats($r): ([$r] + $r.aliases) | map(.root, (.root + "/*")) | unique;
  def suffix_pats($r; $abs):
    if ($abs | startswith($r.root + "/")) then
      ($abs[($r.root | length):]) as $s
      | ([$r] + $r.aliases | map(.root + $s)) as $abss
      | ($abss + (if ($r.relativeRoot | rel_ok) then [if $r.relativeRoot == "" then $s[1:] else $r.relativeRoot + $s end] else [] end))
      | map(., . + "/*")
    else [$abs, $abs + "/*"] end;
  def excl($r): [ $r.excludedPaths[] | suffix_pats($r; .)[] ];
  def rrows($m): $res | map(select(.id as $i | ($m.resources | index($i)) != null));
  def exec_rows: $res | map(select(.id == "project" and .provenance.role == "execution"));
  def edit_rows: (exec_rows) + ($res | map(select(.id == "state" and (.root | startswith($exec + "/")))));
  def has_bash($m): ($m.metadata.permission.bash | type) == "object";
  def rule($p; $pat; $v): {permission: $p, pattern: $pat, value: $v};
  def attach_pattern($a): "MEFISTO_RUNTIME=opencode \"" + $a.executable + "\" attach --shell-pid " + ($a.pid | tostring) + " --request \"" + $a.request + "\"" + ($a.suffix // "");
  def attach_valid($a):
    ($a | type) == "object" and ($a.executable == ($snap.release.root + "/scripts/execution-context.sh")) and
    (($a.pid | type) == "number" and $a.pid > 0 and $a.pid == ($a.pid | floor)) and
    ($a.request | type) == "string" and
    any($res[]; select(.id == "state") | .root as $sr | ($a.controlRoot | type) == "string" and ($a.request | startswith($a.controlRoot + "/")) and ($a.controlRoot == $sr or ($a.controlRoot | startswith($sr + "/")))) and
    ([$a.executable, $a.request, ($a.suffix // "")] | all(.[]; test("[*?\\\\\u0000-\u001f\"]") | not));
  def tdec($rules; $name):
    evaluate_rules($rules; [{permission: "task", candidate: $name}]; $home)[0].decision;
  def task_ok($name; $o; $need_allow):
    (normalize_policy({permission: {task: ($o.permission.task // "deny")}}; $home).rules) as $or
    | (tdec($or; $name)) as $od
    | (if $need_allow then $od == "allow" else $od != "deny" end) and (tdec($F.rules; $name) != "deny") and
      (($in.sessionPolicy == null) or (($in.sessionPolicy | type) != "array") or (tdec($in.sessionPolicy; $name) != "deny"));
  def pair($t): [$t, $roles[$t].alias];

  def role_diags($req):
    ($roles[$req.role]) as $m
    | ($in.originals | map(select(.id == $req.role)) | first) as $o
    | if $m == null then [err("ROLE_UNKNOWN"; $req.role)]
      else
        [ if ($in.collisions | index($m.alias)) != null then err("ALIAS_COLLISION"; $req.role) else empty end,
          if $o == null then err("ORIGINAL_NOT_OBSERVED"; $req.role)
          else
            (if $o.promptHash != $m.sourceDigest then err("PROMPT_OWNERSHIP"; $req.role) else empty end),
            (if $o.mode != $m.metadata.mode then err("MODE_DIVERGENCE"; $req.role) else empty end),
            (if $o.permission != $m.metadata.permission or $o.tools != $m.metadata.tools then err("CAPABILITY_METADATA_DIVERGENCE"; $req.role) else empty end)
          end,
          (if $m.writeScope == "project" and (exec_rows | length) == 0 then err("EXECUTION_ROOT_MISSING"; $req.role) else empty end),
          ($m.resources[] | . as $rid | select(any($res[]; .id == $rid) | not) | err("RESOURCE_MISSING"; $req.role)),
          (if has_bash($m) and (attach_valid($req.attach) | not) then err("ATTACH_INVALID"; $req.role) else empty end),
          (if (has_bash($m) | not) and $req.attach != null then err("ATTACH_NOT_ALLOWED"; $req.role) else empty end),
          ($req.taskTargets[] | . as $t |
             if $roles[$t] == null then err("TASK_TARGET_UNKNOWN"; $req.role)
             elif ($o != null) and ((task_ok($t; $o; true) and task_ok($roles[$t].alias; $o; false)) | not) then err("TASK_DENIED"; $req.role)
             else empty end)
        ]
      end;

  def map_by($rules): $rules | group_by(.permission) | map({key: .[0].permission, value: rules_to_map(.)}) | from_entries;
  def norm_rule: {permission, pattern, value};
  def managed($req):
    ($roles[$req.role]) as $m
    | (rrows($m)) as $rows
    | ($m.metadata.permission) as $mp
    | ([ $prot[] | .root, (.root + "/*") ]) as $pdeny
    | ([ $rows[] | select(.id == "runtime-tool-output") | pats(.)[] ]) as $tool
    | ([ $rows[] | pats(.)[] | rule("read"; .; "allow") ]
       + [ $rows[] | excl(.)[] | rule("read"; .; "deny") ]
       + [ $pdeny[] | rule("read"; .; "deny") ]
       + [ $tool[] | rule("read"; .; "allow") ]
       + [rule("read"; "../*"; "deny")]
       + [ ($mp.read | if type == "object" then to_entries[] | select(.value == "deny") | rule("read"; .key; "deny") else empty end) ]) as $read
    | ([ $rows[] | abs_pats(.)[] | rule("external_directory"; .; "allow") ]
       + [ $pdeny[] | rule("external_directory"; .; "deny") ]
       + [ $rows[] | select(.id == "runtime-tool-output") | abs_pats(.)[] | rule("external_directory"; .; "allow") ]) as $ext
    | (if $m.writeScope == "project" then
         ([ edit_rows[] | pats(.)[] | rule("edit"; .; "allow") ]
          + [ edit_rows[] | excl(.)[] | rule("edit"; .; "deny") ]
          + [ $pdeny[] | rule("edit"; .; "deny") ]
          + [ $res[] | select(.id != "project" and .id != "state") | pats(.)[] | rule("edit"; .; "deny") ]
          + [rule("edit"; "../*"; "deny")]
          + [ ($mp.edit | if type == "object" then to_entries[] | select(.value == "deny" and .key != "*") | rule("edit"; .key; "deny") else empty end) ])
       else [] end) as $edit
    | (if has_bash($m) then [rule("bash"; attach_pattern($req.attach); "allow")] else [] end) as $bash
    | ([ $req.taskTargets[] | pair(.)[] | rule("task"; .; "allow") ]) as $task
    | ([ $m.metadata.skills[]? | rule("skill"; .; "allow") ]) as $skill
    | ([ ($m.metadata.tools // {}) | to_entries[] | rule(.key; "*"; (if .value == true then "allow" else "deny" end)) ]) as $mcp
    | ([ $mp | to_entries[] | select(.key as $k | (["external_directory","bash","edit","write","patch","read","task","skill"] | index($k)) == null and (.value | type) == "string") | rule(.key; "*"; .value) ]) as $scalars
    | ($read + $ext + $edit + $bash + $task + $skill + $mcp + $scalars) as $allow
    | (["read","external_directory","edit","bash","task","skill"] + ($mcp | map(.permission)) + ($scalars | map(.permission)) | unique) as $perms
    | ([ $perms[] | rule(.; "*"; "deny") ] + $allow);

  def compile($req): compose_policy({permission: map_by(managed($req))}; $in.globalPolicy; $home; false);

  def required($req):
    ($roles[$req.role]) as $m | (rrows($m)) as $rows
    | { positive:
          ([ $rows[] | ((.root + "/probe"), (if (.relativeRoot | rel_ok) then (if .relativeRoot == "" then "probe" else .relativeRoot + "/probe" end) else empty end)) | {permission: "read", candidate: .} ]
           + [ $rows[] | {permission: "external_directory", candidate: (.root + "/probe")} ]
           + (if $m.writeScope == "project" then [ exec_rows[] | ("probe", ($exec + "/probe")) | {permission: "edit", candidate: .} ] else [] end)
           + (if has_bash($m) then [{permission: "bash", candidate: attach_pattern($req.attach)}] else [] end)
           + [ $req.taskTargets[] | pair(.)[] | {permission: "task", candidate: .} ]),
        negative:
          ([ {permission: "edit", candidate: "../probe"}, {permission: "read", candidate: "../probe"},
             {permission: "task", candidate: "unlisted-probe"}, {permission: "task", candidate: "autonomy-unlisted-probe"},
             {permission: "bash", candidate: "unlisted-command-probe"}, {permission: "skill", candidate: "unlisted-skill-probe"} ]
           + [ $prot[] | select(.exceptions | length == 0) | ({permission: "read", candidate: (.root + "/probe")}, {permission: "edit", candidate: (.root + "/probe")}) ]
           + [ $res[] | select(.id == "release" or .id == "runtime-tool-output" or .id == "nuget-packages") | {permission: "edit", candidate: (.root + "/probe")} ]
           + [ exec_rows[] | .excludedPaths[] | ({permission: "edit", candidate: .}, {permission: "read", candidate: (. + "/probe")}) ]) };

  def ucode: ascii_upcase | gsub("-"; "_");
  def project_role($req):
    (role_diags($req)) as $d
    | if ($d | length) > 0 then {diags: $d}
      else
        ($roles[$req.role]) as $m | compile($req) as $c | required($req) as $q
        | if $c.policy == null then {diags: ($c.conflicts | map(err(.code | ucode; $req.role)))}
          else
            ($c.policy.rules | map(norm_rule)) as $rules
            | (evaluate_rules($rules; $q.positive; $home)) as $pos
            | (evaluate_rules($rules; $q.negative; $home)) as $neg
            | (if ($in.sessionPolicy | type) == "array" then certify_session({permission: map_by($rules)}; $in.sessionPolicy; $q.positive; true; $home) else {accepted: true, conflicts: []} end) as $sess
            | ([ (if any($pos[]; .decision != "allow") then err("OPERATION_NOT_ALLOWED"; $req.role) else empty end),
                 (if any($neg[]; .decision == "allow") then err("WIDENING_DETECTED"; $req.role) else empty end),
                 ($sess.conflicts[] | err(.code | ucode; $req.role)) ]) as $dd
            | if ($dd | length) > 0 then {diags: $dd}
              else {diags: [], rules: $rules, q: $q, actor: {originalId: $req.role, alias: $m.alias, permission: map_by($rules),
                      taskBindings: [ $req.taskTargets[] | {target: ., alias: $roles[.].alias} ]}}
              end
          end
      end;

  def entry_diags:
    [ ($in.entryTaskPolicies // [])[] | . as $p
      | (if $edig[$p.entryId] != $p.digest then err("ENTRY_POLICY_DIGEST"; $p.entryId) else empty end),
        ($p.targets[] | . as $t
          | if $roles[$t] == null then err("ENTRY_TARGET_UNKNOWN"; $p.entryId)
            elif ([$t, $roles[$t].alias] | any(.[]; (tdec($F.rules; .) == "deny") or (($in.sessionPolicy | type) == "array" and tdec($in.sessionPolicy; .) == "deny"))) then err("ENTRY_TASK_DENIED"; $p.entryId)
            else empty end) ];

  def verify_diags($ps):
    ($in.observed) as $obs
    | [ $ps[] | select(.actor != null) | . as $p | ($obs | map(select(.name == $p.actor.alias)) | first) as $o
        | if $o == null then err("ACTOR_NOT_OBSERVED"; $p.actor.originalId)
          else
            ($roles[$p.actor.originalId]) as $m
            | (if $o.mode != $m.mode then err("MODE_DIVERGENCE"; $p.actor.originalId) else empty end),
              (if $o.promptHash != $m.sourceDigest then err("PROMPT_OWNERSHIP"; $p.actor.originalId) else empty end),
              (if $o.available != true then err("ACTOR_UNAVAILABLE"; $p.actor.originalId) else empty end),
              (if (_validate_rules($o.rules; "observed") | length) > 0 then err("OBSERVATION_INVALID"; $p.actor.originalId)
               else
                 (if any(evaluate_rules($o.rules; $p.q.positive; $home)[]; .decision != "allow") then err("OBSERVED_OPERATION_DENIED"; $p.actor.originalId) else empty end),
                 (if any(evaluate_rules($o.rules; $p.q.negative; $home)[]; .decision == "allow") then err("OBSERVED_WIDENING"; $p.actor.originalId) else empty end),
                 (($o.rules | map(_normalize_rule)) | . as $or | range(0; length) as $i | select($or[$i].value == "allow" and (($or[$i] | norm_rule) as $g | (any($p.rules[]; . == $g) or _grant_proven($p.rules; $g; $home)) | not)) | err("OBSERVED_GRANT_NOT_PROVABLE"; $p.actor.originalId))
               end)
          end ]
      + [ $obs[] | . as $o | select(any($ps[]; .actor != null and .actor.alias == $o.name) | not) | err("UNEXPECTED_ACTOR"; "observed") ]
      + (if ($obs | map(.name) | length) != ($obs | map(.name) | unique | length) then [err("OBSERVATION_DUPLICATED"; "observed")] else [] end);

  ([ $in.roles[] | project_role(.) ]) as $ps
  | ($ps | map(.diags[])) as $d0
  | (if $d0 | length > 0 then [] else entry_diags end) as $d1
  | (if ($d0 + $d1 | length) == 0 and $in.phase == "verify" then verify_diags($ps) else [] end) as $d2
  | ($d0 + $d1 + $d2 | unique_by([.code, .subject])) as $diags
  | ($diags | length == 0) as $ok
  | ($ps | map(select(.actor != null))) as $good
  | { schemaVersion: 1,
      status: (if $ok then "ready" else "conflict" end),
      admissionScope: "agent-projection",
      phase: $in.phase,
      catalogDigest: $man.catalogFingerprint,
      resourcesDigest: $snap.resourcesDigest,
      projectionDigest: null,
      actors: (if $ok then ($good | map(.actor)) else [] end),
      entryTaskBindings: (if $ok then ([ ($in.entryTaskPolicies // [])[] | {key: .entryId, value: (.targets | unique | map({target: ., alias: $roles[.].alias}))} ] | from_entries) else {} end),
      diagnostics: $diags,
      _digestInput: (if $ok then {catalogDigest: $man.catalogFingerprint, resourcesDigest: $snap.resourcesDigest,
          actors: ($good | map({originalId: .actor.originalId, alias: .actor.alias, rules: .rules, taskBindings: .actor.taskBindings})),
          entryTaskBindings: ([ ($in.entryTaskPolicies // [])[] | {key: .entryId, value: (.targets | unique | map({target: ., alias: $roles[.].alias}))} ] | from_entries)} else null end),
      _observations: (if $ok and $in.phase == "verify" then ($in.observed | map({alias: .name, input: {name, mode, promptHash, rules, available}})) else [] end) }
