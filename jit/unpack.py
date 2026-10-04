#!/usr/bin/env python3
"""unpack.py -- tangle an egadjit literate Org file into its tool forms, without Emacs.

An egadjit file is an ordinary Org document.  Prose is for people and for agents
alike; `#+BEGIN_SRC LANG :tangle PATH` blocks are the tools, in whatever language
suits them.  Org's own `org-babel-tangle` produces the same files from Emacs; this
script exists so a web client, a CI job or an agent without Emacs can unpack them.

Supported, deliberately small (the subset Org users already know):
  #+BEGIN_SRC lang :tangle relative/path [:shebang "#!/bin/sh"] [:noweb yes] [:mkdirp yes]
  #+NAME: block-name          then  <<block-name>>  inside another block (:noweb yes)
  :PROPERTIES: :header-args+: :tangle dir/  on a headline adds to the blocks under it
                                            (plain :header-args: REPLACES what is inherited, as in Org)
  #+PROPERTY: header-args ...               at file level
Anything else in a header is kept as metadata and ignored.

Writes the forms under OUT (default dist/jit/) and OUT/jit-index.json: one entry per
form with its source file, headline path, language, sha256, byte size and the first
paragraph of prose above the block -- the guidance a client shows before offering to
run or install the form.  Paths are confined to OUT: `..`, absolute paths and
dot-segments are refused.

    unpack.py FILE.org [FILE2.org ...] [--out dist/jit] [--check]

--check writes nothing: it reports which forms on disk differ from what the Org
would produce (drift between the literate source and its derivations).
"""
import re, sys, json, hashlib, pathlib, argparse, datetime

BEGIN = re.compile(r"^\s*#\+BEGIN_SRC\s+(\S+)(.*)$", re.I)
END = re.compile(r"^\s*#\+END_SRC\s*$", re.I)
NAME = re.compile(r"^\s*#\+NAME:\s*(\S+)", re.I)
HEADLINE = re.compile(r"^(\*+)\s+(.*?)(?:\s+:[\w:@#%]+:)?\s*$")
PROP_FILE = re.compile(r"^\s*#\+PROPERTY:\s+header-args(?::\S+)?\s+(.*)$", re.I)
PROP_HEAD = re.compile(r"^\s*:header-args(?::\S+)?(\+)?:\s+(.*)$", re.I)
ARG = re.compile(r':(\w[\w-]*)\s+("(?:[^"\\]|\\.)*"|\S+)?')
NOWEB = re.compile(r"^(\s*)<<([\w.-]+)>>\s*$")


def parse_args(s):
    out = {}
    for k, v in ARG.findall(s or ""):
        if v and v.startswith('"'):
            v = v[1:-1]
        out[k] = v if v is not None else "yes"
    return out


def safe_rel(path):
    p = pathlib.PurePosixPath(path)
    if p.is_absolute() or any(part in ("..", "") or part.startswith(".") for part in p.parts):
        raise ValueError(f"refused tangle path {path!r}: must be relative, no .. or dot segments")
    return p


