# Validador puro del plan preautorizado de fix-review (issue #1886).
# Entrada: {"plan": <plan>, "grants": null|[<grant>], "context": {"projectId": <kebab>}}.
# Salida: {schemaVersion, status, reasonCode, canonical, requiredActions, authorization}.
# `canonical` es el JSON canonico (claves ordenadas, sin planDigest, comentarios y
# triage por id) que el caller hashea con SHA-256 y compara con plan.planDigest.
def kebab: type == "string" and test("^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$");
def sha256: type == "string" and test("^[0-9a-f]{64}$");
def sha1: type == "string" and test("^[0-9a-f]{40}$");
def slug: type == "string" and test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$");
def posint: type == "number" and floor == . and . > 0;
def natint: type == "number" and floor == . and . >= 0;
def nullable(f): . == null or f;
def closed($allowed):
  . as $o | type == "object" and (($o | keys | sort) == ($allowed | sort));
def ref_name:
  type == "string" and length > 0 and length <= 200
  and test("^[A-Za-z0-9._/-]+$") and (startswith("-") | not) and (contains("..") | not)
  and (startswith("/") | not) and (endswith("/") | not) and (contains("//") | not);
def safe_path:
  type == "string" and length > 0 and length <= 260
  and test("^[A-Za-z0-9._@+-]+(/[A-Za-z0-9._@+-]+)*$")
  and (split("/") | all(.[]; . != "." and . != ".."));
def code_path:
  safe_path
  and (split("/") as $s
       | ($s[0] as $first
          | (["", ".git", ".github", ".mefisto", ".claude", ".claude-plugin", ".opencode", "infra"] | index($first)) == null)
         and (($s | last) as $leaf
              | ($leaf != "harness.config.json" and ($leaf | startswith(".env") | not))));
def text($max): type == "string" and length > 0 and length <= $max and test("^[^\\x00-\\x1f\\x7f]+$");
def sensitive:
  type == "string" and test("(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|(?i:bearer)[ ]+[A-Za-z0-9._~+/=-]{16,}|://[^/ ]*:[^/ ]*@|(?i:authorization)[ ]*[:=]|-----BEGIN [A-Z ]*PRIVATE KEY)");
def unique_list: length as $n | unique | length == $n;
def safe($f): try ($f) catch false;
def t(f): try f catch false;

def canon:
  if type == "object" then
    "{" + (to_entries | sort_by(.key) | map((.key | tojson) + ":" + (.value | canon)) | join(",")) + "}"
  elif type == "array" then "[" + (map(canon) | join(",")) + "]"
  else tojson end;
def normalized:
  del(.planDigest)
  | .commentSnapshot |= sort_by(.id)
  | .triage |= sort_by(.commentId)
  | .secondary.localImprovementClasses |= sort;

def valid_snapshot_row:
  closed(["bodyDigest", "id", "inReplyToId", "line", "originalLine", "path"])
  and (.id | posint) and (.bodyDigest | sha256)
  and (.path | nullable(safe_path))
  and (.line | nullable(posint)) and (.originalLine | nullable(posint))
  and (.inReplyToId | nullable(posint));
def valid_edit:
  closed(["change", "impact", "path"])
  and (.path | code_path) and (.change | text(280)) and (.impact | text(280));
def valid_triage_row:
  . as $row
  | (.category as $c | ["corregir", "explicar", "resuelto", "investigar"] | index($c) != null)
  and (.commentId | posint) and (.summary | text(280))
  and (if .category == "corregir"
       then closed(["category", "commentId", "edits", "summary"])
            and (.edits | type == "array" and length > 0 and all(.[]; valid_edit))
       else closed(["category", "commentId", "summary"]) end);

def has_fix: any(.triage[]; .category == "corregir");
def classes: ["consumer-adr", "consumer-directives", "consumer-test-helper"];

