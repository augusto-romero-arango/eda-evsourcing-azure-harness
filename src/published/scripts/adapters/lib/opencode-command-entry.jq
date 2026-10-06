include "opencode-entry-permissions";
. as $in
| ($in.home) as $home
| ($mat.commands | map({key: .id, value: .}) | from_entries) as $rowmap
| ($man.templates | map(select(.kind == "command"))) as $templates
| ($insp.profile.commands // []) as $approved
| ($agents[0].roles // []) as $roles
| ($snap.resources) as $res
| ($snap.protectedRoots) as $prot
| ($snap.project.executionRoot) as $exec
| ($in.permission // {permission: {}}) as $global
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
  def excl_read($r): [ $r.excludedPaths[] | select(endswith("/harness.config.json") | not) | suffix_pats($r; .)[] ];
  def rule($p; $pat; $v): {permission: $p, pattern: $pat, value: $v};
  def clos($id): reduce range(0; 12) as $_ ([$id]; (. + [.[] | $rowmap[.].composes[]]) | unique);
  def union($ids; $f): [$ids[] | $rowmap[.][$f][]] | unique;
  def wscope($ids): ([$ids[] | $rowmap[.].writeScope] | if index("project") != null then "project" elif index("state") != null then "state" else "none" end);
  def tdec($rules; $name): evaluate_rules($rules; [{permission: "task", candidate: $name}]; $home)[0].decision;
  def map_by($rules): $rules | group_by(.permission) | map({key: .[0].permission, value: rules_to_map(.)}) | from_entries;
  def norm_rule: {permission, pattern, value};
  def ucode: ascii_upcase | gsub("-"; "_");
  def deny_rules($extra): ([ "read","list","glob","grep","edit","bash","task","skill","external_directory","webfetch","websearch" ] + $extra | unique | map(rule(.; "*"; "deny")));

  def row_diags($id):
    (clos($id)) as $ids
    | (union($ids; "resources")) as $rids
    | [ ((["release","project","state","runtime-tool-output"] + $rids) | unique[] | . as $r | select(any($res[]; .id == $r) | not) | err("RESOURCE_MISSING"; $id)),
        ($ids[] | . as $c | select(($rowmap[$c].capabilities | index("shell")) != null and (($shells | type) != "object" or (($shells.commands // {})[$c] | type) != "array")) | err("SHELL_TEMPLATES_UNAVAILABLE"; $c)),
        (if wscope($ids) == "project" and ([$res[] | select(.id == "project" and .provenance.role == "execution")] | length) == 0 then err("EXECUTION_ROOT_MISSING"; $id) else empty end) ];

  def managed($id):
    (clos($id)) as $ids
    | (union($ids; "resources")) as $rids
    | ((["release","project","state","runtime-tool-output"] + $rids) | unique) as $rneed
    | ($res | map(select(.id as $i | $rneed | index($i) != null))) as $rows
    | (wscope($ids)) as $ws
    | ([ $prot[] | .root, (.root + "/*") ]) as $pdeny
    | ([ $rows[] | select(.id == "runtime-tool-output") | pats(.)[] ]) as $tool
    | ($res | map(select(.id == "project" and .provenance.role == "execution"))) as $exrows
    | ($exrows + ($res | map(select(.id == "state" and (.root | startswith($exec + "/")))))) as $erows
    | ([ $rows[] | pats(.)[] | rule("read"; .; "allow") ]
       + [ $rows[] | excl_read(.)[] | rule("read"; .; "deny") ]
       + [ $pdeny[] | rule("read"; .; "deny") ]
       + [ $tool[] | rule("read"; .; "allow") ]
       + [rule("read"; "../*"; "deny")]) as $read
    | ([ $rows[] | abs_pats(.)[] | rule("external_directory"; .; "allow") ]
       + [ $pdeny[] | rule("external_directory"; .; "deny") ]
       + [ $rows[] | select(.id == "runtime-tool-output") | abs_pats(.)[] | rule("external_directory"; .; "allow") ]) as $ext
    | ((if $ws == "project" then $erows elif $ws == "state" then ($erows | map(select(.id == "state"))) else [] end)) as $ed
    | ((if ($ws != "none") then
         ([ $ed[] | pats(.)[] | rule("edit"; .; "allow") ]
          + [ $ed[] | excl(.)[] | rule("edit"; .; "deny") ]
          + [ $pdeny[] | rule("edit"; .; "deny") ]
          + [ $res[] | select(.id != "project" and .id != "state") | pats(.)[] | rule("edit"; .; "deny") ]
          + [rule("edit"; "../*"; "deny")])
       else [] end)) as $edit
    | ([ $ids[] | select(($rowmap[.].capabilities | index("shell")) != null) | ($shells.commands[.])[] | rule("bash"; .; "allow") ]) as $bash
    | (if ($ids | map($rowmap[.].capabilities | index("task")) | any(. != null)) then [ union($ids; "delegates")[] | rule("task"; .; "allow") ] else [] end) as $task
    | ([ union($ids; "skills")[] | rule("skill"; .; "allow") ]) as $skill
    | ([ union($ids; "mcp")[] | rule(. + "_*"; "*"; "allow") ]) as $mcp
    | ([ "list","glob","grep" | rule(.; "*"; "allow") ]) as $lgg
    | (deny_rules($mcp | map(.permission))) as $deny
    | ($deny + $read + $ext + $edit + $bash + $task + $skill + $mcp + $lgg);

  def required($id):
    (clos($id)) as $ids
    | (union($ids; "resources")) as $rids
    | ($res | map(select(.id as $i | (["release","project","state","runtime-tool-output"] + $rids) | index($i) != null))) as $rows
    | (wscope($ids)) as $ws
    | ($res | map(select(.id == "project" and .provenance.role == "execution"))) as $exrows
    | { positive:
          ([ $rows[] | ((.root + "/probe"), (if (.relativeRoot | rel_ok) then (if .relativeRoot == "" then "probe" else .relativeRoot + "/probe" end) else empty end)) | {permission: "read", candidate: .} ]
           + [ $rows[] | {permission: "external_directory", candidate: (.root + "/probe")} ]
           + [ $rows[] | select(.id == "runtime-tool-output") | {permission: "read", candidate: (.root + "/otra-sesion/probe")} ]
           + (if $ws == "project" then [ $exrows[] | ("probe", ($exec + "/probe")) | {permission: "edit", candidate: .} ] else [] end)
           + (if $ws == "state" then [ $rows[] | select(.id == "state") | ((.root + "/probe"), (if (.relativeRoot | rel_ok) then (if .relativeRoot == "" then "probe" else .relativeRoot + "/probe" end) else empty end)) | {permission: "edit", candidate: .} ] else [] end)
           + [ $ids[] | select(($rowmap[.].capabilities | index("shell")) != null) | ($shells.commands[.])[] | {permission: "bash", candidate: gsub("\\*"; "")} ]
           + [ union($ids; "delegates")[] | {permission: "task", candidate: .} ]),
        negative:
          ([ {permission: "edit", candidate: "../probe"}, {permission: "read", candidate: "../probe"},
             {permission: "task", candidate: "unlisted-probe"}, {permission: "bash", candidate: "unlisted-command-probe"},
             {permission: "skill", candidate: "unlisted-skill-probe"} ]
           + [ $prot[] | select(.exceptions | length == 0) | ({permission: "read", candidate: (.root + "/probe")}, {permission: "edit", candidate: (.root + "/probe")}) ]
           + [ $res[] | select(.id == "release" or .id == "runtime-tool-output" or .id == "nuget-packages") | {permission: "edit", candidate: (.root + "/probe")} ]) };

  def compile($id; $sess_on):
    (managed($id)) as $m
    | compose_policy({permission: map_by($m)}; $global; $home; true) as $c
    | required($id) as $q
    | if $c.policy == null then {diags: ($c.conflicts | map(err(.code | ucode; $id)))}
      else
        ($c.policy.rules | map(norm_rule)) as $rules
        | (evaluate_rules($rules; $q.positive; $home)) as $pos
        | (evaluate_rules($rules; $q.negative; $home)) as $neg
        | (if $sess_on and $in.phase == "command" and $in.sessionPolicyKnown and $in.sessionProjectMatches
           then certify_session({permission: map_by($rules)}; $in.sessionPermission; $q.positive; true; $home) else {accepted: true, conflicts: []} end) as $sess
        | ([ (if any($pos[]; .decision != "allow") then err("OPERATION_NOT_ALLOWED"; $id) else empty end),
             (if any($neg[]; .decision == "allow") then err("WIDENING_DETECTED"; $id) else empty end),
             ($sess.conflicts[] | err(.code | ucode; $id)) ]) as $dd
        | if ($dd | length) > 0 then {diags: $dd} else {diags: [], rules: $rules} end
      end;

  def own_diags($id):
    ($templates | map(select(.id == $id)) | first) as $t
    | ($in.commands | map(select(.name == ("mefisto:" + $id))) | first) as $o
    | if $t == null or $o == null then [err("COMMAND_NOT_OBSERVED"; $id)]
      else
        [ (if $o.sourceDigest != $t.sha256 then err("COMMAND_OWNERSHIP"; $id) else empty end),
          (if ($t.nativeBinding == null and ($o.agent != null or $o.subtask != null)) or
              ($t.nativeBinding != null and (($o.agent != null or $o.subtask != null) and ($o.agent != ("command-entry-" + $t.nativeBinding.commandEntryId) or $o.subtask != false)))
           then err("COMMAND_OWNERSHIP"; $id) else empty end) ]
      end;

  def delegate_diags($id):
    [ clos($id)[] as $c | ($rowmap[$c].delegates[]) as $a
      | ($man.delegatedPrompts | map(select(.command == $c and .agent == $a)) | first) as $p
      | ($in.delegateAgents | map(select(.id == $a)) | first) as $o
      | ($roles | map(select(.id == $a)) | first) as $role
      | if $p == null or $o == null or $o.available != true then err("DELEGATE_MISSING"; $a)
        elif $o.sourceDigest != $p.sha256 then err("DELEGATE_MODIFIED"; $a)
        elif (($o.mode == "subagent" or $o.mode == "all") | not) or ($role != null and $role.mode != $o.mode) then err("DELEGATE_MODE"; $a)
        else empty end ];

  ($templates | map(.id)) as $all
  | (if $in.phase == "command" then [$in.requestedCommand] else ($all | map(select(. as $i | $approved | index($i) != null))) end) as $scope
  | ($scope | map(select(. as $i | ($all | index($i)) == null))) as $badscope
  | ($scope | map(select(. as $i | $approved | index($i) == null))) as $unapproved
  | ($scope - $badscope - $unapproved) as $good
  | ([ (if $in.configPolicyKnown then empty else err("CONFIG_POLICY_UNKNOWN"; "config") end),
       ($in.foreignEntryAgents[] | err("ENTRY_AGENT_COLLISION"; .)),
       ($badscope[] | err("COMMAND_UNKNOWN"; .)),
       ($unapproved[] | err("COMMAND_NOT_APPROVED"; .)),
       (if $in.phase == "command" and ($in.sessionPolicyKnown | not) then err("SESSION_UNKNOWN"; "session") else empty end),
       (if $in.phase == "command" and ($in.sessionProjectMatches | not) then err("SESSION_PROJECT_MISMATCH"; "session") else empty end),
       ($all[] | own_diags(.)[]) ]) as $d0
  | (if ($d0 | length) > 0 then [] else [ $good[] | (row_diags(.)[], delegate_diags(.)[]) ] end) as $d1
  | (if ($d0 + $d1 | length) > 0 then [] else [ $good[] | . as $id | {id: $id, c: compile($id; true)} ] end) as $comp
  | ($d0 + $d1 + [ $comp[] | .id as $id | .c.diags[] ] | unique_by([.code, .subject])) as $diags
  | ($diags | length == 0) as $ok
  | (if ($d0 + $d1 | length) > 0 then {} else ([ $approved[] | select(. as $i | ($all | index($i)) != null) | . as $id | {key: $id, value: (compile($id; false) | .rules // null)} ] | from_entries) end) as $dig_rules
  | ($comp | map({key: .id, value: .c.rules}) | from_entries) as $rulesby
  | ($templates | map({
       id: .id,
       agent: ("command-entry-" + .id),
       rules: (if $ok then ($rulesby[.id] // deny_rules([])) else deny_rules([]) end)
     })) as $agentrows
  | { schemaVersion: 1, phase: $in.phase, admissionScope: "entry",
      status: (if $ok then "ready" else "conflict" end),
      projectId: $snap.projectId, profileDigest: $snap.profileDigest,
      catalogDigest: $man.catalogFingerprint, resourcesDigest: $snap.resourcesDigest, projectionDigest: null,
      release: {root: $snap.release.root, version: ($snap.release.version // null), commit: ($snap.release.commit // null)},
      agents: ($agentrows | map({id: .agent, mode: "primary", hidden: true, rules: .rules})),
      bindings: ($templates | map(. as $t | {command: ("mefisto:" + $t.id), agent: ("command-entry-" + $t.id), subtask: false, sourceDigest: $t.sha256,
                 admitted: ($ok and $in.phase == "command" and $t.id == $in.requestedCommand)})),
      diagnostics: $diags,
      _digestInput: (if $ok then {projectId: $snap.projectId, profileDigest: $snap.profileDigest, release: $snap.release, catalogDigest: $man.catalogFingerprint,
          resourcesDigest: $snap.resourcesDigest,
          agents: ($templates | map({id: ("command-entry-" + .id), rules: ($dig_rules[.id] // deny_rules([]))})),
          bindings: ($templates | map({command: ("mefisto:" + .id), agent: ("command-entry-" + .id), sourceDigest: .sha256}))} else null end) }