def parse_org(text, source):
    """Yield blocks: dict(lang, args, body, name, headline, guidance)."""
    lines = text.splitlines()
    file_args, head_stack, blocks, names = {}, [], [], {}
    i, last_para, cur_name = 0, [], None
    while i < len(lines):
        ln = lines[i]
        m = HEADLINE.match(ln)
        if m:
            depth = len(m.group(1))
            head_stack = head_stack[:depth - 1] + [(m.group(2).strip(), {})]
            last_para = []
            i += 1; continue
        m = PROP_FILE.match(ln)
        if m:
            file_args.update(parse_args(m.group(1))); i += 1; continue
        m = PROP_HEAD.match(ln)
        if m and head_stack:
            # Org semantics: `:header-args:' REPLACES everything inherited; `:header-args+:' adds to it.
            head_stack[-1][1].update(parse_args(m.group(2)))
            head_stack[-1][1]["__replace__"] = not bool(m.group(1)); i += 1; continue
        m = NAME.match(ln)
        if m:
            cur_name = m.group(1); i += 1; continue
        m = BEGIN.match(ln)
        if m:
            lang, args = m.group(1), dict(file_args)
            for _, a in head_stack:
                if a.get("__replace__"):
                    args = {}
                args.update({k: v for k, v in a.items() if k != "__replace__"})
            args.update(parse_args(m.group(2)))
            body = []
            i += 1
            while i < len(lines) and not END.match(lines[i]):
                body.append(lines[i]); i += 1
            blk = dict(lang=lang, args=args, body=body, name=cur_name, source=source,
                       headline=" / ".join(h for h, _ in head_stack),
                       guidance=" ".join(l.strip() for l in last_para).strip())
            if cur_name:
                names[cur_name] = blk
            blocks.append(blk)
            cur_name = None
            i += 1; continue
        if ln.strip() and not ln.lstrip().startswith(("#+", ":")):
            last_para.append(ln)
        elif not ln.strip():
            if last_para and i + 1 < len(lines) and BEGIN.match(lines[i + 1] if i + 1 < len(lines) else ""):
                pass  # the paragraph right above a block is its guidance
            else:
                last_para = []
        i += 1
    return blocks, names


def expand(blk, names, depth=0):
    if depth > 8:
        raise ValueError("noweb nesting deeper than 8")
    out = []
    for ln in blk["body"]:
        m = NOWEB.match(ln)
        if m and blk["args"].get("noweb", "no") != "no":
            ref = names.get(m.group(2))
            if not ref:
                raise ValueError(f"<<{m.group(2)}>> names no block")
            out += [m.group(1) + l for l in expand(ref, names, depth + 1)]
        else:
            out.append(ln)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+"); ap.add_argument("--out", default="dist/jit"); ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    out = pathlib.Path(a.out)
    forms, drift, all_names = {}, [], {}
    parsed = []
    for f in a.files:
        text = pathlib.Path(f).read_text(encoding="utf-8")
        blocks, names = parse_org(text, f)
        all_names.update(names)
        parsed.append(blocks)
    for blocks in parsed:
        for blk in blocks:
            tangle = blk["args"].get("tangle")
            if not tangle or tangle in ("no", "nil"):
                continue
            rel = safe_rel(tangle)
            body = expand(blk, all_names)
            text = ("\n".join(body) + "\n")
            if blk["args"].get("shebang"):
                text = blk["args"]["shebang"] + "\n" + text
            forms.setdefault(str(rel), {"path": str(rel), "lang": blk["lang"], "source": blk["source"],
                                        "headline": blk["headline"], "guidance": blk["guidance"], "chunks": []})
            forms[str(rel)]["chunks"].append(text)
    index = {"egad-jit": 1, "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"), "forms": []}
    for rel, f in forms.items():
        data = "".join(f["chunks"]).encode()
        sha = hashlib.sha256(data).hexdigest()
        dest = out / rel
        if a.check:
            on_disk = dest.read_bytes() if dest.exists() else None
            state = "missing" if on_disk is None else ("same" if on_disk == data else "DRIFT")
            print(f"{state:<8} {rel}")
            if state != "same":
                drift.append(rel)
        else:
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
            if f["lang"] in ("sh", "bash", "python", "perl"):
                dest.chmod(0o755)
            print("tangled", dest, f"({len(data)} bytes, {f['lang']})")
        index["forms"].append({"path": rel, "lang": f["lang"], "sha256": sha, "bytes": len(data),
                               "source": f["source"], "headline": f["headline"], "guidance": f["guidance"]})
    if a.check:
        sys.exit(1 if drift else 0)
    out.mkdir(parents=True, exist_ok=True)
    (out / "jit-index.json").write_text(json.dumps(index, indent=1) + "\n")
    print("index", out / "jit-index.json", f"({len(index['forms'])} forms)")


if __name__ == "__main__":
    main()
