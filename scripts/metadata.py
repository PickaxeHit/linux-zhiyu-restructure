#!/usr/bin/env python3
"""Read and validate the pinned third-party sources.

    metadata.py verify
    metadata.py list
    metadata.py get <name> <field>

`metadata/sources.json` is the single, hand-edited authority for third-party
revisions and checksums; see metadata/README.md.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "metadata" / "sources.json"

HEX64 = set("0123456789abcdef")


def load(path=SOURCES):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def is_hex(value, length):
    return isinstance(value, str) and len(value) == length and set(value) <= HEX64


def verify():
    sources = load()
    errors = []

    for name, entry in sorted(sources.items()):
        if not isinstance(entry.get("url"), str) or not entry["url"]:
            errors.append(f"{name}: url is required")
        kind = entry.get("type")
        if kind == "git":
            if not isinstance(entry.get("rev"), str) or not entry["rev"]:
                errors.append(f"{name}: rev is required for git sources")
            if "commit" in entry and not is_hex(entry["commit"], 40):
                errors.append(f"{name}: commit must be a 40-character hex SHA")
            if "archive_sha256" in entry and not is_hex(entry["archive_sha256"], 64):
                errors.append(f"{name}: archive_sha256 must be a 64-character hex digest")
        elif kind == "tarball":
            if not isinstance(entry.get("version"), str) or not entry["version"]:
                errors.append(f"{name}: version is required for tarball sources")
            if not is_hex(entry.get("sha256"), 64):
                errors.append(f"{name}: sha256 must be a 64-character hex digest")
        else:
            errors.append(f"{name}: type must be 'git' or 'tarball'")

    if errors:
        for error in errors:
            print(f"metadata: {error}", file=sys.stderr)
        return 1
    print(f"metadata/sources.json: {len(sources)} entries OK")
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == "verify":
        return verify()
    if len(argv) == 2 and argv[1] == "list":
        print("\n".join(sorted(load())))
        return 0
    if len(argv) == 4 and argv[1] == "get":
        entry = load().get(argv[2])
        if entry is None:
            print(f"metadata: no such source: {argv[2]}", file=sys.stderr)
            return 1
        value = entry.get(argv[3])
        if value is None:
            print(f"metadata: {argv[2]} has no field {argv[3]}", file=sys.stderr)
            return 1
        print(value)
        return 0
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
