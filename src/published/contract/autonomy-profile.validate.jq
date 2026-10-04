# Validador puro del envelope de perfil y consentimiento de autonomia.
def kebab: type == "string" and test("^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$");
def sha256: type == "string" and test("^[0-9a-f]{64}$");
def reference: type == "string" and test("^[a-z][a-z0-9._:/-]*$");
def closed($allowed):
  . as $object | ($object | type) == "object" and (($object | keys | sort) == ($allowed | sort));
def allowed($allowed):
  . as $object | ($object | type) == "object" and ((($object | keys) - $allowed) | length == 0);
def valid_string: type == "string" and length > 0;
def valid_catalog:
  type == "array" and length > 0 and all(.[]; kebab) and (length as $count | unique | length == $count);

def valid_grant($commands):
  . as $grant
  | allowed(["action", "command", "environment", "planDigest", "resources"])
  and ($grant.command as $command | ($command | kebab) and ($commands | index($command) != null))
  and ($grant.action | kebab)
  and ($grant.environment | kebab)
  and ($grant.resources | type == "array" and length > 0 and all(.[]; reference) and (length as $count | unique | length == $count))
  and (if $grant | has("planDigest") then ($grant.planDigest | sha256) else true end);

def valid_profile($catalog):
  . as $profile
  | closed(["administration", "commands", "id", "revision", "schemaVersion"])
  and $profile.schemaVersion == 1
  and ($profile.id | kebab)
  and ($profile.revision | type == "number" and floor == . and . > 0)
  and ($profile.commands as $commands
       | ($commands | type == "array" and length > 0 and all(.[]; kebab) and (length as $count | unique | length == $count)
          and all(.[]; . as $command | ($catalog | index($command) != null)))
       and ($profile.administration | type == "array" and all(.[]; valid_grant($commands))));

def valid_context:
  closed(["profileDigest", "projectId"])
  and (.projectId | kebab)
  and (.profileDigest | sha256);

def valid_consent:
  closed(["decision", "profileDigest", "projectId", "recordedAt", "schemaVersion"])
  and .schemaVersion == 1
  and (.projectId | kebab)
  and (.profileDigest | sha256)
  and (.decision == "approved" or .decision == "revoked")
  and (.recordedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})$"));

def result($status; $reason; $context; $profile):
  {schemaVersion: 1, status: $status, reasonCode: $reason,
   projectId: ($context.projectId // null), profileDigest: ($context.profileDigest // null), profile: $profile};

if (type != "object" or (keys | sort) != ["catalog", "consent", "context", "profile"]) then
  result("conflict"; "INVALID_ENVELOPE"; {}; null)
elif (.context | valid_context | not) then
  result("conflict"; "INVALID_CONTEXT"; (.context // {}); null)
elif (.catalog | valid_catalog | not) then
  result("conflict"; "INVALID_CATALOG"; .context; null)
elif .profile == null then
  result("disabled"; "NO_PROFILE"; .context; null)
elif (.profile as $profile | .catalog as $catalog | ($profile | valid_profile($catalog) | not)) then
  result("conflict"; "INVALID_PROFILE"; .context; null)
elif .consent == null then
  result("needs-approval"; "CONSENT_REQUIRED"; .context; .profile)
elif (.consent | valid_consent | not) then
  result("conflict"; "INVALID_CONSENT"; .context; .profile)
elif .consent.projectId != .context.projectId then
  result("conflict"; "PROJECT_MISMATCH"; .context; .profile)
elif .consent.profileDigest != .context.profileDigest then
  result("needs-approval"; "CONSENT_DIGEST_MISMATCH"; .context; .profile)
elif .consent.decision == "revoked" then
  result("disabled"; "CONSENT_REVOKED"; .context; .profile)
else
  result("ready"; "CONSENT_APPROVED"; .context; .profile)
end
