#!/bin/bash
# Creates the Ed25519 key that signs release checksums (run once, by the owner).
#   private key -> paste into GitHub: Settings > Secrets > Actions > TUNLOCK_RELEASE_KEY
#   public key  -> docs/tunlock-release.pem, committed, used by everyone to verify
set -euo pipefail
cd "$(dirname "$0")/.."
OPENSSL=$(command -v /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl openssl | head -1)
"$OPENSSL" version | grep -q '^OpenSSL 3' || { echo "needs OpenSSL 3 (brew install openssl@3)" >&2; exit 1; }
[[ ! -e docs/tunlock-release.pem ]] || { echo "docs/tunlock-release.pem exists already" >&2; exit 1; }
umask 077
KEY=$(mktemp)
"$OPENSSL" genpkey -algorithm ed25519 -out "$KEY"
"$OPENSSL" pkey -in "$KEY" -pubout -out docs/tunlock-release.pem
echo "Public key written to docs/tunlock-release.pem (commit it)."
echo "Private key, for the GitHub secret TUNLOCK_RELEASE_KEY (then delete this output):"
cat "$KEY"
rm -f "$KEY"
