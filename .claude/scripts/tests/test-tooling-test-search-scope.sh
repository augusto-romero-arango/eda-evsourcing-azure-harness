#!/usr/bin/env bash
# Fija que los prompts de Stage 1 (writer) y Stage 2 (reviewer) buscan tests en src/published/scripts/tests/.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
F="$ROOT/src/internal/scripts/mefisto-tooling-pipeline.sh"
fail=0
lines=($(grep -n "corre UNA vez" "$F" | cut -d: -f1))
if [ "${#lines[@]}" -ne 2 ]; then
  echo "FAIL: se esperaban 2 bloques, hay ${#lines[@]}"; exit 1
fi
texts=()
for n in "${lines[@]}"; do
  line="$(sed -n "${n}p" "$F")"
  texts+=("$line")
  case "$line" in
    *"src/published/scripts/tests/"*) echo "PASS: bloque l.$n nombra src/published/scripts/tests/" ;;
    *) echo "FAIL: bloque l.$n no nombra src/published/scripts/tests/"; fail=1 ;;
  esac
  case "$line" in
    *shim*"sin duplicarla"*) echo "PASS: bloque l.$n aclara el shim" ;;
    *) echo "FAIL: bloque l.$n no aclara el shim"; fail=1 ;;
  esac
done
if [ "${texts[0]}" != "${texts[1]}" ]; then echo "FAIL: los dos bloques difieren"; fail=1; else echo "PASS: bloques identicos"; fi
exit $fail
