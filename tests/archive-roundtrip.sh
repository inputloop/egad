#!/bin/sh
# archive-roundtrip.sh -- prove the archive layer end to end, on this machine:
#   generated themes -> signed ELPA archive -> two egad nodes (public TLS, trusted plain)
#   -> curl reads /.well-known/egad -> check-peers says "mutual" both ways
#   -> a real Emacs (batch) adds the archive, verifies the GPG signatures, installs
#      a theme and loads it.
# Needs: python3, gpg, openssl, curl, emacs (27+).  Leaves nothing running.
# Exit 0 only when every step passed.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
tmp="$here/tests/tmp"; rm -rf "$tmp"; mkdir -p "$tmp/tls" "$tmp/gnupg" "$tmp/emacs-gnupg" "$tmp/site-trusted/jit"
chmod 700 "$tmp/gnupg" "$tmp/emacs-gnupg"
export GNUPGHOME="$tmp/gnupg"
PASS=0; fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo "--- $*"; }

step "1 throwaway signing key"
gpg --batch --quiet --passphrase '' --quick-gen-key 'egad test node <test@egad.invalid>' ed25519 sign 1d
FP=$(gpg --batch --with-colons --list-keys | awk -F: '/^fpr/{print $10; exit}')
[ -n "$FP" ] || fail "no fingerprint"

step "2 emit + signed archive into dist/site"
python3 "$here/emit/emit.py" >/dev/null
rm -rf "$here/dist/site"; mkdir -p "$here/dist/site/keys"
python3 "$here/archive/make-archive.py" "$here/dist/elpa-src" "$here/dist/site/elpa" --sign "$FP" --url https://127.0.0.1:8443/
cp -r "$here/dist/org-html" "$here/dist/site/org"; cp "$here/org-html/"*.setup "$here/dist/site/org/"
gpg --batch --armor --export "$FP" > "$here/dist/site/keys/node.asc"
grep -q '^(1' "$here/dist/site/elpa/archive-contents" || fail "archive-contents shape"
[ -s "$here/dist/site/elpa/archive-contents.sig" ] || fail "archive-contents.sig missing"
gpg --batch --quiet --verify "$here/dist/site/elpa/archive-contents.sig" "$here/dist/site/elpa/archive-contents" 2>/dev/null || fail "gpg does not verify our own signature"

step "3 self-signed TLS for 127.0.0.1"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj '/CN=127.0.0.1' \
  -addext 'subjectAltName=IP:127.0.0.1,DNS:localhost' -keyout "$tmp/tls/key.pem" -out "$tmp/tls/cert.pem" 2>/dev/null

step "3b the server certificate verifies with openssl against itself"
sleep 0.2
echo | openssl s_client -connect 127.0.0.1:8443 -CAfile "$tmp/tls/cert.pem" -verify_return_error >/dev/null 2>&1 && echo "(no node yet: checked after start)"

step "4 two nodes: public (TLS, :8443) and trusted (plain, :8444), each listing the other"
cat > "$tmp/public.conf" <<EOF
[node]
name = 127.0.0.1
role = public
bind = 127.0.0.1
port = 8443
root = ../../dist/site
tls_cert = tls/cert.pem
tls_key = tls/key.pem
signing_key_fingerprint = $FP
peers = peers-public.json
EOF
cat > "$tmp/peers-public.json" <<EOF
[{"name": "trusted-test", "url": "http://127.0.0.1:8444", "fingerprint": "$FP"}]
EOF
cat > "$tmp/trusted.conf" <<EOF
[node]
name = trusted-test
role = trusted
bind = 127.0.0.1
port = 8444
root = site-trusted
wg_cidr = 127.0.0.0/8
signing_key_fingerprint = $FP
peers = peers-trusted.json
EOF
cat > "$tmp/peers-trusted.json" <<EOF
[{"name": "127.0.0.1", "url": "https://127.0.0.1:8443", "fingerprint": "$FP", "ca": "tls/cert.pem"}]
EOF
echo '{"egad-jit":1,"forms":[]}' > "$tmp/site-trusted/jit/jit-index.json"
python3 "$here/archive/egad-node.py" serve "$tmp/public.conf"  >"$tmp/public.log"  2>&1 & P1=$!
python3 "$here/archive/egad-node.py" serve "$tmp/trusted.conf" >"$tmp/trusted.log" 2>&1 & P2=$!
trap 'kill $P1 $P2 2>/dev/null || true' EXIT INT TERM
for i in 1 2 3 4 5 6 7 8 9 10; do curl -fsk https://127.0.0.1:8443/healthz >/dev/null 2>&1 && curl -fs http://127.0.0.1:8444/healthz >/dev/null 2>&1 && break; sleep 0.3; done

echo | openssl s_client -connect 127.0.0.1:8443 -CAfile "$tmp/tls/cert.pem" -verify_return_error 2>&1 | grep -q 'Verify return code: 0' || fail "openssl cannot verify the node certificate"
echo "openssl verifies the node certificate"

