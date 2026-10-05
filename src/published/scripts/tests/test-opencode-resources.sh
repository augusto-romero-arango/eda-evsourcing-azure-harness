#!/usr/bin/env bash
# Pruebas deterministas del resolver de recursos OpenCode contra una release
# instalada de fixture (sin checkout fuente) con dobles de inspect y NuGet.
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
DIST="$REPO_ROOT/dist/opencode"
WORK="$(cd -P "$(mktemp -d)" && pwd -P)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT
PASS=0; FAIL=0

pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { local label="$1"; shift; "$@" >/dev/null 2>&1 && pass "$label" || fail "$label"; }
assert_json() { local label="$1" filter="$2"; shift 2; jq -e "$filter" "$@" >/dev/null <<< "$OUT" && pass "$label" || fail "$label"; }

OS_HOME="$WORK/os home"; DATA="$WORK/XDG data"; CONFIG_HOME="$WORK/XDG config"
STORE="$DATA/mefisto"; RELEASE="$STORE/releases/0.40.2"; CONFIG="$CONFIG_HOME/opencode"
MAIN="$WORK/proj main"; LINKED="$WORK/proj linked"; OTHER="$WORK/otro clon"
mkdir -p "$OS_HOME" "$STORE/releases" "$CONFIG" "$DATA/opencode/storage"
printf 'sentinel-secret\n' > "$DATA/opencode/auth.json"

# Release instalada: solo dist/opencode, con manifest y dobles de los eslabones.
cp -R "$DIST" "$RELEASE" || { echo 'FAIL: no se pudo copiar dist/opencode'; exit 1; }
jq -n '{schemaVersion:1,runtime:"opencode",version:"0.40.2",commit:"0123456789abcdef0123456789abcdef01234567",minimumRuntimeVersion:"1.18.29"}' > "$RELEASE/mefisto-manifest.json"
ln -s "$RELEASE" "$STORE/active"
REAL_INSPECT="$RELEASE/scripts/autonomy-profile.real.sh"
mv "$RELEASE/scripts/autonomy-profile.sh" "$REAL_INSPECT"
cat > "$RELEASE/scripts/autonomy-profile.sh" <<'EOF'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd -P)"
[ ! -f "$d/inspect.real" ] || exec "$d/autonomy-profile.real.sh" "$@"
cat "$d/inspect.json"; exit "$(cat "$d/inspect.rc")"
EOF
cat > "$RELEASE/scripts/resolve-nuget-resources.sh" <<'EOF'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd -P)"
printf '%s\n' "$*" > "$d/nuget.args"
cat "$d/nuget.json"; exit "$(cat "$d/nuget.rc")"
EOF
chmod +x "$RELEASE/scripts/autonomy-profile.sh" "$RELEASE/scripts/resolve-nuget-resources.sh"
set_inspect() { jq -cn --arg status "$1" --arg reason "$2" '{schemaVersion:1,status:$status,reasonCode:$reason,projectId:"project-aaaaaaaaaaaaaaaaaaaaaaaa",profileDigest:("a" * 64),profile:null}' > "$RELEASE/scripts/inspect.json"; printf '%s\n' "$3" > "$RELEASE/scripts/inspect.rc"; }
set_nuget() { printf '%s\n' "$1" > "$RELEASE/scripts/nuget.json"; printf '%s\n' "$2" > "$RELEASE/scripts/nuget.rc"; }
nuget_row() { jq -cn --arg r "$1" --argjson e "$2" --argjson s "$3" '{logicalRoot:$r,physicalRoot:$r,exists:$e,sources:$s}'; }
nuget_doc() { jq -cn --arg status "$1" --arg coverage "$2" --argjson roots "$3" --argjson assets "$4" '{schemaVersion:1,status:$status,coverage:$coverage,worktreeRoot:"x",roots:$roots,assets:$assets,diagnostics:[]}'; }

