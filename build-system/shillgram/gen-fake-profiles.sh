#!/bin/bash
# Re-issue build-system/fake-codesigning profiles for the SHILLGRAM bundle id, signed with the
# bundled SelfSigned.p12 via openssl (no keychain changes). Output: $1 (default /Volumes/TBuild/ios/codesigning).
set -euo pipefail
W="${1:-/Volumes/TBuild/ios/codesigning}"
SRC="$(cd "$(dirname "$0")/../fake-codesigning" && pwd)"
mkdir -p "$W/profiles" "$W/certs" "$W/tmp"
cp "$SRC"/certs/* "$W/certs/"
openssl pkcs12 -in "$SRC/certs/SelfSigned.p12" -passin pass: -nodes -legacy -nocerts -out "$W/tmp/key.pem" 2>/dev/null
openssl pkcs12 -in "$SRC/certs/SelfSigned.p12" -passin pass: -nodes -legacy -nokeys -clcerts -out "$W/tmp/cert.pem" 2>/dev/null
chmod 600 "$W/tmp/key.pem"
for f in "$SRC"/profiles/*.mobileprovision; do
  n=$(basename "$f")
  security cms -D -i "$f" > "$W/tmp/$n.plist"
  python3 - "$W/tmp/$n.plist" <<'PY'
import plistlib, sys, uuid
p = sys.argv[1]; d = plistlib.load(open(p, 'rb'))
def fix(o):
    if isinstance(o, str):
        return o.replace('ph.telegra.Telegraph', 'io.github.audit0.shillgram').replace('C67CF9S4VU', 'SHLGRM0001').replace('Telegraph', 'SHILLGRAM')
    if isinstance(o, list): return [fix(x) for x in o]
    if isinstance(o, dict): return {k: (v if k in ('DeveloperCertificates', 'DER-Encoded-Profile') else fix(v)) for k, v in o.items()}
    return o
d = fix(d); d['TeamName'] = 'SHILLGRAM self-signed'; d['UUID'] = str(uuid.uuid4()).upper(); d.pop('DER-Encoded-Profile', None)
plistlib.dump(d, open(p, 'wb'))
PY
  openssl cms -sign -nodetach -binary -outform der -signer "$W/tmp/cert.pem" -inkey "$W/tmp/key.pem" -in "$W/tmp/$n.plist" -out "$W/profiles/$n"
done
rm -rf "$W/tmp"
