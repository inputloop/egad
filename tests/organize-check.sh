#!/bin/sh
# organize-check.sh -- card 3, as checks.  Tangles hello/hello-egad.org, then plays a scripted session for two people
# in a temp dir and holds the organiser to what the card and MODEL.org say:
#   O1 AGENDA is normally open: another person sees a new item;  O2 MOOD is normally closed: nobody else sees a mood
#   O3 sharing a mood is refused before opt-in, and without a confirm; O4 a remembered yes stops the asking, for that
#      destination only;  O5 pmo rows have the ledger's six columns;  O6 epmo moves a shared mood to the other person,
#      and only to the destination it was shared with;  O7 replay rebuilds every file from the tracks; O8 a file edited
#      outside the tracks is found;  O9 (with Emacs) the elisp reader reads tracks.org as the Python one does.
# usage: sh tests/organize-check.sh [--prove-red]   (--prove-red: a mutant view that shows every mood must go red)
# Copyright (C) 2026 Corwin Brust <corwin@bru.st>.  SPDX-License-Identifier: GPL-3.0-or-later.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 2
EMACS=${EMACS:-emacs}
t=$(mktemp -d) || exit 2; trap 'rm -rf "$t"' EXIT
export EGAD_DECL="$here/decl" EGAD_NOW=2026-10-04T12:00:00Z
python3 "$here/jit/unpack.py" "$here/hello/hello-egad.org" --out "$t/forms" >/dev/null || { echo "FAIL tangle"; exit 1; }
play() { # ORG_PY -> 0 when every property holds
  P="python3 $1"; A="$t/run/alice"; B="$t/run/bram"; rm -rf "$t/run"; f=0
  ok() { echo "ok   $1"; }; no() { echo "FAIL $1"; f=1; }
  EGAD_USER=alice $P capture "$A" agenda Call the plumber priority=A project=house >/dev/null
  EGAD_USER=alice $P capture "$A" mood Tired but hopeful feeling=tired >/dev/null
  v=$($P view "$A" who=bram)
  case $v in *'"agenda": ["Call the plumber"]'*) ok "O1 a new agenda item is seen by others (normally open)";; *) no "O1 $v";; esac
  case $v in *'"mood": []'*) ok "O2 a new mood is seen by nobody else (normally closed)";; *) no "O2 $v";; esac
  EGAD_USER=alice $P share-mood "$A" m1 bram >/dev/null 2>&1 && no "O3 shared before opt-in" || ok "O3 refused before opt-in"
  EGAD_USER=alice $P opt-in-mood "$A" >/dev/null
  EGAD_USER=alice $P share-mood "$A" m1 bram >/dev/null 2>&1 && no "O3 shared without a confirm" || ok "O3 refused without a confirm"
  EGAD_USER=alice $P share-mood "$A" m1 bram --confirm --remember >/dev/null || no "O4 confirm and remember"
  EGAD_USER=alice $P capture "$A" mood Proud of the garden feeling=proud >/dev/null
  EGAD_USER=alice $P share-mood "$A" m2 bram >/dev/null 2>&1 && ok "O4 a remembered yes for bram stops the asking" || no "O4 still asked for bram"
  EGAD_USER=alice $P share-mood "$A" m2 chen >/dev/null 2>&1 && no "O4 the yes for bram was used for chen" || ok "O4 the remembered yes is for bram only"
  rows=$($P pmo "$A")
  printf '%s\n' "$rows" | awk -F'\t' 'NF != 6 { bad = 1 } END { exit bad }' && ok "O5 pmo rows have six columns" || no "O5 $rows"
  EGAD_USER=alice $P epmo "$A" export to=bram > "$t/ex.json"; EGAD_USER=alice $P epmo "$A" export to=chen > "$t/ex-chen.json"
  EGAD_USER=bram $P epmo "$B" import "$t/ex.json" >/dev/null
  v=$($P view "$B" who=self)
  case $v in *'Tired but hopeful'*'Proud of the garden'*) ok "O6 both shared moods reached bram";; *) no "O6 $v";; esac
  grep -q 'Tired' "$t/ex-chen.json" && no "O6 a mood shared with bram went to chen" || ok "O6 nothing went to chen"
  $P replay "$A" >/dev/null && $P replay "$B" >/dev/null && ok "O7 the tracks rebuild every file, for both people" || no "O7 replay"
  printf '* edited by hand\n' >> "$A/agenda.org"
  $P replay "$A" >/dev/null 2>&1 && no "O8 a hand edit went unseen" || ok "O8 a file edited outside the tracks is found"
  if "$EMACS" --batch -Q --eval '(kill-emacs 0)' >/dev/null 2>&1; then
    "$EMACS" --batch -Q -l "$here/decl/egad-decl.el" --eval "(egad-decl-cli-to-json \"$B/tracks.org\")" > "$t/el.json" 2>/dev/null
    python3 "$here/decl/egad-decl.py" to-json "$B/tracks.org" > "$t/py.json"
    python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))==json.load(open(sys.argv[2])) else 1)' "$t/el.json" "$t/py.json" \
      && ok "O9 the elisp reader reads the tracks as Python does" || no "O9 the two readers disagree on tracks.org"
  else echo "NOT CHECKED O9 (no Emacs)"; fi
  return $f
}
if [ "${1:-}" = --prove-red ]; then
  sed "s/^        md = \[n for n in walk(st\['mood'\]) if .*/        md = [n for n in walk(st['mood'])]/" "$t/forms/egad-org.py" > "$t/mutant.py"
  grep -q "^        md = \[n for n in walk(st\['mood'\])\]$" "$t/mutant.py" || { echo "FAIL prove-red: the mutant was not planted"; exit 1; }
  play "$t/mutant.py" >/dev/null 2>&1 && { echo "FAIL prove-red: a view showing every mood passed"; exit 1; }
  echo "ok   prove-red: a view that shows every mood to everyone goes red"
fi
play "$t/forms/egad-org.py" && echo "ORGANISER CHECKS PASSED" || { echo "ORGANISER CHECKS FAILED"; exit 1; }
