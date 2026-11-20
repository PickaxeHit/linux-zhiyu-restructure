#!/usr/bin/env bash
# Publish a Nix binary cache: NARs as GitHub release assets, the index on the
# nix-repodata branch (GitHub Raw is the substituter URL).
#
#   publish-nix-cache.sh <cache-dir> <release-tag>
#
# The cache directory must be in the output format of
#   nix copy --to file://<cache-dir> <paths>
#
# Objects already available from cache.nixos.org are dropped: there is no
# point re-hosting them. The index branch is merged, not replaced, so entries
# published by earlier runs (and their release assets) stay usable.
set -euo pipefail
cache=$(realpath "${1:?cache directory required}")
tag=${2:?release tag required}
branch=${NIX_CACHE_BRANCH:-nix-repodata}
[[ -n "${GITHUB_REPOSITORY:-}" ]] || { echo "GITHUB_REPOSITORY is not set" >&2; exit 1; }
[[ -f "$cache/nix-cache-info" ]] || { echo "no nix-cache-info in $cache" >&2; exit 1; }

# Drop what the official cache already provides, by full store hash.
dropped=0
for narinfo in "$cache"/*.narinfo; do
    hash=$(basename "$narinfo" .narinfo)
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        "https://cache.nixos.org/$hash.narinfo" || echo 000)
    if [ "$code" = 200 ]; then
        url=$(sed -n 's/^URL: //p' "$narinfo" | head -1)
        [ -n "$url" ] && rm -f "$cache/$url"
        rm -f "$narinfo"
        dropped=$((dropped + 1))
    fi
done
kept=$(ls "$cache"/*.narinfo 2>/dev/null | wc -l)
echo "cache: $kept object(s) to publish, $dropped already in cache.nixos.org"
(( kept > 0 )) || { echo "cache: nothing to publish" >&2; exit 1; }

if gh release view "$tag" >/dev/null 2>&1; then
    gh release upload "$tag" "$cache"/nar/* --clobber
else
    gh api -X POST "repos/$GITHUB_REPOSITORY/releases" \
        -f tag_name="$tag" -f name="Nix cache $(date -u +%Y-%m-%d)" \
        -f body="NAR files for the nix-repodata substituter index." \
        -f make_latest=false >/dev/null
    gh release upload "$tag" "$cache"/nar/* --clobber
fi

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'git -C "$root" worktree remove --force "$work/tree" 2>/dev/null || true; rm -rf "$work"' EXIT
git -C "$root" worktree add --detach "$work/tree" HEAD
if git -C "$root" ls-remote --exit-code --heads origin "$branch" >/dev/null; then
    git -C "$work/tree" fetch origin "$branch"
    git -C "$work/tree" checkout -q FETCH_HEAD
else
    git -C "$work/tree" checkout --orphan "$branch"
    git -C "$work/tree" rm -rf --cached . >/dev/null 2>&1 || true
    find "$work/tree" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
fi

cp "$cache/nix-cache-info" "$work/tree/"
base="https://github.com/$GITHUB_REPOSITORY/releases/download/$tag"
for narinfo in "$cache"/*.narinfo; do
    sed -E "s#^URL: nar/#URL: $base/#" "$narinfo" > "$work/tree/$(basename "$narinfo")"
done
git -C "$work/tree" add -A
git -C "$work/tree" -c user.name=github-actions\[bot\] \
    -c user.email=41898282+github-actions\[bot\]@users.noreply.github.com \
    commit -q -m "nix cache: $tag ($kept new object(s))"
git -C "$work/tree" push origin "HEAD:refs/heads/$branch"
echo "substituter: https://raw.githubusercontent.com/$GITHUB_REPOSITORY/$branch"
