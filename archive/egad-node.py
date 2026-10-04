#!/usr/bin/env python3
"""egad-node.py -- a small HTTP(S) node that serves an egad site: the package
archive, the org-html theme, the gallery, the jit forms, and the node's
/.well-known/egad discovery document.  Standard library only.

Two roles, meant to run as two separate processes with two config files:

  role = public    the surface the world sees (egad.example): archive, themes, gallery
  role = trusted   the surface only your WireGuard peers see (egadjit.example):
                   the same plus /jit/ -- tangled tool forms and "transport-compiled"
                   intermediate work product shared between Emacs, web and other clients.

Commands:
  egad-node.py serve  CONF            run the server
  egad-node.py check-peers CONF       fetch every peer's /.well-known/egad; report
                                      mutual / one-way / unreachable / key-mismatch
  egad-node.py well-known CONF        print this node's discovery document

The default bind is 0.0.0.0 -- every interface -- and the node says so loudly at
start.  A trusted node should bind its WireGuard address (bind = 10.2.42.1, or
bind = wg to pick the first address inside wg_cidr).  See net/FIREWALL.org.
"""
import sys, ssl, json, socket, ipaddress, configparser, pathlib, subprocess, http.server, urllib.request, datetime, functools

DEFAULTS = {
    "name": "localhost", "role": "public", "bind": "0.0.0.0", "port": "8443", "root": "dist/site",
    "tls_cert": "", "tls_key": "", "wg_cidr": "10.2.42.0/24", "peers": "peers.json",
    "signing_key_fingerprint": "", "signing_key_path": "/keys/node.asc",
    "archive_path": "/elpa/", "org_path": "/org/", "gallery_path": "/gallery/", "jit_path": "/jit/",
    "contact": "",
}


def warn(msg):
    sys.stderr.write("\n" + "=" * 72 + "\nWARNING: " + msg.strip() + "\n" + "=" * 72 + "\n\n")


def load_conf(path):
    cp = configparser.ConfigParser(defaults=DEFAULTS)
    cp.read(path)
    if "node" not in cp:
        cp["node"] = {}
    n = dict(cp["node"])
    n["_dir"] = pathlib.Path(path).resolve().parent
    n["root"] = str((n["_dir"] / n["root"]).resolve())
    if n["role"] not in ("public", "trusted"):
        sys.exit(f"role must be public or trusted, not {n['role']!r}")
    return n


def load_peers(n):
    p = n["_dir"] / n["peers"]
    return json.loads(p.read_text()) if p.exists() else []


def wg_address(cidr):
    """First local address inside cidr, via `ip -j addr'; None when unavailable."""
    net = ipaddress.ip_network(cidr)
    try:
        data = json.loads(subprocess.run(["ip", "-j", "addr"], capture_output=True, text=True, check=True).stdout)
    except Exception:  # noqa: BLE001 -- no `ip', or not Linux: the caller explains
        return None
    for link in data:
        for a in link.get("addr_info", []):
            try:
                if ipaddress.ip_address(a["local"]) in net:
                    return a["local"]
            except (KeyError, ValueError):
                continue
    return None


def well_known(n):
    scheme = "https" if n["tls_cert"] else "http"
    base = f"{scheme}://{n['name']}" + ("" if n["port"] in ("443", "80") else f":{n['port']}")
    doc = {
        "egad": 1,
        "node": n["name"],
        "role": n["role"],
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "archives": [{"name": "egad", "kind": "elpa", "url": base + n["archive_path"],
                      "package_archives_entry": f'("egad" . "{base}{n["archive_path"]}")'}],
        "org_html": {"setupfile": base + n["org_path"] + "egad.setup", "css": base + n["org_path"] + "egad.css"},
        "gallery": base + n["gallery_path"],
        "signing_key": {"fingerprint": n["signing_key_fingerprint"], "url": base + n["signing_key_path"]} if n["signing_key_fingerprint"] else None,
        "transport": {"tls": bool(n["tls_cert"]), "wireguard_cidr": n["wg_cidr"] if n["role"] == "trusted" else None},
        "peers": [{"name": p["name"], "url": p["url"], "fingerprint": p.get("fingerprint", "")} for p in load_peers(n)],
        "contact": n["contact"] or None,
    }
    if n["role"] == "trusted":
        doc["jit"] = {"index": base + n["jit_path"] + "jit-index.json", "forms": base + n["jit_path"]}
    return doc


