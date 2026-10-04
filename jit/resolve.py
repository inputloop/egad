#!/usr/bin/env python3
"""resolve.py -- choose one treatment per category for the people looking at a screen.

Each person carries a small file of preferences: constraints (reduced motion, screen
reader) and, per category, the order in which they would like the treatments.  A
category declares its treatments, the facts each can be refused on, and a baseline
that no constraint can refuse.  Given one or more viewers, this picks, for every
category, the treatment that is acceptable to all of them and ranks best for the
person it ranks worst for (minimise the maximum rank: nobody gets their last choice
so that someone else gets their first).  Ties fall to the category's declared order.
If nothing is acceptable to everyone -- which the baseline rule prevents -- the
baseline is chosen and said so.

This is the whole of the "just in time" part: the choice is made when the screen is
drawn, from who is there, not baked into the page.

    resolve.py FOREST_DIR VIEWER.json [VIEWER2.json ...] [--json]

Prints a line per category with the choice and the reason; --json prints a machine
form: {"category": {"treatment": ..., "forms": [...], "why": ...}}.
"""
import sys, json, pathlib


def acceptable(treat, c):
    if c.get("reduced_motion") and treat.get("motion"):
        return False, "moves, viewer asked for reduced motion"
    if c.get("screen_reader") and not treat.get("announces"):
        return False, "does not announce, viewer uses a screen reader"
    return True, ""


def resolve(category, viewers):
    names = category.get("order") or list(category["treatments"])
    trace = []
    candidates = []
    for name in names:
        t = category["treatments"][name]
        ok, why = True, []
        ranks = []
        for v in viewers:
            a, reason = acceptable(t, v.get("constraints", {}))
            if not a:
                ok = False; why.append(f"{v.get('viewer', '?')}: {reason}")
            pref = v.get("prefer", {}).get(category["category"], [])
            ranks.append(pref.index(name) if name in pref else len(names))
        if ok:
            candidates.append((max(ranks), sum(ranks), names.index(name), name))
        else:
            trace.append(f"  {name}: refused ({'; '.join(why)})")
    if candidates:
        candidates.sort()
        worst, total, _, pick = candidates[0]
        why = f"acceptable to all; worst rank {worst}, total {total}"
    else:
        pick, why = category["baseline"], "nothing acceptable to everyone; baseline"
    return pick, why, trace


def main():
    args = [a for a in sys.argv[1:] if a != "--json"]
    as_json = "--json" in sys.argv
    if len(args) < 2:
        sys.exit(__doc__)
    forest = pathlib.Path(args[0])
    viewers = [json.loads(pathlib.Path(p).read_text()) for p in args[1:]]
    out = {}
    for f in sorted(forest.glob("*.json")):
        cat = json.loads(f.read_text())
        pick, why, trace = resolve(cat, viewers)
        out[cat["category"]] = {"treatment": pick, "forms": cat["treatments"][pick]["forms"], "why": why}
        if not as_json:
            who = ", ".join(v.get("viewer", "?") for v in viewers)
            print(f"{cat['category']} for [{who}] -> {pick}  ({why})")
            for t in trace:
                print(t)
    if as_json:
        print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