step "5 discovery documents"
curl -fsk https://127.0.0.1:8443/.well-known/egad | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["egad"]==1 and d["role"]=="public" and d["archives"][0]["url"].endswith("/elpa/") and d["signing_key"]["fingerprint"], d; print("public ok:", d["archives"][0]["package_archives_entry"])'
curl -fs  http://127.0.0.1:8444/.well-known/egad | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["role"]=="trusted" and d["jit"]["index"].endswith("jit-index.json") and d["transport"]["wireguard_cidr"], d; print("trusted ok:", d["jit"]["index"])'
grep -q 'WARNING: No tls_cert' "$tmp/trusted.log" || fail "trusted node did not warn about plain HTTP"
curl -fsk https://127.0.0.1:8443/elpa/archive-contents | head -2

step "6 mutual trust, measured from both sides"
python3 "$here/archive/egad-node.py" check-peers "$tmp/public.conf"
python3 "$here/archive/egad-node.py" check-peers "$tmp/trusted.conf"

step "7 Emacs installs a theme from the archive with signature checking on"
# a proxy in the environment would swallow 127.0.0.1; url.el honours no_proxy
no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost emacs --batch -Q --eval "(progn
  (require 'package) (require 'url) (setq url-proxy-services nil)
  (setq user-emacs-directory \"$tmp/emacs.d/\"
        package-user-dir \"$tmp/emacs.d/elpa/\"
        package-gnupghome-dir \"$tmp/emacs-gnupg/\"
        package-check-signature 'all
        package-archives '((\"egad\" . \"https://127.0.0.1:8443/elpa/\"))
        ;; NOTE: url.el in Emacs 29.3 (Debian build, GnuTLS) returned no connection at all
        ;; whenever gnutls-trustfiles named this self-signed cert, with no verification message
        ;; logged.  So this step pins nothing: the tunnel still encrypts, and the certificate is
        ;; verified by openssl in step 3b.  Reproduce on your own Emacs build before relying on
        ;; gnutls-trustfiles for a private CA; see archive/README.org, Known gaps.
        network-security-level 'low)
  (package-import-keyring \"$here/dist/site/keys/node.asc\")
  (package-initialize)
  (package-refresh-contents)
  (package-install 'egad-operandi-theme)
  (unless (package-installed-p 'egad-operandi-theme) (kill-emacs 2))
  (require 'org)
  (load-theme 'egad-operandi t)
  (princ (format \"installed %s; default bg=%s org-todo=%s\\n\"
                 (package-desc-full-name (cadr (assq 'egad-operandi-theme package-alist)))
                 (face-attribute 'default :background) (face-attribute 'org-todo :foreground))))" >"$tmp/emacs.log" 2>&1 || { tail -5 "$tmp/emacs.log"; fail "emacs install (see tests/tmp/emacs.log)"; }
grep -v '^Contacting\|^Importing\|^Package refresh\|^Setting' "$tmp/emacs.log"
grep -q '^installed egad-operandi-theme-0.1.0; default bg=#ffffff org-todo=#a60000' "$tmp/emacs.log" || fail "installed theme did not report the token colours"

step "7b a tampered archive is refused"
printf ' ' >> "$here/dist/site/elpa/archive-contents"
no_proxy=127.0.0.1,localhost emacs --batch -Q --eval "(progn
  (require 'package) (require 'url) (setq url-proxy-services nil)
  (setq package-user-dir \"$tmp/emacs.d/elpa2/\" package-gnupghome-dir \"$tmp/emacs-gnupg/\"
        package-check-signature 'all package-archives '((\"egad\" . \"https://127.0.0.1:8443/elpa/\"))
        network-security-level 'low)
  (package-initialize)
  (condition-case e (progn (package-refresh-contents) (princ \"REFRESH-SUCCEEDED\n\"))
    (error (princ (format \"refused: %s\n\" (error-message-string e))))))" >"$tmp/emacs2.log" 2>&1 || true
grep -qi 'signature\|refused\|Failed to verify\|Failed to download' "$tmp/emacs2.log" || { tail -5 "$tmp/emacs2.log"; fail "tampered archive-contents was accepted"; }
grep -v REFRESH-SUCCEEDED "$tmp/emacs2.log" | grep -i 'signature\|refused\|Failed' | head -2
# package.el says only "Failed to download" in batch; the node log shows both files were served
# with 200, so the refusal is the signature check (step 7 fetched the same two files and passed).
[ "$(grep -c 'GET /elpa/archive-contents.sig HTTP/1.1" 200' "$tmp/public.log")" -ge 2 ] || fail "the .sig was not re-fetched"
echo "node served archive-contents + .sig with 200 both times; only the bytes differed"
python3 "$here/archive/make-archive.py" "$here/dist/elpa-src" "$here/dist/site/elpa" --sign "$FP" --url https://127.0.0.1:8443/ >/dev/null

step "8 the 0.0.0.0 default warns"
cat > "$tmp/default.conf" <<EOF
[node]
name = default-test
port = 8445
root = ../../dist/site
EOF
python3 "$here/archive/egad-node.py" serve "$tmp/default.conf" >"$tmp/default.log" 2>&1 & P3=$!
sleep 0.7; kill $P3 2>/dev/null || true
grep -q 'WARNING: Listening on EVERY interface' "$tmp/default.log" || fail "no bind warning"
echo "default bind warned, as documented"

echo "ALL STEPS PASSED"
