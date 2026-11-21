# Verifying a release

On each push to `main`, GitHub Actions runs the build and live PF tests.
It reads commits since the previous release tag and picks the highest
version bump under the [commit rules](../AGENTS.md). A push with only
maintenance or unclassified commits runs CI without publishing a release.
For a release, the tag, app, and bundled CLI use the calculated version.
The release notes list commit subjects since the previous release tag
and include migration guidance from `BREAKING CHANGE:` footers.

If an upload fails after the tag is created, rerun the failed publication
job to resume the release for that commit.

Every DMG is built on GitHub Actions, never on someone's computer. The build
publishes `SHA256SUMS.txt` next to the DMG. Once the owner has set a release key,
it also publishes `SHA256SUMS.txt.sig`, an Ed25519 signature made with a private
key that only exists as a GitHub secret.

Check the file you downloaded (OpenSSL 3: `brew install openssl@3`):

```bash
OPENSSL=$(brew --prefix openssl@3)/bin/openssl
curl -fsSLO https://raw.githubusercontent.com/hunbow-n/tunlock/main/docs/tunlock-release.pem
base64 -d < SHA256SUMS.txt.sig > SHA256SUMS.sig.bin
"$OPENSSL" pkeyutl -verify -pubin -inkey tunlock-release.pem -rawin -in SHA256SUMS.txt -sigfile SHA256SUMS.sig.bin
shasum -a 256 -c SHA256SUMS.txt
```

Both commands must succeed: `Signature Verified Successfully` and `Tunlock.dmg: OK`.
A changed DMG fails the checksum; a changed checksum file fails the signature,
even if someone took over the GitHub account, because the private key is not in it.

## For the owner: set up the key once

```bash
tools/release-key.sh      # writes docs/tunlock-release.pem, prints the private key
```

Paste the private key into GitHub: Settings → Secrets and variables → Actions →
New repository secret `TUNLOCK_RELEASE_KEY`. Commit `docs/tunlock-release.pem`.
Without the secret, CI still publishes `SHA256SUMS.txt`, just unsigned.
