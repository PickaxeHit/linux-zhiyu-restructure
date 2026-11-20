#!/usr/bin/env bash
# Publish a lightweight nix-stable branch: only what the Nix expressions need.
#
# Large sources (kernel, libcamera) are pinned as URLs+hashes in
# metadata/sources.lock.json, so they are not in the branch; only the small
# board files and the Nix definitions are.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
rev=${1:-HEAD}
branch=${2:-nix-stable}
paths=(
    flake.nix flake.lock
    metadata
    nix nixos
    dts configs initramfs-src keymint sensors
    scripts avb-test-key.pem
    README.md LICENSE.md
)
work=$(mktemp -d)
trap 'git -C "$root" worktree remove --force "$work/tree" 2>/dev/null || true; rm -rf "$work"' EXIT

git -C "$root" worktree add --detach "$work/tree" "$rev"
git -C "$work/tree" checkout --orphan "$branch"
git -C "$work/tree" rm -rf --cached . >/dev/null 2>&1 || true
find "$work/tree" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
git -C "$root" archive --format=tar "$rev" -- "${paths[@]}" | tar -x -C "$work/tree"
git -C "$work/tree" add -A
git -C "$work/tree" -c user.name=github-actions\[bot\] \
    -c user.email=41898282+github-actions\[bot\]@users.noreply.github.com \
    commit -q -m "nix-stable: $(git -C "$root" rev-parse --short "$rev")"
git -C "$work/tree" push --force origin "HEAD:refs/heads/$branch"
echo "pushed $branch from $(git -C "$root" rev-parse --short "$rev")"