# Proyecto principal con worktree registrado y un clon ajeno.
mkdir -p "$MAIN/.mefisto"
git -C "$MAIN" init -q 2>/dev/null && git -C "$MAIN" config user.email t@t && git -C "$MAIN" config user.name t
printf '{}\n' > "$MAIN/.mefisto/harness.config.json"
git -C "$MAIN" add -A && git -C "$MAIN" commit -qm init
git -C "$MAIN" worktree add -q "$LINKED" -b linked 2>/dev/null
printf '{}\n' > "$LINKED/.mefisto/harness.config.json"
git clone -q "$MAIN" "$OTHER"
ln -s "$MAIN" "$WORK/alias main"

# Ledger alineado y vacio: no hay enlaces que verificar.
printf '{"schemaVersion":1,"release":"0.40.2","paths":[],"directories":["."]}\n' > "$CONFIG/.mefisto-projection.json"

context() {
    jq -cn --arg os "$OS_HOME" --arg data "$DATA" --arg config "$CONFIG_HOME" --arg directory "$1" --arg worktree "$2" \
        '{platform:"linux",osHome:$os,home:$os,xdgDataHome:$data,xdgConfigHome:$config,opencodeConfigDir:null,directory:$directory,worktree:$worktree}'
}
request() { # <directory> <worktree> <required-json> [assets-json]
    jq -cn --argjson ctx "$(context "$1" "$2")" --argjson req "$3" --argjson assets "${4:-[]}" '{schemaVersion:1,runtimeContext:$ctx,requiredResources:$req,nugetAssetsFiles:$assets}'
}
BASE='["release","project","state","runtime-tool-output"]'
WITH_NUGET='["release","project","state","runtime-tool-output","nuget-packages"]'
run() { # <project-root> <execution-root> <request-json>
    OUT="$(cd "$WORK" && printf '%s' "$3" | "$RELEASE/scripts/resolve-opencode-resources.sh" --project-root "$1" --worktree-root "$2" 2>"$WORK/stderr")"; RC=$?
}

echo '== Interfaz, protocolo y clausura instalada =='
[ -x "$RELEASE/scripts/resolve-opencode-resources.sh" ] && pass 'el wrapper se distribuye ejecutable en la release' || fail 'wrapper ausente'
set_inspect ready CONSENT_APPROVED 0
run "$MAIN" "$MAIN" 'no-json'; [ "$RC" -eq 2 ] && pass 'stdin invalido sale 2' || fail 'stdin invalido sale 2'
run "$MAIN" "$MAIN" "$(request "$MAIN" "$MAIN" '["release","project","state"]')"; [ "$RC" -eq 2 ] && pass 'falta un recurso base: 2' || fail 'falta un recurso base: 2'
run "$MAIN" "$MAIN" "$(request "$MAIN" "$MAIN" '["release","project","state","runtime-tool-output","/etc"]')"; [ "$RC" -eq 2 ] && pass 'roots arbitrarias en requiredResources: 2' || fail 'roots arbitrarias: 2'
run "$MAIN" "$MAIN" "$(request "$MAIN" "$MAIN" "$BASE" "[\"$MAIN/obj/project.assets.json\"]")"; [ "$RC" -eq 2 ] && pass 'assets sin nuget-packages: 2' || fail 'assets sin nuget-packages: 2'
run "$MAIN" "$MAIN" "$(jq -c '. + {extra:1}' <<< "$(request "$MAIN" "$MAIN" "$BASE")")"; [ "$RC" -eq 2 ] && pass 'campo extra: 2' || fail 'campo extra: 2'
run relativa "$MAIN" "$(request "$MAIN" "$MAIN" "$BASE")"; [ "$RC" -eq 2 ] && pass 'project-root relativo: 2' || fail 'project-root relativo: 2'
mv "$RELEASE/src/published/scripts/adapters/lib/opencode-resources.sh" "$WORK/lib.bak"
run "$MAIN" "$MAIN" "$(request "$MAIN" "$MAIN" "$BASE")"; [ "$RC" -eq 2 ] && pass 'clausura incompleta: 2' || fail 'clausura incompleta: 2'
mv "$WORK/lib.bak" "$RELEASE/src/published/scripts/adapters/lib/opencode-resources.sh"