def checks($ctx):
  . as $p
  | [
    ["INVALID_PLAN_SHAPE", t($p | closed(["baseRef", "commentSnapshot", "expectedHeadSha", "headRefName", "headRepository", "limits", "planDigest", "planTextDigest", "projectId", "prNumber", "repoSlug", "schemaVersion", "secondary", "triage", "verification"]))],
    ["INVALID_SCHEMA_VERSION", t($p.schemaVersion == 1)],
    ["INVALID_PROJECT", t($p.projectId | kebab)],
    ["PROJECT_MISMATCH", t($p.projectId == $ctx)],
    ["INVALID_REPOSITORY", t(($p.repoSlug | slug) and ($p.headRepository | slug))],
    ["FORK_NOT_SUPPORTED", t($p.headRepository == $p.repoSlug)],
    ["INVALID_PR_NUMBER", t($p.prNumber | posint)],
    ["INVALID_REF", t(($p.baseRef | ref_name) and ($p.headRefName | ref_name))],
    ["INVALID_HEAD_SHA", t($p.expectedHeadSha | sha1)],
    ["INVALID_SNAPSHOT", t($p.commentSnapshot | type == "array" and length > 0 and all(.[]; valid_snapshot_row))],
    ["DUPLICATE_COMMENT_ID", t($p.commentSnapshot | map(.id) | unique_list)],
    ["INVALID_TRIAGE", t($p.triage | type == "array" and all(.[]; valid_triage_row))],
    ["TRIAGE_SNAPSHOT_MISMATCH", t(($p.triage | map(.commentId) | sort) == ($p.commentSnapshot | map(.id) | sort) and ($p.triage | map(.commentId) | unique_list))],
    ["INVALID_VERIFICATION", t($p.verification == (if ($p | has_fix) then ["dotnet build", "dotnet test"] else [] end))],
    ["INVALID_PLAN_TEXT_DIGEST", t($p.planTextDigest | sha256)],
    ["INVALID_PLAN_DIGEST_FORMAT", t($p.planDigest | sha256)],
    ["INVALID_SECONDARY", t($p.secondary | closed(["consumerIssues", "harnessDrafts", "localImprovementClasses", "replyPolicy"])
       and (.replyPolicy == "none" or .replyPolicy == "freeform-factual")
       and (.consumerIssues | type == "boolean") and (.harnessDrafts | type == "boolean")
       and (.localImprovementClasses | type == "array" and unique_list and all(.[]; . as $c | classes | index($c) != null)))],
    ["INVALID_LIMITS", t($p.limits | closed(["consumerIssues", "drafts", "localFiles"])
       and (.consumerIssues | natint) and (.drafts | natint) and (.localFiles | natint)
       and ((.consumerIssues > 0) == $p.secondary.consumerIssues)
       and ((.drafts > 0) == $p.secondary.harnessDrafts)
       and ((.localFiles > 0) == (($p.secondary.localImprovementClasses | length) > 0)))],
    ["SENSITIVE_CONTENT", t([$p | .. | select(type == "string") | sensitive] | any | not)]
  ];

def required_actions:
  [ (if has_fix then "fix-review-correct" else empty end),
    (if .secondary.replyPolicy != "none" then "fix-review-reply" else empty end),
    (if .secondary.consumerIssues then "fix-review-consumer-issue" else empty end),
    (if .secondary.harnessDrafts then "fix-review-harness-draft" else empty end),
    (if (.secondary.localImprovementClasses | length) > 0 then "fix-review-local-improvement" else empty end) ];
def action_scope:
  {"fix-review-correct": "scope:planned-files", "fix-review-reply": "scope:review-comments",
   "fix-review-consumer-issue": "scope:consumer-issue", "fix-review-harness-draft": "scope:harness-draft",
   "fix-review-local-improvement": "scope:consumer-docs"};
def granted($plan; $grants; $action):
  ("pr:" + ($plan.prNumber | tostring)) as $pr
  | any($grants[]; safe(
      .command == "fix-review" and .action == $action and .environment == "repository"
      and has("planDigest") and .planDigest == $plan.planDigest
      and (.resources | type == "array") and (.resources | index($pr)) != null and (.resources | index(action_scope[$action])) != null));

def result($status; $reason; $canonical; $required; $auth):
  {schemaVersion: 1, status: $status, reasonCode: $reason, canonical: $canonical,
   requiredActions: $required, authorization: $auth};

if (type != "object" or (keys | sort) != ["context", "grants", "plan"]
    or (.context | closed(["projectId"]) | not) or (.context.projectId | kebab | not)
    or (.grants != null and (.grants | type != "array"))) then
  result("invalid"; "INVALID_ENVELOPE"; null; []; null)
else
  .plan as $plan | .grants as $grants | .context.projectId as $ctx
  | if ($plan | type) != "object" then result("invalid"; "INVALID_PLAN_SHAPE"; null; []; null)
    else
      ([$plan | checks($ctx)[] | select(.[1] | not) | .[0]] | first) as $failed
      | if $failed != null then result("invalid"; $failed; null; []; null)
        else
          ($plan | required_actions) as $required
          | result("valid"; "PLAN_VALID"; ($plan | normalized | canon); $required;
              if $grants == null then null
              else ([$required[] | select(granted($plan; $grants; .) | not)]) as $missing
                | {status: (if ($missing | length) == 0 then "authorized" else "unauthorized" end), missing: $missing}
              end)
        end
    end
end
