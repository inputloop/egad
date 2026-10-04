#!/bin/sh
# hello-check.sh -- hello-egad, read three ways, must agree:
#   1. the two tanglers (jit/unpack.py; org-babel-tangle in Emacs) write identical files;
#   2. every var(--egad-*) the page's forms use exists in the generated token stylesheet;
#   3. what the page says (heading, waiting and done messages) is what the greeting's keys say, read by the
#      declarative layer; and, with Emacs, M-x hello-egad says the same text, read by the elisp reader.
# Without Emacs, the Emacs halves print NOT CHECKED.  usage: sh tests/hello-check.sh [--prove-red] [ORG]
# Copyright (C) 2026 Corwin Brust <corwin@bru.st>.  SPDX-License-Identifier: GPL-3.0-or-later.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 2
EMACS=${EMACS:-emacs}
t=$(mktemp -d) || exit 2; trap 'rm -rf "$t"' EXIT
have_emacs() { "$EMACS" --batch -Q --eval '(kill-emacs 0)' >/dev/null 2>&1; }
check() { # ORG OUTDIR -> 0 when everything agrees
  c_org=$1; o=$2; f=0; mkdir -p "$o/py" "$o/org"
  python3 "$here/jit/unpack.py" "$c_org" --out "$o/py" >/dev/null || { echo "FAIL unpack.py could not tangle"; return 1; }
  if have_emacs; then
    cp "$c_org" "$o/org/hello-egad.org"
    "$EMACS" --batch -Q --eval "(progn (require 'org) (require 'ob-tangle) (setq org-confirm-babel-evaluate nil)
      (org-babel-tangle-file \"$o/org/hello-egad.org\"))" >/dev/null 2>&1 || { echo "FAIL org-babel-tangle"; f=1; }
    for x in hello.html hello.css hello.js hello-egad.el; do
      cmp -s "$o/py/$x" "$o/org/$x" || { echo "FAIL $x differs between the two tanglers"; f=1; }
    done
    [ $f = 0 ] && echo "ok   4 forms identical from both tanglers"
  else echo "NOT CHECKED the two tanglers agree (no Emacs)"; fi
  [ -f "$here/dist/css/egad-tokens.css" ] || python3 "$here/emit/emit.py" >/dev/null
  missing=$(grep -ho 'var(--egad-[a-z0-9-]*)' "$o/py/hello.css" "$o/py/hello.html" | sed 's/var(\(.*\))/\1/' | sort -u |
    while read -r v; do grep -q -- "^ *$v:" "$here/dist/css/egad-tokens.css" || echo "$v"; done)
  [ -z "$missing" ] && echo "ok   every token the page names exists" || { echo "FAIL tokens that do not exist: $missing"; f=1; }
  python3 "$here/decl/egad-decl.py" to-json "$c_org" > "$o/g.json" || { echo "FAIL the declarative layer refused the file"; return 1; }
  py=$(python3 - "$o/g.json" "$o/py/hello.html" "$o/py/hello.js" <<'PY'
import json, sys, re
g = next(n for n in json.load(open(sys.argv[1])) if n['title'] == 'greeting')['props']
html, js = open(sys.argv[2], encoding='utf-8').read(), open(sys.argv[3], encoding='utf-8').read()
bad = []
m = re.search(r'<h1 data-egad-greeting>(.*?)</h1>', html)
if not m or m.group(1) != g['text']: bad.append('heading')
if '"%s"' % g['await-message'] not in js: bad.append('waiting message')
if '"%s"' % g['done-message'] not in js: bad.append('done message')
print(' '.join(bad))
PY
)
  [ -z "$py" ] && echo "ok   the page says what the greeting's keys say" || { echo "FAIL the page and the keys disagree: $py"; f=1; }
  if have_emacs; then
    said=$("$EMACS" --batch -Q -L "$here/decl" -L "$o/py" --eval "(progn (require 'hello-egad) (princ (hello-egad-greeting \"$c_org\")))" 2>/dev/null)
    want=$(python3 -c 'import json,sys; print(next(n for n in json.load(open(sys.argv[1])) if n["title"]=="greeting")["props"]["text"])' "$o/g.json")
    [ "$said" = "$want" ] && echo "ok   M-x hello-egad says it too ($said)" || { echo "FAIL Emacs said '$said', the keys say '$want'"; f=1; }
  else echo "NOT CHECKED M-x hello-egad (no Emacs)"; fi
  return $f
}
org=${2:-$here/hello/hello-egad.org}
if [ "${1:-}" = --prove-red ]; then
  sed 's/var(--egad-canvas)/var(--egad-canvas-nope)/' "$org" > "$t/r1.org"
  check "$t/r1.org" "$t/r1" >/dev/null && { echo "FAIL prove-red: a token that does not exist passed"; exit 1; }
  sed 's/^:text: Hello, egad$/:text: Goodbye, egad/' "$org" > "$t/r2.org"
  check "$t/r2.org" "$t/r2" >/dev/null && { echo "FAIL prove-red: a greeting the page does not say passed"; exit 1; }
  echo "ok   prove-red: a missing token and a changed greeting each turn the check red"
fi
check "$org" "$t/real" && echo "HELLO-EGAD CHECKS PASSED" || { echo "HELLO-EGAD CHECKS FAILED"; exit 1; }