echo '== Guard de consentimiento =='
UNUSED_DATA="$WORK/sin-roots"
: > "$RELEASE/scripts/inspect.real"
OUT="$(cd "$WORK" && jq -cn --arg d "$MAIN" --arg w "$MAIN" '{schemaVersion:1,runtimeContext:{platform:"linux",osHome:"/inexistente",home:"/inexistente",xdgDataHome:null,xdgConfigHome:null,opencodeConfigDir:null,directory:$d,worktree:$w},requiredResources:["release","project","state","runtime-tool-output"],nugetAssetsFiles:[]}' | "$RELEASE/scripts/resolve-opencode-resources.sh" --project-root "$MAIN" --worktree-root "$MAIN" 2>"$WORK/stderr")"; RC=$?
[ "$RC" -eq 0 ] && pass 'inspect real sin perfil: exit 0' || fail 'inspect real sin perfil: exit 0'
assert_json 'sin perfil: disabled/NO_PROFILE sin recursos ni roots exigidas' '.status=="disabled" and .diagnostics[0].code=="NO_PROFILE" and .resources==[] and .resourcesDigest==null and .nuget==null'
[ ! -e "$MAIN/.mefisto/pipeline" ] && pass 'inspect disabled no crea estado' || fail 'inspect disabled no crea estado'
rm -f "$RELEASE/scripts/inspect.real"
set_inspect needs-approval CONSENT_REQUIRED 1
run "$MAIN" "$MAIN" "$(request "$MAIN" "$MAIN" "$BASE")"
[ "$RC" -eq 1 ] && assert_json 'needs-approval: exit 1 sin snapshot' '.status=="needs-approval" and .resources==[] and .diagnostics[0].code=="CONSENT_REQUIRED"' || fail 'needs-approval: exit 1'
set_inspect disabled CONSENT_REVOKED 0
run "$MAIN" "$MAIN" "$(request "$MAIN" "$MAIN" "$BASE")"
[ "$RC" -eq 0 ] && assert_json 'revocado: disabled/CONSENT_REVOKED distinto de NO_PROFILE' '.status=="disabled" and .diagnostics[0].code=="CONSENT_REVOKED" and .resources==[] and .protectedRoots==[]' || fail 'revocado'
set_inspect conflict INVALID_PROFILE 1
run "$MAIN" "$MAIN" "$(request "$MAIN" "$MAIN" "$BASE")"
[ "$RC" -eq 1 ] && assert_json 'conflicto de inspect propaga el codigo' '.status=="conflict" and .diagnostics[0].code=="INVALID_PROFILE"' || fail 'conflicto de inspect'

echo '== Snapshot ready: principal y worktree registrado =='
set_inspect ready CONSENT_APPROVED 0
snapshot_tree() { (cd "$WORK" && find . -not -name 'tree.*' -not -name stderr | LC_ALL=C sort); }
snapshot_tree > "$WORK/tree.before"
run "$MAIN" "$MAIN" "$(request "$MAIN" "$MAIN" "$BASE")"; MAIN_OUT="$OUT"
[ "$RC" -eq 0 ] && pass 'ready principal: exit 0' || fail "ready principal: exit 0 ($(jq -c .diagnostics <<< "$OUT"))"
assert_json 'envelope cerrado con scope resources' '(keys|sort)==["diagnostics","nuget","permissionBase","profileDigest","project","projectId","projection","protectedRoots","release","resolutionScope","resources","resourcesDigest","schemaVersion","status"]
  and .schemaVersion==1 and .resolutionScope=="resources" and .status=="ready" and .nuget==null'
