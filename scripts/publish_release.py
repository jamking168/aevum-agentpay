#!/usr/bin/env python3
"""Publish a file as a GitHub release asset and verify the public URL anonymously.

The older `~/.git-credentials-github` token is expired (401 Bad credentials), while the
current one lives in `~/.git-credentials`; this reads whichever github entry is present
there and never prints it.

Usage:
    publish_release.py <owner/repo> <tag> <file> [--title T] [--note N]
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.github.com"
UA = "money-coo-release-publisher"


def token() -> str:
    for path in ("/home/jam/.git-credentials", "/home/jam/.git-credentials-github"):
        try:
            raw = open(path, encoding="utf-8").read()
        except OSError:
            continue
        for line in raw.splitlines():
            if "github.com" not in line or "@" not in line:
                continue
            creds = line.split("://", 1)[-1].split("@", 1)[0]
            if ":" in creds:
                return creds.rsplit(":", 1)[1]
    sys.exit("no github credential found")


def call(method: str, url: str, tok: str, body=None, ctype="application/json", raw=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {tok}", "Accept": "application/vnd.github+json",
        "User-Agent": UA, "Content-Type": ctype,
    })
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        text = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(text)
        except json.JSONDecodeError:
            return e.code, {"raw": text[:400]}


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) < 3:
        sys.exit(__doc__)
    repo, tag, path = args[0], args[1], args[2]
    title = note = None
    for flag, name in (("--title", "title"), ("--note", "note")):
        if flag in sys.argv:
            val = sys.argv[sys.argv.index(flag) + 1]
            if name == "title":
                title = val
            else:
                note = val

    tok = token()
    status, rel = call("GET", f"{API}/repos/{repo}/releases/tags/{tag}", tok)
    if status == 404:
        status, rel = call("POST", f"{API}/repos/{repo}/releases", tok, {
            "tag_name": tag, "name": title or tag, "body": note or "", "draft": False,
            "prerelease": False,
        })
        print("release created:", status, rel.get("html_url") or rel.get("message"))
    else:
        print("release reused:", status, rel.get("html_url"))
    if status not in (200, 201):
        return 1

    release_id = rel["id"]
    name = os.path.basename(path)
    # replace a same-named asset so a re-record can be re-published
    for asset in rel.get("assets", []):
        if asset.get("name") == name:
            call("DELETE", f"{API}/repos/{repo}/releases/assets/{asset['id']}", tok)
            print("removed previous asset", name)

    payload = open(path, "rb").read()
    status, asset = call(
        "POST",
        "https://uploads.github.com/repos/" + repo + "/releases/" + str(release_id) + "/assets?name="
        + urllib.parse.quote(name),
        tok, ctype="video/mp4", raw=payload,
    )
    print("upload:", status, asset.get("browser_download_url") or asset.get("message"))
    if status not in (200, 201):
        return 1

    url = asset["browser_download_url"]
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=120) as r:  # anonymous on purpose
        size = int(r.headers.get("Content-Length", 0))
        print(f"anonymous HEAD: {r.status} {size} bytes "
              f"{r.headers.get('Content-Type')} size matches: {size == len(payload)}")
    print("URL:", url)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
