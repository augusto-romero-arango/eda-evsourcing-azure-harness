#!/usr/bin/env bash
# Contrato de permisos efectivos (issue #1750): cada comando bash que el
# artefacto OpenCode generado de test-writer ejecuta (preambulo de release y
# bloque `test -f`) debe pasar permission.bash de su propio frontmatter.
# Simula la evaluacion documentada en src/published/contract/README.md: un
# candidato por nodo `command`, ultima coincidencia, `*` cruza `/`, comillas
# literales. No ejecuta ningun runtime real. Uso: [artefacto.md]
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
ARTIFACT="${1:-$REPO_ROOT/dist/opencode/agents/test-writer.md}"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

command -v python3 >/dev/null 2>&1 || { printf '%s\n' 'ERROR: se requiere python3'; exit 1; }
[ -f "$ARTIFACT" ] || { printf 'ERROR: no existe el artefacto %s\n' "$ARTIFACT"; exit 1; }

PY="$(mktemp)"; trap 'rm -f "$PY"' EXIT
cat > "$PY" <<'PYEOF'
import json, re, sys

KEYWORDS = {"if", "then", "elif", "else", "fi", "do", "done", "{", "}", "!", "esac"}

def first_word(seg):
    i, n, q = 0, len(seg), None
    while i < n:
        c = seg[i]
        if q:
            if c == q: q = None
            elif c == "\\" and q == '"': i += 1
        elif c in "\"'": q = c
        elif c.isspace(): break
        i += 1
    return seg[:i], seg[i:].lstrip()

def clean(seg, out):
    seg = seg.strip()
    while True:
        m = re.match(r"^[^\s()'\"]*\)\s*", seg)  # patron de case: `*) ...`
        if m and not seg.startswith("("):
            seg = seg[m.end():]
        word, rest = first_word(seg)
        if word in KEYWORDS:
            seg = rest; continue
        if word == "case":
            return
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", word):
            seg = rest
            if not seg: return
            continue
        break
    seg = re.sub(r"(\s+\d*>+&?\S*)+\s*$", "", seg).strip()
    if seg: out.append(seg)

def scan(text, out):
    i, n, buf, q = 0, len(text), [], None
    def flush():
        clean("".join(buf), out); buf.clear()
    while i < n:
        c = text[i]
        if q == "'":
            buf.append(c)
            if c == "'": q = None
            i += 1; continue
        if c == "\\" and i + 1 < n:
            buf.append(text[i:i+2]); i += 2; continue
        if text.startswith("$(", i):
            depth, j, qq = 1, i + 2, None
            while j < n and depth:
                d = text[j]
                if qq:
                    if d == qq: qq = None
                    elif d == "\\" and qq == '"': j += 1
                elif d in "\"'": qq = d
                elif d == "(": depth += 1
                elif d == ")": depth -= 1
                j += 1
            scan(text[i+2:j-1], out)
            buf.append(text[i:j]); i = j; continue
        if q == '"':
            buf.append(c)
            if c == '"': q = None
            i += 1; continue
        if c in "\"'":
            q = c; buf.append(c); i += 1; continue
        if c == "#" and (not buf or "".join(buf).strip() == "" or buf[-1].isspace()):
            while i < n and text[i] != "\n": i += 1
            continue
        if c == "\n" or c == ";" or c == "|" or (c == "&" and not text.startswith(">&", i - 1) and not (i + 1 < n and text[i+1] == ">")):
            if c == ">": pass
            if text.startswith("&&", i) or text.startswith("||", i) or text.startswith(";;", i): i += 1
            elif c == "&" and i > 0 and text[i-1] in "<>": buf.append(c); i += 1; continue
            flush(); i += 1; continue
        buf.append(c); i += 1
    flush()

def blocks(path):
    res, cur, inside = [], [], False
    for line in open(path, encoding="utf-8").read().split("\n"):
        if line == "```bash": inside, cur = True, []
        elif line == "```" and inside: res.append("\n".join(cur)); inside = False
        elif inside: cur.append(line)
    return res