run "$MAIN" "$LINKED" "$(request "$LINKED" "$LINKED" "$BASE")"; LINKED_OUT="$OUT"
[ "$RC" -eq 0 ] && pass 'ready worktree registrado: exit 0' || fail "ready worktree: exit 0 ($(jq -c .diagnostics <<< "$OUT"))"
[ "$(jq -r .projectId <<< "$MAIN_OUT")" = "$(jq -r .projectId <<< "$LINKED_OUT")" ] && pass 'principal y worktree comparten projectId' || fail 'projectId distinto'
assert_json 'worktree: base y scopes distintos del principal' --argjson main "$MAIN_OUT" '.permissionBase.worktree.physical != $main.permissionBase.worktree.physical and .resourcesDigest != $main.resourcesDigest and (.project.executionRoot != .project.approvedRoot)'
assert_json 'worktree: ejecucion editable y aprobada solo lectura' --arg l "$LINKED" --arg m "$MAIN" '[.resources[] | select(.id=="project")] as $p | ($p | map({(.root):.maxAccess}) | add) == {($l):"project",($m):"read"}'
assert_json 'state: ambas raices .mefisto/pipeline, planned, sin autonomy editable' --arg l "$LINKED" --arg m "$MAIN" '[.resources[] | select(.id=="state")] as $s | ($s | length)==2 and all($s[]; .maxAccess=="state" and .exists==false and (.excludedPaths | any(endswith("/autonomy")))) and ($s | map(.root) | sort)==([$l+"/.mefisto/pipeline",$m+"/.mefisto/pipeline"] | sort)'
assert_json 'projectos: excluyen autonomy y markers de identidad' '[.resources[] | select(.id=="project")] | all(.[]; (.excludedPaths | any(endswith("/.mefisto/pipeline/autonomy"))) and (.excludedPaths | any(endswith("/.mefisto/harness.config.json"))))'
snapshot_tree > "$WORK/tree.after"
cmp -s "$WORK/tree.before" "$WORK/tree.after" && pass 'ready no crea directorios (planned sin mkdir ni legacy)' || fail 'el resolver creo archivos'
[ ! -e "$MAIN/.mefisto/pipeline" ] && [ ! -e "$MAIN/.claude" ] && pass 'sin estado canonico ni escritor legacy' || fail 'estado creado'

echo '== Caso Control Asistencia: absolutos y relativos desde la base real =='
assert_json 'release fisica exacta como recurso read con relativo desde el worktree logico' --arg r "$RELEASE" '[.resources[] | select(.id=="release")] | length==1 and .[0].root==$r and .[0].maxAccess=="read" and .[0].relativeRoot=="../XDG data/mefisto/releases/0.40.2" and .[0].exists==true' <<< "$MAIN_OUT"
OUT="$MAIN_OUT"
assert_json 'tool-output: clase read de toda la carpeta (planned)' --arg t "$DATA/opencode/tool-output" '[.resources[] | select(.id=="runtime-tool-output")] | length==1 and .[0].root==$t and .[0].maxAccess=="read" and .[0].exists==false and .[0].relativeRoot=="../XDG data/opencode/tool-output"'
assert_json 'ni auth, logs, storage, config ni escritura aparecen como grants' --arg d "$DATA/opencode" --arg c "$CONFIG" 'all(.resources[]; .root != $d and .root != $c and (.root|startswith($d+"/storage")|not) and (.root|startswith($d+"/log")|not) and (.root|startswith($c+"/")|not) and (.id != "runtime-tool-output" or .maxAccess=="read") and (.id != "release" or .maxAccess=="read"))'
assert_json 'protectedRoots: config, runtime-data (excepto tool-output), runtime-use y credenciales' --arg c "$CONFIG" --arg d "$DATA/opencode" --arg h "$OS_HOME" --arg s "$STORE" '(.protectedRoots | map({(.id):.root}) | add) as $p | $p.config==$c and $p["runtime-data"]==$d and $p["runtime-use"]==($s+"/runtime-use") and $p.ssh==($h+"/.ssh") and $p.aws==($h+"/.aws") and $p["nuget-config"]==($h+"/.nuget/NuGet") and $p["xdg-nuget-config"]==($h+"/.config/NuGet") and ([.protectedRoots[] | select(.id=="runtime-data") | .exceptions[0]]==[$d+"/tool-output"])'
assert_json 'release y proyecto: observacion de la release cargada' '.release.version=="0.40.2" and (.release.commit|length)==40 and .projection.status=="aligned"'
assert_json 'permissionBase conserva logico y fisico exactos' --arg m "$MAIN" '.permissionBase.worktree=={logical:$m,physical:$m} and .permissionBase.directory==$m'
assert_json 'sin secretos en el envelope' '(tostring | contains("sentinel-secret") | not)'
[ ! -s "$WORK/stderr" ] && pass 'stderr vacio' || fail 'stderr con contenido'

