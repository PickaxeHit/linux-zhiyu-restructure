#!/usr/bin/env bash
# Upload the firmware blob archive to the firmware-sources release if it is not
# there yet.  The name contains the content hash, so an existing asset is never
# overwritten and old locks keep working.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
repo=${GITHUB_REPOSITORY:-PickaxeHit/linux-zhiyu-restructure}
tag=firmware-sources
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

bash "$root/scripts/make-firmware-archive.sh" "$work/blobs.tar.gz"
sha=$(sha256sum "$work/blobs.tar.gz" | cut -d' ' -f1)
name="zhiyu-firmware-blobs-${sha:0:16}.tar.gz"

gh release view "$tag" -R "$repo" >/dev/null 2>&1 ||
    gh release create "$tag" -R "$repo" --latest=false \
        --title "Firmware blob archives" \
        --notes "Content-addressed firmware/SNS archives fetched by the Nix build."
if gh release view "$tag" -R "$repo" --json assets --jq '.assets[].name' |
    grep -Fxq "$name"; then
    echo "firmware blobs: $name already published"
else
    cp "$work/blobs.tar.gz" "$work/$name"
    gh release upload "$tag" "$work/$name" -R "$repo"
    echo "firmware blobs: published $name"
fi
