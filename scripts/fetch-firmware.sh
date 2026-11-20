#!/usr/bin/env bash
# Fetch the firmware/SNS blobs at the commit pinned in metadata/sources.json.
#
#   scripts/fetch-firmware.sh [destination]
#
# The destination defaults to initramfs-src/blobs (the path the traditional
# distro build uses). Everything under it is generated: the repository does
# not carry the blobs any more.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
dest=${1:-$root/initramfs-src/blobs}
rev=$(python3 "$root/scripts/metadata.py" get firmware rev)
sha=$(python3 "$root/scripts/metadata.py" get firmware archive_sha256)
url="https://codeload.github.com/PickaxeHit/linux-zhiyu-firmware/tar.gz/$rev"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl --fail --location --silent --show-error --retry 3 \
    --happy-eyeballs-timeout-ms 200 --connect-timeout 30 \
    --output "$work/archive" "$url"
if ! printf '%s  %s\n' "$sha" "$work/archive" | sha256sum --check --status; then
    echo "fetch-firmware.sh: checksum mismatch for $url" >&2
    exit 1
fi
mkdir -p "$dest"
tar -xf "$work/archive" -C "$dest" --strip-components=1
echo "firmware: $rev -> $dest"
