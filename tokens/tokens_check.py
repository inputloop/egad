#!/usr/bin/env python3
"""tokens_check.py -- the contrast and consistency gate for egad-tokens.json.

Measures, never repairs.  Exit 0 = all gates pass, 1 = a gate failed.

Gates
  names    every token name unique across families (type excluded), legal charset
  aliases  every "{name}" alias resolves to an existing color token, no self/cycle
  contrast every declared text pair clears its floor in EVERY theme
           (text 7.0 = AAA normal; ui 3.0 = WCAG 1.4.11 non-text)
  drift    if a hand-written tokens.css sits beside tokens.json, every
           --var it sets for the first theme equals the json value

Pairs are declared in the json itself, under "meta.pairs":
  [{"fg": "ink-100", "bg": "surface-100", "floor": "text"}, ...]
so the contract lives with the data, not in this script.

Falsifiers (how this check can be wrong):
  * contrast("#ffffff","#000000") must print 21.00 and #777 on #fff 4.48
    -> run:  python3 tokens_check.py --selftest
  * a deliberately duplicated name must fail the names gate
"""
import json, re, sys, pathlib

FLOORS = {"text": 7.0, "text-aa": 4.5, "ui": 3.0}
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
HEX_RE = re.compile(r"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$")


def lum(hexv):
    h = hexv.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    out = []
    for i in (0, 2, 4):
        c = int(h[i:i + 2], 16) / 255
        out.append(c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4)
    r, g, b = out
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def selftest():
    ok = abs(contrast("#ffffff", "#000000") - 21.0) < 0.01 and \
        abs(contrast("#777777", "#ffffff") - 4.48) < 0.01 and \
        contrast("#123456", "#abcdef") == contrast("#abcdef", "#123456")
    print("selftest", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main(path):
    t = json.load(open(path))
    fails = []
    themes = [th["id"] for th in t["color"]["themes"]]
    first = themes[0]

    # names
    seen = {}
    for fam, body in t.items():
        if fam in ("type", "name", "version", "meta") or not isinstance(body, dict):
            continue
        for tok in body.get("tokens", []):
            n = tok["name"]
            if not NAME_RE.match(n):
                fails.append(f"names: illegal name {n!r} in {fam}")
            if n in seen:
                fails.append(f"names: {n!r} in {fam} duplicates {seen[n]}")
            seen[n] = fam

    # aliases -> resolved table
    raw = {tok["name"]: tok["value"] for tok in t["color"]["tokens"]}

    def val(name, theme, depth=0):
        v = raw[name]
        v = v.get(theme, v.get(first)) if isinstance(v, dict) else v
        m = re.fullmatch(r"\{([^}]+)\}", v)
        if m:
            tgt = m.group(1)
            if tgt not in raw or tgt == name or depth > 8:
                raise ValueError(f"aliases: {name} -> {tgt} unresolved/cyclic")
            return val(tgt, theme, depth + 1)
        return v

    resolved = {}
    for n in raw:
        for th in themes:
            try:
                resolved[(n, th)] = val(n, th)
            except ValueError as e:
                fails.append(str(e))

    # contrast
    pairs = t.get("meta", {}).get("pairs", [])
    if not pairs:
        fails.append("contrast: no meta.pairs declared -- nothing measured")
    for p in pairs:
        floor = FLOORS[p.get("floor", "text")]
        for th in themes:
            fg, bg = resolved.get((p["fg"], th)), resolved.get((p["bg"], th))
            if not (fg and bg and HEX_RE.match(fg) and HEX_RE.match(bg)):
                fails.append(f"contrast: {p['fg']}/{p['bg']} [{th}] not hex, unmeasured")
                continue
            r = contrast(fg, bg)
            mark = "ok  " if r >= floor else "FAIL"
            print(f"{mark} {th:<22} {p['fg']:>18} on {p['bg']:<14} {r:5.2f} (floor {floor})")
            if r < floor:
                fails.append(f"contrast: {p['fg']} on {p['bg']} [{th}] {r:.2f} < {floor}")

    # drift against a hand-written css twin
    css = pathlib.Path(path).with_name("tokens.css")
    if css.exists():
        root = css.read_text().split("}")[0]
        for n, v in re.findall(r"--([A-Za-z0-9_.-]+):\s*(#[0-9a-fA-F]{3,6})", root):
            if (n, first) in resolved and resolved[(n, first)].lower() != v.lower():
                fails.append(f"drift: tokens.css --{n} {v} != tokens.json {resolved[(n, first)]}")

    for f in fails:
        print("GATE", f)
    print(f"{len(fails)} gate failure(s)")
    return 1 if fails else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "tokens/egad-tokens.json"))