echo '== Aliases de proyecto y symlinks =='
run "$MAIN" "$WORK/alias main" "$(request "$WORK/alias main" "$WORK/alias main" "$BASE")"
[ "$RC" -eq 0 ] && pass 'alias de proyecto observado: ready' || fail "alias: ready ($(jq -c .diagnostics <<< "$OUT"))"
assert_json 'alias verificado con relativo y la raiz fisica conservada' --arg a "$WORK/alias main" --arg m "$MAIN" '[.resources[] | select(.id=="project" and .root==$m)][0].aliases==[{root:$a,relativeRoot:""}] and (.permissionBase.worktree.logical==$a and .permissionBase.worktree.physical==$m)'
mkdir -p "$WORK/outside-state"; ln -s "$WORK/outside-state" "$LINKED/.mefisto/pipeline"
run "$MAIN" "$LINKED" "$(request "$LINKED" "$LINKED" "$BASE")"
[ "$RC" -eq 1 ] && assert_json 'state por symlink fuera del proyecto: conflicto' '.status=="conflict" and .diagnostics[0].code=="STATE_ROOT_ESCAPES_PROJECT" and .resources==[]' || fail 'state con symlink externo'
rm "$LINKED/.mefisto/pipeline"
mkdir -p "$LINKED/.claude/pipeline"
run "$MAIN" "$LINKED" "$(request "$LINKED" "$LINKED" "$BASE")"
assert_json 'fallback legacy solo lectura cuando falta el canonico' --arg l "$LINKED/.claude/pipeline" '[.resources[] | select(.id=="state" and .root==$l)] | length==1 and .[0].maxAccess=="read" and .[0].provenance.state=="legacy-fallback"'
rm -rf "$LINKED/.claude"

echo '== Identidad: clones, rutas ajenas y contexto =='
run "$MAIN" "$OTHER" "$(request "$OTHER" "$OTHER" "$BASE")"
[ "$RC" -eq 1 ] && assert_json 'otro clon con el mismo remote no se admite' '.status=="conflict" and .diagnostics[0].code=="PROJECT_IDENTITY_MISMATCH" and .resources==[]' || fail 'otro clon admitido'
mkdir -p "$MAIN/sub"
run "$MAIN" "$MAIN/sub" "$(request "$MAIN/sub" "$MAIN" "$BASE")"
[ "$RC" -eq 1 ] && assert_json 'execution-root que no es raiz de worktree: conflicto' '.status=="conflict" and .diagnostics[0].code=="PROJECT_ROOT_NOT_WORKTREE_ROOT"' || fail 'subdirectorio admitido'
mkdir -p "$WORK/hermano"; git -C "$MAIN" init -q "$WORK/hermano" 2>/dev/null
run "$MAIN" "$WORK/hermano" "$(request "$WORK/hermano" "$WORK/hermano" "$BASE")"
[ "$RC" -eq 1 ] && assert_json 'ruta hermana ajena no se admite' '.status=="conflict" and .resources==[]' || fail 'ruta hermana admitida'
git -C "$MAIN" worktree add -q "$WORK/no registrado" -b noreg 2>/dev/null && git -C "$MAIN" worktree remove --force "$WORK/no registrado" 2>/dev/null
mkdir -p "$WORK/tmux-root"
run "$MAIN" "$WORK/tmux-root" "$(request "$MAIN" "$MAIN" "$BASE")"
[ "$RC" -eq 1 ] && assert_json 'raiz heredada inexistente/no git: conflicto' '.status=="conflict" and .resources==[]' || fail 'raiz heredada admitida'
run "$MAIN" "$MAIN" "$(request "$OTHER" "$OTHER" "$BASE")"
[ "$RC" -eq 1 ] && assert_json 'contexto OpenCode de otro clon: conflicto' '.status=="conflict" and .diagnostics[0].code=="PROJECT_IDENTITY_MISMATCH"' || fail 'contexto ajeno admitido'
run "$MAIN" "$MAIN" "$(request "$WORK" "$MAIN" "$BASE")"
[ "$RC" -eq 1 ] && assert_json 'directory fuera del worktree: conflicto' '.status=="conflict" and .diagnostics[0].code=="DIRECTORY_OUTSIDE_WORKTREE"' || fail 'directory ajeno admitido'

