#!/usr/bin/env bash
# Install Foundry from the official GitHub release tarball (no pipe-to-shell).
# Verifies the asset digest published by the GitHub API before unpacking.
set -euo pipefail

DEST="${HOME}/.foundry"
mkdir -p "$DEST/bin"

API="https://api.github.com/repos/foundry-rs/foundry/releases/latest"
echo "== querying latest release"
curl -sSL -H "Accept: application/vnd.github+json" "$API" -o /tmp/foundry_release.json
python3 - <<'PY'
import json
d = json.load(open('/tmp/foundry_release.json'))
print("tag:", d.get("tag_name"))
for a in d.get("assets", []):
    if "linux_amd64.tar.gz" in a["name"]:
        print("asset:", a["name"])
        print("url:", a["browser_download_url"])
        print("size:", a["size"])
        print("digest:", a.get("digest"))
        open('/tmp/foundry_asset.txt','w').write(a["browser_download_url"] + "\n" + (a.get("digest") or ""))
        break
else:
    raise SystemExit("no linux_amd64 asset found")
PY

URL=$(sed -n 1p /tmp/foundry_asset.txt)
DIGEST=$(sed -n 2p /tmp/foundry_asset.txt)
echo "== downloading $URL"
curl -sSL "$URL" -o /tmp/foundry.tar.gz

if [ -n "$DIGEST" ]; then
  echo "== verifying digest"
  echo "$DIGEST" | sed 's/^sha256://' > /tmp/foundry.sha
  sha256sum -c <(awk '{print $1"  /tmp/foundry.tar.gz"}' /tmp/foundry.sha)
else
  echo "== no digest published; recording sha256 for the log only"
  sha256sum /tmp/foundry.tar.gz
fi

echo "== unpacking to $DEST/bin"
tar -xzf /tmp/foundry.tar.gz -C "$DEST/bin"
"$DEST/bin/forge" --version
"$DEST/bin/cast" --version
echo "== done; add $DEST/bin to PATH"
