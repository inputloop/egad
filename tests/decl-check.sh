#!/bin/sh
# decl-check.sh -- the declarative layer, read twice.  For every decl/examples/*.org:
#   1. Python: org -> json -> org -> json is the identity;
#   2. Python and Emacs Lisp (written apart, sharing no parser) turn it into the same JSON;
#   3. Emacs Lisp writes Org from Python's JSON, and Python reads that back to the same JSON;
# and every decl/refuse/*.org is refused by both readers.
# Without Emacs, steps 2-3 and the Emacs half of the refusals print NOT CHECKED (never a pass).
# usage: sh tests/decl-check.sh [--prove-red]     (--prove-red: a planted Python mutant must turn step 2 red)
# Copyright (C) 2026 Corwin Brust <corwin@bru.st>.  SPDX-License-Identifier: GPL-3.0-or-later.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 2
EMACS=${EMACS:-emacs}
t=$(mktemp -d) || exit 2; trap 'rm -rf "$t"' EXIT
fail=0; nc=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
have_emacs() { "$EMACS" --batch -Q --eval '(kill-emacs 0)' >/dev/null 2>&1; }
same() { python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))==json.load(open(sys.argv[2])) else 1)' "$1" "$2"; }
run() { # PY (path to the python reader under test)
  py=$1; fail=0
  for f in "$here"/decl/examples/*.org; do
    b=$(basename "$f")
    python3 "$py" roundtrip "$f" >/dev/null 2>&1 && ok "$b: python round trip" || bad "$b: python round trip"
    python3 "$py" to-json "$f" > "$t/py.json" 2>/dev/null || { bad "$b: python to-json"; continue; }
    if have_emacs; then
      "$EMACS" --batch -Q -l "$here/decl/egad-decl.el" --eval "(egad-decl-cli-to-json \"$f\")" > "$t/el.json" 2>/dev/null \
        && same "$t/py.json" "$t/el.json" && ok "$b: python and elisp agree" || bad "$b: python and elisp disagree"
      "$EMACS" --batch -Q -l "$here/decl/egad-decl.el" --eval "(egad-decl-cli-to-org \"$t/py.json\")" > "$t/el.org" 2>/dev/null \
        && python3 "$py" to-json "$t/el.org" > "$t/back.json" 2>/dev/null && same "$t/py.json" "$t/back.json" \
        && ok "$b: elisp writes, python reads back the same" || bad "$b: elisp-written Org does not read back"
    else nc=$((nc+2)); echo "NOT CHECKED $b: python/elisp agreement (no Emacs at '$EMACS')"; fi
  done
  for f in "$here"/decl/refuse/*.org; do
    b=$(basename "$f")
    python3 "$py" to-json "$f" >/dev/null 2>&1 && bad "$b: python accepted" || ok "$b: python refuses"
    if have_emacs; then
      "$EMACS" --batch -Q -l "$here/decl/egad-decl.el" --eval "(egad-decl-cli-to-json \"$f\")" >/dev/null 2>&1 \
        && bad "$b: elisp accepted" || ok "$b: elisp refuses"
    else nc=$((nc+1)); fi
  done
  return $fail
}
if [ "${1:-}" = --prove-red ]; then
  have_emacs || { echo "NOT CHECKED prove-red needs Emacs (the mutant is caught by the elisp reader)"; exit 77; }
  sed "s/if raw == 'nil':/if raw == 'nil-never':/" "$here/decl/egad-decl.py" > "$t/mutant.py"
  if run "$t/mutant.py" >/dev/null; then echo "FAIL prove-red: a reader that keeps 'nil' as a string passed"; exit 1; fi
  echo "ok   prove-red: a mutant python reader (nil read as a string) turns the check red"
fi
run "$here/decl/egad-decl.py"; r=$?
[ "$nc" -gt 0 ] && echo "NOT CHECKED: $nc check(s) need Emacs; what ran passed or failed as shown"
[ $r -eq 0 ] && [ "$nc" -eq 0 ] && echo "ALL DECL CHECKS PASSED"; [ $r -eq 0 ] && [ "$nc" -gt 0 ] && echo "DECL CHECKS PASSED WHERE RUN" ; [ $r -ne 0 ] && echo "DECL CHECKS FAILED"
exit $r