echo '== Digest =='
run "$MAIN" "$MAIN" "$(request "$MAIN" "$MAIN" "$BASE")"; D0="$(jq -r .resourcesDigest <<< "$OUT")"
mkdir -p "$DATA/opencode/tool-output"; printf 'a\n' > "$DATA/opencode/tool-output/tool_1"; printf 'b\n' > "$DATA/opencode/tool-output/tool_2"
run "$MAIN" "$MAIN" "$(request "$MAIN" "$MAIN" "$BASE")"
[ "$(jq -r .resourcesDigest <<< "$OUT")" = "$D0" ] && pass 'digest estable ante planned->existente y nuevos archivos tool-output' || fail 'digest cambio por tool-output'
assert_json 'la raiz de tool-output ahora existe sin deriva' '[.resources[] | select(.id=="runtime-tool-output")][0].exists==true'
printf '{"schemaVersion":1,"release":"0.40.2","paths":[],"directories":[".","commands"]}\n' > "$CONFIG/.mefisto-projection.json"
run "$MAIN" "$MAIN" "$(request "$MAIN" "$MAIN" "$BASE")"
[ "$(jq -r .resourcesDigest <<< "$OUT")" != "$D0" ] && pass 'digest cambia con el ledger determinante' || fail 'digest igual ante otro ledger'
printf '{"schemaVersion":1,"release":"0.40.2","paths":[],"directories":["."]}\n' > "$CONFIG/.mefisto-projection.json"
run "$MAIN" "$MAIN" "$(request "$MAIN" "$MAIN" "$BASE")"
[ "$(jq -r .resourcesDigest <<< "$OUT")" = "$D0" ] && pass 'revalidar con el mismo alcance reproduce el digest' || fail 'digest no reproducible'
run "$MAIN" "$MAIN" "$(request "$MAIN" "$WORK/alias main" "$BASE")"
[ "$(jq -r .resourcesDigest <<< "$OUT")" != "$D0" ] || [ "$RC" -ne 0 ] && pass 'digest o resultado cambian con otra base' || fail 'digest igual con otra base'
run "$MAIN" "$MAIN" "$(request "$MAIN" "$WORK/alias main" "$BASE")"
D_ALIAS="$(jq -r .resourcesDigest <<< "$OUT")"
run "$MAIN" "$MAIN" "$(request "$MAIN" "$MAIN" "$BASE")"
[ "$D_ALIAS" != "$D0" ] && pass 'la base logica forma parte del digest' || fail 'base logica fuera del digest'
set_inspect ready CONSENT_APPROVED 0
jq -c '.profileDigest=("b" * 64)' "$RELEASE/scripts/inspect.json" > "$WORK/i.json" && mv "$WORK/i.json" "$RELEASE/scripts/inspect.json"
run "$MAIN" "$MAIN" "$(request "$MAIN" "$MAIN" "$BASE")"
[ "$(jq -r .resourcesDigest <<< "$OUT")" != "$D0" ] && [ "$(jq -r .profileDigest <<< "$OUT")" = "$(printf 'b%.0s' $(seq 64))" ] && pass 'digest cambia con el perfil' || fail 'digest igual con otro perfil'
set_inspect ready CONSENT_APPROVED 0

