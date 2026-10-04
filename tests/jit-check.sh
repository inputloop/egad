#!/bin/sh
# jit-check.sh -- two independent tanglers must agree.
#   jit/unpack.py (Python, this project) and org-babel-tangle (Emacs Lisp, GNU Org) are
#   run on the same literate file; every form they produce must be byte-identical.
#   Then the resolver's three documented outcomes are asserted.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
tmp="$here/tests/tmp-jit"; rm -rf "$tmp"; mkdir -p "$tmp/py" "$tmp/org"
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "--- unpack.py"
python3 "$here/jit/unpack.py" "$here/jit/treatments/await.org" --out "$tmp/py" >/dev/null

echo "--- org-babel-tangle (Emacs)"
cp "$here/jit/treatments/await.org" "$tmp/org/await.org"
emacs --batch -Q --eval "(progn (require 'org) (require 'ob-tangle)
  (setq org-confirm-babel-evaluate nil org-babel-tangle-use-relative-file-links nil)
  (org-babel-tangle-file \"$tmp/org/await.org\"))" >"$tmp/org.log" 2>&1 || { tail -5 "$tmp/org.log"; fail "org tangle"; }

echo "--- compare"
n=0
for f in $(cd "$tmp/py" && find . -type f ! -name jit-index.json | sort); do
  [ -f "$tmp/org/$f" ] || fail "Org did not produce $f"
  cmp -s "$tmp/py/$f" "$tmp/org/$f" || { diff "$tmp/py/$f" "$tmp/org/$f" | head -5; fail "$f differs between unpack.py and org-babel-tangle"; }
  n=$((n+1))
done
extra=$(cd "$tmp/org" && find . -type f ! -name await.org | wc -l)
[ "$extra" -eq "$n" ] || fail "Org produced $extra files, unpack.py $n"
echo "$n forms identical from both tanglers"

echo "--- resolver outcomes"
r() { python3 "$here/jit/resolve.py" "$tmp/py/forest" "$@" | head -1; }
r "$here/jit/viewers/bram.json"                                   | grep -q -- '-> spinner'  || fail "bram alone should get spinner"
r "$here/jit/viewers/alice.json" "$here/jit/viewers/bram.json"    | grep -q -- '-> progress' || fail "alice+bram should get progress"
r "$here/jit/viewers/chen.json"                                   | grep -q -- '-> progress' || fail "chen should get progress"
r "$here/jit/viewers/alice.json" "$here/jit/viewers/chen.json" "$here/jit/viewers/bram.json" | grep -q -- '-> progress' || fail "all three should get progress"
echo "resolver: 4 documented outcomes hold"

echo "--- drift check is honest"
printf '/* x */\n' >> "$tmp/py/await/pulse.css"
if python3 "$here/jit/unpack.py" "$here/jit/treatments/await.org" --out "$tmp/py" --check >/dev/null; then fail "--check missed a drifted form"; fi
echo "--check caught the drift"
echo "ALL JIT CHECKS PASSED"
