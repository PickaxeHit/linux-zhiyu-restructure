#!/usr/bin/env python3
"""Generate metadata/sources.lock.json from the pins and the real fetchers.

The lock is the only file the Nix expressions read for source locations and
hashes. It is derived, never hand-edited:

  * kernel and the libcamera forks come from the gitlink of the submodule;
  * third-party projects come from metadata/sources.json;
  * every hash is computed the way Nix will fetch the source
    (fetchzip/fetchFromGitHub for archives, fetchgit for GitLab).

Usage:
    scripts/gen-sources-lock.py           # write the lock
    scripts/gen-sources-lock.py --check   # fail if it is out of date
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "metadata" / "sources.json"
LOCK = ROOT / "metadata" / "sources.lock.json"

GITHUB = re.compile(r"^https://github\.com/([^/]+)/([^/]+?)(?:\.git)?$")


def run(args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def gitlink(path):
    return run(["git", "-C", str(ROOT), "rev-parse", f"HEAD:{path}"])


def prefetch_unpack(url, name="source"):
    out = run(["nix", "store", "prefetch-file", "--unpack", "--json", "--name", name, url])
    data = json.loads(out)
    return data["hash"], pathlib.Path(data["storePath"])


def prefetch_git(url, rev):
    try:
        out = run(["nix-prefetch-git", "--url", url, "--rev", rev])
    except FileNotFoundError:
        out = run(["nix", "run", "nixpkgs#nix-prefetch-git", "--", "--url", url, "--rev", rev])
    return json.loads(out)["hash"]


def github_parts(url):
    m = GITHUB.match(url)
    if not m:
        raise SystemExit(f"gen-sources-lock: not a GitHub URL: {url}")
    return m.group(1), m.group(2)


def codeload(owner, repo, rev):
    return f"https://codeload.github.com/{owner}/{repo}/tar.gz/{rev}"


def kernel_version(source):
    makefile = (source / "Makefile").read_text()
    version = ".".join(
        re.search(rf"^{key}\s*=\s*(\d+)$", makefile, re.M).group(1)
        for key in ("VERSION", "PATCHLEVEL", "SUBLEVEL")
    )
    series = ".".join(version.split(".")[:2])
    config = (ROOT / "configs" / f"linux-{series}-zhiyu.config").read_text()
    m = re.search(r'^CONFIG_LOCALVERSION="(.*)"$', config, re.M)
    return version, version + (m.group(1) if m else "")


def meson_version(source):
    m = re.search(r"version\s*:\s*'([^']+)'", (source / "meson.build").read_text())
    if not m:
        raise SystemExit(f"gen-sources-lock: no version in {source}/meson.build")
    return m.group(1)


FIRMWARE_TAG = "firmware-sources"


def firmware_blobs_entry():
    repo = os.environ.get("GITHUB_REPOSITORY", "PickaxeHit/linux-zhiyu-restructure")
    with tempfile.TemporaryDirectory() as tmp:
        archive = pathlib.Path(tmp) / "blobs.tar.gz"
        run(["bash", str(ROOT / "scripts" / "make-firmware-archive.sh"), str(archive)])
        file_hash = hashlib.sha256(archive.read_bytes()).hexdigest()
        tree = pathlib.Path(tmp) / "tree"
        tree.mkdir()
        run(["tar", "-xzf", str(archive), "-C", str(tree)])
        tree_hash = run(["nix", "hash", "path", "--sri", str(tree)])
    name = f"zhiyu-firmware-blobs-{file_hash[:16]}.tar.gz"
    return {
        "url": f"https://github.com/{repo}/releases/download/{FIRMWARE_TAG}/{name}",
        "hash": tree_hash,
        "sha256": file_hash,
    }


def build_lock():
    sources = json.loads(SOURCES.read_text())
    lock = {}

    for name, path in (("kernel", "kernel-source"),
                       ("libcamera-0.7", "libcamera/0.7"),
                       ("libcamera-0.8", "libcamera/0.8")):
        url = run(["git", "-C", str(ROOT), "config", "-f", ".gitmodules",
                   f"--get", f"submodule.{path}.url"])
        owner, repo = github_parts(url)
        rev = gitlink(path)
        digest, store = prefetch_unpack(codeload(owner, repo, rev))
        entry = {"owner": owner, "repo": repo, "rev": rev, "hash": digest}
        if name == "kernel":
            version, mod_dir = kernel_version(store)
            entry.update(version=version, modDirVersion=mod_dir)
        else:
            entry["version"] = meson_version(store)
        lock[name] = entry

    lock["firmware-blobs"] = firmware_blobs_entry()

    for name, source in sources.items():
        if name in ("avb", "mkbootimg", "busybox", "f2fs-tools", "hexagonrpc"):
            # Not fetched by the Nix expressions (distro/tools packages).
            continue
        if source["type"] != "git":
            continue
        url, rev = source["url"], source["rev"]
        if "gitlab.com" in url:
            lock[name] = {"url": url, "rev": rev, "hash": prefetch_git(url, rev)}
            continue
        owner, repo = github_parts(url)
        digest, store = prefetch_unpack(codeload(owner, repo, rev))
        lock[name] = {"owner": owner, "repo": repo, "rev": rev, "hash": digest}
        if name == "qcom-va-driver":
            lock[name]["version"] = meson_version(store)

    return lock


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="fail if metadata/sources.lock.json is out of date")
    args = parser.parse_args()

    lock = build_lock()
    text = json.dumps(lock, indent=2, sort_keys=True) + "\n"
    if args.check:
        if not LOCK.exists() or LOCK.read_text() != text:
            print("metadata/sources.lock.json is out of date; "
                  "run scripts/gen-sources-lock.py", file=sys.stderr)
            return 1
        print("metadata/sources.lock.json: up to date")
        return 0
    LOCK.write_text(text)
    print(f"wrote {LOCK.relative_to(ROOT)} ({len(lock)} entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
