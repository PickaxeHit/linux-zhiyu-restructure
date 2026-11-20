#!/usr/bin/env bash
# Materialize (and optionally push) the lightweight nix-stable tree.
#
#   make-nix-stable.sh <dir> [--push]
#
# Only what the Nix expressions actually read is copied: the build
# definitions, the source lock, small board sources and the licence texts.
# Kernel, libcamera, firmware/SNS blobs and the distro build tooling are
# fetched through metadata/sources.lock.json instead.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
dest=${1:?destination directory required}
shift
push=false
[[ ${1:-} == --push ]] && push=true
rev=${2:-HEAD}

files=(
    flake.nix flake.lock avb-test-key.pem
    metadata/sources.lock.json metadata/nix-cache.pub
    nix
    nixos/configuration.nix
    configs/linux-7.3-zhiyu.config
    dts/lenovo-zhiyu.dts
    initramfs-src/busybox-applets.txt
    initramfs-src/modules.tsv
    initramfs-src/order-modules.py
    initramfs-src/fs
    initramfs-src/src
    initramfs-src/tplg/Zhiyu-vendorprops.m4
    initramfs-src/tplg/piano
    keymint/idlc.Cargo.lock
    keymint/unlock_metadata.c
    keymint/rpmb_proxy.c
    keymint/time_main.c
    sensors/Makefile
    sensors/sensord.c
    scripts/60-persistent-v4l.rules
    scripts/90-dma-heap.rules
    scripts/90-fastrpc.rules
    scripts/91-flash-led.rules
    scripts/alsa-ucm2
    licenses
    LICENSE.md README.md
)

rm -rf "$dest"
mkdir -p "$dest"
git -C "$root" archive --format=tar "$rev" -- "${files[@]}" | tar -x -C "$dest"

if ! $push; then
    echo "materialized $dest from $(git -C "$root" rev-parse --short "$rev")"
    exit 0
fi

branch=nix-stable
work=$(mktemp -d)
trap 'git -C "$root" worktree remove --force "$work/tree" 2>/dev/null || true; rm -rf "$work"' EXIT
git -C "$root" worktree add --detach "$work/tree" "$rev"

if git -C "$root" ls-remote --exit-code --heads origin "$branch" >/dev/null; then
    # Keep the branch history: each release is one commit on top of the last.
    git -C "$work/tree" fetch origin "$branch"
    git -C "$work/tree" checkout -q -B "$branch" FETCH_HEAD
else
    git -C "$work/tree" checkout --orphan "$branch"
    git -C "$work/tree" rm -rf --cached . >/dev/null 2>&1 || true
fi
find "$work/tree" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp -a "$dest/." "$work/tree/"
git -C "$work/tree" add -A
if git -C "$work/tree" diff --cached --quiet; then
    echo "$branch is unchanged"
    exit 0
fi
git -C "$work/tree" -c user.name=github-actions\[bot\] \
    -c user.email=41898282+github-actions\[bot\]@users.noreply.github.com \
    commit -q -m "nix-stable: $(git -C "$root" rev-parse --short "$rev")"
git -C "$work/tree" push origin "HEAD:refs/heads/$branch"

# A tag per release makes old trees easy to refer to.
if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    tag="nix-$(date -u +%Y%m%d)-${GITHUB_RUN_ID}"
    git -C "$work/tree" tag -f "$tag" >/dev/null
    git -C "$work/tree" push origin "$tag"
fi
echo "pushed $branch from $(git -C "$root" rev-parse --short "$rev")"