class Handler(http.server.SimpleHTTPRequestHandler):
    server_version = "egad-node/0.1"

    def do_GET(self):
        if self.path.split("?")[0] in ("/.well-known/egad", "/.well-known/egad.json"):
            body = json.dumps(well_known(self.server.node), indent=1).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/healthz":
            self.send_response(200); self.send_header("Content-Type", "text/plain"); self.end_headers(); self.wfile.write(b"ok\n")
            return
        super().do_GET()

    def end_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        super().end_headers()

    def log_message(self, fmt, *args):
        sys.stderr.write(f"{self.address_string()} {fmt % args}\n")


def serve(n):
    bind = n["bind"]
    if bind == "wg":
        bind = wg_address(n["wg_cidr"]) or sys.exit(
            f"bind = wg: no local address inside {n['wg_cidr']} found (needs Linux `ip -j addr`; set bind explicitly otherwise)")
    if bind in ("0.0.0.0", "::", ""):
        warn(f"Listening on EVERY interface ({bind or '0.0.0.0'}:{n['port']}).\n"
             f"Anyone who can reach this host on port {n['port']} can read this node"
             + (".\nThis node's role is TRUSTED: it is meant to be reachable only over WireGuard.\n"
                f"Set bind = wg (first address in {n['wg_cidr']}) or bind = <your wg address>." if n["role"] == "trusted" else ".")
             + "\nSee net/FIREWALL.org for how to restrict the port on GNU/Linux, the BSDs, macOS and Windows.")
    elif n["role"] == "trusted" and ipaddress.ip_address(bind) not in ipaddress.ip_network(n["wg_cidr"]):
        warn(f"role = trusted but bind {bind} is outside wg_cidr {n['wg_cidr']}.")
    if not n["tls_cert"]:
        warn("No tls_cert/tls_key: serving plain HTTP. package.el and browsers will fetch over http://.\n"
             "Acceptable only inside WireGuard (the tunnel is the encryption); never on a public interface.")
    root = pathlib.Path(n["root"])
    if not root.is_dir():
        sys.exit(f"root {root} is not a directory (run emit and make-archive first, or fix root=)")
    handler = functools.partial(Handler, directory=str(root))
    httpd = http.server.ThreadingHTTPServer((bind, int(n["port"])), handler)
    httpd.node = n
    if n["tls_cert"]:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(str(n["_dir"] / n["tls_cert"]), str(n["_dir"] / n["tls_key"]))
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    sys.stderr.write(f"egad-node [{n['role']}] {n['name']} serving {root} on {'https' if n['tls_cert'] else 'http'}://{bind}:{n['port']}/\n")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


def fetch_json(url, ca=None, insecure=False, timeout=10):
    ctx = ssl.create_default_context(cafile=ca) if ca else ssl.create_default_context()
    if insecure:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    with urllib.request.urlopen(url, context=ctx, timeout=timeout) as r:
        return json.loads(r.read().decode())


def check_peers(n, insecure=False):
    """Mutual trust is a property you can measure: we list them, they list us, keys match."""
    me = well_known(n)
    my_urls = {me["archives"][0]["url"].rsplit(n["archive_path"], 1)[0], f"https://{n['name']}", f"http://{n['name']}"}
    rows = []
    for p in load_peers(n):
        try:
            doc = fetch_json(p["url"].rstrip("/") + "/.well-known/egad", ca=(str(n["_dir"] / p["ca"]) if p.get("ca") else None), insecure=insecure)
        except Exception as e:  # noqa: BLE001 -- the status IS the result
            rows.append((p["name"], "unreachable", str(e).splitlines()[0][:70])); continue
        fp = (doc.get("signing_key") or {}).get("fingerprint", "")
        if p.get("fingerprint") and fp and p["fingerprint"].replace(" ", "").upper() != fp.replace(" ", "").upper():
            rows.append((p["name"], "KEY-MISMATCH", f"they say {fp[-16:]}, we pinned {p['fingerprint'][-16:]}")); continue
        lists_us = any(q.get("name") == n["name"] or q.get("url", "").rstrip("/") in my_urls for q in doc.get("peers", []))
        rows.append((p["name"], "mutual" if lists_us else "one-way", f"role={doc.get('role')} node={doc.get('node')}"))
    w = max((len(r[0]) for r in rows), default=4)
    for name, status, note in rows:
        print(f"{name:<{w}}  {status:<13} {note}")
    bad = [r for r in rows if r[1] != "mutual"]
    print(f"{len(rows) - len(bad)} mutual, {len(bad)} not")
    return 1 if bad else 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) < 2 or args[0] not in ("serve", "check-peers", "well-known"):
        sys.exit(__doc__)
    n = load_conf(args[1])
    if args[0] == "serve":
        serve(n)
    elif args[0] == "well-known":
        print(json.dumps(well_known(n), indent=1))
    else:
        sys.exit(check_peers(n, insecure="--insecure" in args))
