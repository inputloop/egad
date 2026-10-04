#!/usr/bin/env python3
"""make-archive.py -- build an ELPA-compatible package archive from a directory of packages.

Emacs's package.el (M-x list-packages) reads an archive as plain files over HTTP(S):

    archive-contents          an Emacs Lisp list: version 1, then one entry per package
    archive-contents.sig      optional detached GPG signature (binary, not armoured)
    NAME-VERSION.el           a single-file package, header-described
    NAME-VERSION.tar          a multi-file package containing NAME-VERSION/NAME-pkg.el
    NAME-VERSION.{el,tar}.sig optional detached GPG signature of each file

That is the whole protocol; a static web server is a conforming ELPA.  This script
makes the directory.  Entry shape (package.el `package-desc', archive version 1):

    (NAME . [(MAJOR MINOR ...) ((DEP (MAJOR MINOR ...)) ...) "summary" single|tar ((:url . "...") ...)])

Usage:
    make-archive.py SRC_DIR OUT_DIR [--sign KEYID] [--url https://egad.bru.st/]

Single-file packages are read from their standard headers (`;;; NAME.el --- summary',
`;; Version:', `;; Package-Requires:', `;; URL:').  Tar packages are read from the
`define-package' form in NAME-pkg.el inside the tar.  Anything that does not parse is
reported and skipped; the archive is never written half-right.
"""
import re, sys, shutil, pathlib, tarfile, subprocess, argparse, html

VER_RE = re.compile(r"^;;\s*(?:Package-)?Version:\s*(\S+)", re.M)
REQ_RE = re.compile(r"^;;\s*Package-Requires:\s*(\(.*\))", re.M)
URL_RE = re.compile(r"^;;\s*URL:\s*(\S+)", re.M)
HEAD_RE = re.compile(r"^;;;\s*([\w.+-]+)\.el\s+---\s+(.*?)(?:\s+-\*-.*)?$", re.M)


def version_list(v):
    """'0.1.0' -> '(0 1 0)'; package.el also accepts pre-release suffixes, we keep to numbers."""
    parts = [int(p) for p in re.findall(r"\d+", v)]
    if not parts:
        raise ValueError(f"unparseable version {v!r}")
    return "(" + " ".join(map(str, parts)) + ")", ".".join(map(str, parts))


def requires_list(text):
    """\"((emacs \"27.1\") (foo \"1.2\"))\" -> \"((emacs (27 1)) (foo (1 2)))\" """
    if not text:
        return "nil"
    deps = re.findall(r"\(\s*([\w.+-]+)\s+\"([^\"]+)\"\s*\)", text)
    return "(" + " ".join(f"({n} {version_list(v)[0]})" for n, v in deps) + ")" if deps else "nil"


def read_single(path):
    src = path.read_text(encoding="utf-8", errors="replace")
    head = HEAD_RE.search(src)
    ver = VER_RE.search(src)
    if not head or not ver:
        raise ValueError("missing `;;; NAME.el --- summary' or `;; Version:' header")
    name, summary = head.group(1), head.group(2).strip()
    if name != path.stem:
        raise ValueError(f"header names {name} but file is {path.name}")
    vlist, vdot = version_list(ver.group(1))
    req = REQ_RE.search(src)
    url = URL_RE.search(src)
    return dict(name=name, vlist=vlist, vdot=vdot, reqs=requires_list(req.group(1) if req else ""),
                summary=summary, kind="single", url=url.group(1) if url else None, src=path)


def read_tar(path):
    with tarfile.open(path) as tf:
        pkg = [m for m in tf.getmembers() if m.name.endswith("-pkg.el")]
        if not pkg:
            raise ValueError("no NAME-pkg.el inside")
        text = tf.extractfile(pkg[0]).read().decode("utf-8", "replace")
    m = re.search(r'\(define-package\s+"([\w.+-]+)"\s+"([^"]+)"\s+"((?:[^"\\]|\\.)*)"(?:\s+\'?(\(.*?\)|nil))?', text, re.S)
    if not m:
        raise ValueError("no define-package form")
    name, ver, summary, reqs = m.groups()
    vlist, vdot = version_list(ver)
    return dict(name=name, vlist=vlist, vdot=vdot, reqs=requires_list(reqs or ""), summary=summary,
                kind="tar", url=None, src=path)


def sign(path, keyid):
    subprocess.run(["gpg", "--batch", "--yes", "--detach-sign", "--local-user", keyid,
                    "--output", str(path) + ".sig", str(path)], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src"); ap.add_argument("out")
    ap.add_argument("--sign", metavar="KEYID", help="detach-sign archive-contents and every package with this GPG key")
    ap.add_argument("--url", default="", help="archive base URL recorded in the index page")
    a = ap.parse_args()
    src, out = pathlib.Path(a.src), pathlib.Path(a.out)
    pkgs, errors = [], []
    for p in sorted(src.iterdir()):
        try:
            if p.suffix == ".el" and not p.name.endswith("-pkg.el"):
                pkgs.append(read_single(p))
            elif p.suffix == ".tar":
                pkgs.append(read_tar(p))
        except Exception as e:  # noqa: BLE001 -- report every bad package, then stop
            errors.append(f"{p.name}: {e}")
    if errors:
        print("\n".join("refused: " + e for e in errors), file=sys.stderr)
        sys.exit(1)
    if not pkgs:
        sys.exit("no packages found")
    out.mkdir(parents=True, exist_ok=True)
    entries = []
    for k in pkgs:
        dest = out / f"{k['name']}-{k['vdot']}.{'el' if k['kind'] == 'single' else 'tar'}"
        shutil.copyfile(k["src"], dest)
        if a.sign:
            sign(dest, a.sign)
        extras = f'((:url . "{k["url"]}"))' if k["url"] else "nil"
        summary = k["summary"].replace("\\", "\\\\").replace('"', '\\"')
        entries.append(f' ({k["name"]} . [{k["vlist"]} {k["reqs"]} "{summary}" {k["kind"]} {extras}])')
    (out / "archive-contents").write_text("(1\n" + "\n".join(entries) + ")\n")
    if a.sign:
        sign(out / "archive-contents", a.sign)
    rows = "\n".join(f"<tr><td><a href=\"{k['name']}-{k['vdot']}.{'el' if k['kind']=='single' else 'tar'}\">{html.escape(k['name'])}</a></td>"
                     f"<td>{k['vdot']}</td><td>{html.escape(k['summary'])}</td></tr>" for k in pkgs)
    (out / "index.html").write_text(f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><meta name="color-scheme" content="light dark">
<title>egad package archive</title><link rel="stylesheet" href="../org/egad.css"></head>
<body><div id="content"><h1 class="title">egad package archive</h1>
<p class="subtitle">add to <code>package-archives</code>: <code>("egad" . "{html.escape(a.url)}elpa/")</code></p>
<table><thead><tr><th>package</th><th>version</th><th>summary</th></tr></thead><tbody>{rows}</tbody></table>
<p>{'Signed: every file has a detached <code>.sig</code>; import the node key from <a href="../.well-known/egad">.well-known/egad</a>.' if a.sign else 'Unsigned archive. Set <code>package-check-signature</code> to <code>allow-unsigned</code> or sign it with --sign.'}</p>
</div></body></html>
""")
    print(f"wrote {len(pkgs)} package(s) to {out}" + (" (signed)" if a.sign else " (unsigned)"))


if __name__ == "__main__":
    main()
