#!/usr/bin/env bash
# Publish a Nix binary cache: NARs as GitHub release assets, the index on the
# nix-repodata branch (GitHub Raw is the substituter URL).
#
#   publish-nix-cache.sh <cache-dir> <release-tag>
#
# The cache directory must be in the output format of
#   nix copy --to file://<cache-dir> <paths>
set -euo pipefail
cache=$(realpath "${1:?cache directory required}")
tag=${2:?release tag required}
branch=${NIX_CACHE_BRANCH:-nix-repodata}
[[ -n "${GITHUB_REPOSITORY:-}" ]] || { echo "GITHUB_REPOSITORY is not set" >&2; exit 1; }
[[ -f "$cache/nix-cache-info" ]] || { echo "no nix-cache-info in $cache" >&2; exit 1; }

# NARs go to a release: branch files are limited to 100 MB and can be large.
if gh release view "$tag" >/dev/null 2>&1; then
    gh release upload "$tag" "$cache"/nar/* --clobber
else
    gh release create "$tag" "$cache"/nar/* --latest=false \
        --title "Nix cache $(date -u +%Y-%m-%d)" \
        --notes "NAR files for the nix-repodata substituter index."
fi

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'git -C "$root" worktree remove --force "$work/tree" 2>/dev/null || true; rm -rf "$work"' EXIT
git -C "$root" worktree add --detach "$work/tree" HEAD
git -C "$work/tree" checkout --orphan "$branch"
git -C "$work/tree" rm -rf --cached . >/dev/null 2>&1 || true
find "$work/tree" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +

base="https://github.com/$GITHUB_REPOSITORY/releases/download/$tag"
cp "$cache/nix-cache-info" "$work/tree/"
for narinfo in "$cache"/*.narinfo; do
    sed -E "s#^URL: nar/#URL: $base/#" "$narinfo" > "$work/tree/$(basename "$narinfo")"
done
git -C "$work/tree" add -A
git -C "$work/tree" -c user.name=github-actions\[bot\] \
    -c user.email=41898282+github-actions\[bot\]@users.noreply.github.com \
    commit -q -m "nix cache: $tag"
git -C "$work/tree" push --force origin "HEAD:refs/heads/$branch"
echo "substituter: https://raw.githubusercontent.com/$GITHUB_REPOSITORY/$branch"