echo '== Projection y release =='
ACTIVE_BEFORE="$(readlink "$STORE/active")"
printf '{"schemaVersion":1,"release":"0.40.1","paths":[],"directories":["."]}\n' > "$CONFIG/.mefisto-projection.json"
run "$MAIN" "$MAIN" "$(request "$MAIN" "$MAIN" "$BASE")"
[ "$RC" -eq 1 ] && assert_json 'projection drift impide ready' '.status=="conflict" and .projection.status=="drift" and .resources==[]' || fail 'drift admitido'
[ "$(readlink "$STORE/active")" = "$ACTIVE_BEFORE" ] && pass 'drift no cambia active ni adopta otra release' || fail 'active cambio'
mv "$CONFIG/.mefisto-projection.json" "$WORK/ledger.bak"
run "$MAIN" "$MAIN" "$(request "$MAIN" "$MAIN" "$BASE")"
[ "$RC" -eq 1 ] && assert_json 'projection ausente impide ready' '.status=="conflict" and .diagnostics[-1].code=="PROJECTION_ABSENT"' || fail 'ausente admitido'
mv "$WORK/ledger.bak" "$CONFIG/.mefisto-projection.json"
printf '{"schemaVersion":1,"release":"0.40.2","paths":[],"directories":["."]}\n' > "$CONFIG/.mefisto-projection.json"

echo '== NuGet =='
set_nuget "$(nuget_doc resolved global-only "[$(nuget_row "$OS_HOME/.nuget/packages" false '[{"kind":"cli"}]')]" '[]')" 0
rm -f "$RELEASE/scripts/nuget.args"
run "$MAIN" "$MAIN" "$(request "$MAIN" "$MAIN" "$BASE")"
[ ! -e "$RELEASE/scripts/nuget.args" ] && assert_json 'NuGet omitido: no se consulta ni hay filas' '.nuget==null and ([.resources[].id] | index("nuget-packages")) == null' || fail 'NuGet omitido se consulto'
run "$MAIN" "$LINKED" "$(request "$LINKED" "$LINKED" "$WITH_NUGET" "[\"$LINKED/obj/project.assets.json\"]")"
[ "$RC" -eq 0 ] && pass 'NuGet requerido global-only: ready' || fail "NuGet global-only ($(jq -c .diagnostics <<< "$OUT"))"
assert_json 'NuGet global-only: coverage y fila read con procedencia' --arg p "$OS_HOME/.nuget/packages" '.nuget.coverage=="global-only" and [.resources[] | select(.id=="nuget-packages")] as $n | ($n|length)==1 and $n[0].root==$p and $n[0].maxAccess=="read" and $n[0].aliases==[] and $n[0].provenance.sources==[{kind:"cli"}]'
grep -q -- "--worktree-root $LINKED --assets-file $LINKED/obj/project.assets.json" "$RELEASE/scripts/nuget.args" && pass 'NuGet recibe execution-root y assets explicitos' || fail 'argv de NuGet'
G_DIGEST="$(jq -r .resourcesDigest <<< "$OUT")"
C64="$(printf 'c%.0s' $(seq 64))"
set_nuget "$(nuget_doc resolved observed-assets "[$(nuget_row "$OS_HOME/.nuget/packages" false "$(jq -cn --arg h "$C64" '[{kind:"cli"},{kind:"assets",assetsFile:"obj/project.assets.json",sha256:$h}]')"),$(nuget_row "$WORK/paquetes extra" true '[]')]" "$(jq -cn --arg h "$C64" '[{path:"obj/project.assets.json",sha256:$h,roots:[]}]')")" 0
run "$MAIN" "$LINKED" "$(request "$LINKED" "$LINKED" "$WITH_NUGET")"
assert_json 'NuGet observed-assets: filas multiples y hashes conservados' '.nuget.coverage=="observed-assets" and ([.resources[] | select(.id=="nuget-packages")] | length)==2 and .nuget.assets[0].path=="obj/project.assets.json"'
[ "$(jq -r .resourcesDigest <<< "$OUT")" != "$G_DIGEST" ] && pass 'digest distingue global-only de observed-assets' || fail 'digest igual por cobertura'
for bad in "$WORK" / "$OS_HOME" "$CONFIG" "$DATA/opencode/storage" "$OS_HOME/.nuget/NuGet/cache" "$OS_HOME/.ssh" "$LINKED" "$MAIN/.." "$WORK/con*glob" "$WORK/con?signo" "$WORK/con\\barra"; do
    set_nuget "$(nuget_doc resolved global-only "[$(nuget_row "$bad" true '[]')]" '[]')" 0
    run "$MAIN" "$LINKED" "$(request "$LINKED" "$LINKED" "$WITH_NUGET")"
    [ "$RC" -eq 1 ] && jq -e '.status=="conflict" and .resources==[]' >/dev/null <<< "$OUT" && pass "NuGet root rechazada: ${bad##*/}" || fail "NuGet root admitida: $bad"