def frontmatter_permission(path):
    for line in open(path, encoding="utf-8"):
        if line.startswith("permission: "): return json.loads(line[len("permission: "):])["bash"]
    raise SystemExit("sin permission en el frontmatter")

def allowed(rules, cand):
    verdict = None
    for pat, val in rules.items():
        rx = "^" + ".*".join(re.escape(p) for p in pat.split("*")) + "$"
        if re.match(rx, cand, re.S): verdict = val
    return verdict

def main():
    mode, path = sys.argv[1], sys.argv[2]
    rules = frontmatter_permission(path)
    if mode == "rules":
        print(json.dumps(rules)); return
    if mode == "eval":
        print(allowed(rules, sys.argv[3])); return
    cands = []
    for b in blocks(path):
        if "mefisto_opencode_launcher" in b or re.search(r"^test -f ", b, re.M):
            sub = []; scan(b, sub); cands += sub
    for c in cands:
        print(("ALLOW\t" if allowed(rules, c) == "allow" else "DENY\t") + c)

main()
PYEOF

printf '%s\n' '[contrato] comandos del preambulo y del bloque test -f contra permission.bash'
listing="$(python3 "$PY" candidates "$ARTIFACT")" || { fail 'no se pudo extraer los comandos del artefacto'; listing=''; }
total="$(printf '%s\n' "$listing" | grep -c .)"
[ "$total" -ge 10 ] && pass "se extrajeron $total comandos del artefacto" || fail "extraccion sospechosamente corta ($total comandos)"
printf '%s\n' "$listing" | grep -q 'package-root' && printf '%s\n' "$listing" | grep -q '^ALLOW.test -f ' && pass 'la extraccion incluye el lanzador y el bloque test -f' || fail 'la extraccion omite el lanzador o el bloque test -f'
denied="$(printf '%s\n' "$listing" | grep '^DENY' | cut -f2-)"
if [ -z "$denied" ]; then
    pass 'todos los comandos del preambulo y del bloque test -f estan permitidos'
else
    fail "comandos denegados por permission.bash: $(printf '%s' "$denied" | tr '\n' '|')"
fi
grep -qi 'cada llamada bash que use' "$ARTIFACT" && pass 'el preambulo declara que se repite en cada llamada bash' || fail 'el preambulo no declara su repeticion por llamada bash'

printf '%s\n' '[contrato] deny por defecto y comandos arbitrarios'
rules="$(python3 "$PY" rules "$ARTIFACT")"
[ "$(jq -r 'keys_unsorted[0]' <<< "$rules")" = '*' ] && [ "$(jq -r '.["*"]' <<< "$rules")" = deny ] && pass 'permission.bash abre con "*":"deny"' || fail 'permission.bash no abre con "*":"deny"'
for forbidden in '*' 'bash *' 'sh *' 'eval *' 'env *'; do
    if [ "$forbidden" = '*' ]; then continue; fi
    jq -e --arg k "$forbidden" 'has($k) | not' <<< "$rules" >/dev/null && pass "sin regla '$forbidden'" || fail "regla prohibida '$forbidden'"
done
for cmd in 'bash -c x' 'eval x' 'curl x' 'rm -rf /' 'sh -c x' 'env x'; do
    [ "$(python3 "$PY" eval "$ARTIFACT" "$cmd")" = deny ] && pass "'$cmd' sigue denegado" || fail "'$cmd' dejo de estar denegado"
done
for keep in 'rm *' 'curl *' 'ssh *' 'scp *' 'sudo *'; do
    jq -e --arg k "$keep" '.[$k] == "deny"' <<< "$rules" >/dev/null && pass "denegacion explicita '$keep' conservada" || fail "falta la denegacion explicita '$keep'"
done

printf '\n%s PASS, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
