#!/usr/bin/env bash
# Deterministic archive of the firmware/SNS blobs.  Nix fetches this archive
# (hash in metadata/sources.lock.json) instead of the tree keeping 75 MB of
# blobs in the nix-stable branch.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?output archive required}
( cd "$root/initramfs-src/blobs" && \
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
      -cf - firmware sensors ) | gzip -n -9 > "$out"