done
set_nuget "$(nuget_doc unavailable global-only '[]' '[]')" 1
run "$MAIN" "$LINKED" "$(request "$LINKED" "$LINKED" "$WITH_NUGET")"
[ "$RC" -eq 1 ] && assert_json 'NuGet no disponible: conflicto sin fallback a home' '.status=="conflict" and .diagnostics[-1].code=="NUGET_UNAVAILABLE" and .resources==[]' || fail 'unavailable admitido'
set_nuget 'basura' 0
run "$MAIN" "$LINKED" "$(request "$LINKED" "$LINKED" "$WITH_NUGET")"
[ "$RC" -eq 1 ] && assert_json 'salida NuGet invalida: conflicto sin volcar la salida' '.diagnostics[-1].code=="NUGET_OUTPUT_INVALID" and (tostring | contains("basura") | not)' || fail 'salida invalida'

echo '== Aislamiento del flujo Claude =='
# Excepcion por ruta exacta (#1860/#1966): run-published-agent.sh es parte de la
# clausura compartida, es solo de ese runtime (RUNTIME_MISMATCH) y bajo Claude
# no se alcanza: sin contexto transportado se conserva el camino legacy
# (cubierto en test-pipeline-execution-wiring.sh).
claude_resolver_refs() {
    local root="$1"
    grep -rl 'resolve-opencode-resources\|opencode-resources.sh' "$root/dist/claude" "$root/agents" "$root/commands" "$root/hooks" 2>/dev/null \
        | grep -vxF "$root/dist/claude/scripts/run-published-agent.sh" || true
}
[ -z "$(claude_resolver_refs "$REPO_ROOT")" ] && pass 'dist/claude, mirrors y hooks no dependen del resolver' || fail 'Claude depende del resolver'
ISO="$WORK/iso"; mkdir -p "$ISO/dist/claude/scripts" "$ISO/agents" "$ISO/commands" "$ISO/hooks"
printf 'RESOLVE_RES=resolve-opencode-resources.sh\n' > "$ISO/dist/claude/scripts/run-published-agent.sh"
[ -z "$(claude_resolver_refs "$ISO")" ] && pass 'excepcion exacta: run-published-agent.sh se tolera' || fail 'excepcion no aplicada'
printf 'x opencode-resources.sh\n' > "$ISO/dist/claude/scripts/otro.sh"
[ -n "$(claude_resolver_refs "$ISO")" ] && pass 'otra mencion en dist/claude sigue fallando' || fail 'otra mencion en dist/claude tolerada'
rm -f "$ISO/dist/claude/scripts/otro.sh"
printf 'resolve-opencode-resources\n' > "$ISO/hooks/h.sh"
[ -n "$(claude_resolver_refs "$ISO")" ] && pass 'mencion en hooks sigue fallando' || fail 'mencion en hooks tolerada'
grep -q 'RUNTIME_MISMATCH' "$REPO_ROOT/dist/claude/scripts/run-published-agent.sh" && pass 'la excepcion sigue justificada: RUNTIME_MISMATCH presente' || fail 'run-published-agent.sh sin RUNTIME_MISMATCH'
! grep -q 'resolve-opencode-resources\|opencode-resources' "$HERE/test-adapter-claude.sh" && pass 'test-adapter-claude no depende del resolver' || fail 'test-adapter-claude depende del resolver'

echo "Resultado: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
