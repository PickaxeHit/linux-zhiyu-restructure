#!/usr/bin/env bash
# Publish a Nix binary cache: NARs as GitHub release assets, the index on the
# nix-repodata branch (GitHub Raw is the substituter URL).
#
#   publish-nix-cache.sh <cache-dir> <release-tag>
#
# Objects already served by cache.nixos.org are dropped, and objects already
# uploaded by an earlier cache release are not uploaded again: their narinfo
# keeps pointing at the release that has them. The index branch is merged, not
# replaced.
set -euo pipefail
cache=$(realpath "${1:?cache directory required}")
tag=${2:?release tag required}
branch=${NIX_CACHE_BRANCH:-nix-repodata}
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
[[ -f "$cache/nix-cache-info" ]] || { echo "no nix-cache-info in $cache" >&2; exit 1; }

# ---- drop what cache.nixos.org already provides, by full store hash -------
for narinfo in "$cache"/*.narinfo; do
    hash=$(basename "$narinfo" .narinfo)
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        "https://cache.nixos.org/$hash.narinfo" || echo 000)
    if [ "$code" = 200 ]; then
        url=$(sed -n 's/^URL: //p' "$narinfo" | head -1)
        [ -n "$url" ] && rm -f "$cache/$url"
        rm -f "$narinfo"
    fi
done
if ! ls "$cache"/*.narinfo >/dev/null 2>&1; then
    echo "cache: nothing new to publish"
    exit 0
fi

# ---- which release already holds each NAR file ----------------------------
declare -A asset_tag=()
while IFS=$'\t' read -r release_id release_tag; do
    while IFS= read -r name; do
        [ -n "$name" ] && asset_tag["$name"]="$release_tag"
    done < <(gh api "repos/$GITHUB_REPOSITORY/releases/$release_id/assets?per_page=100" \
                 --jq '.[].name' 2>/dev/null || true)
done < <(gh api "repos/$GITHUB_REPOSITORY/releases?per_page=100" \
             --jq '.[] | select(.tag_name|startswith("nix-cache-")) | [.id, .tag_name] | @tsv' 2>/dev/null || true)

new_nars=()
for nar in "$cache"/nar/*; do
    name=$(basename "$nar")
    [ -n "${asset_tag[$name]:-}" ] || new_nars+=("$nar")
done

if (( ${#new_nars[@]} > 0 )); then
    if gh release view "$tag" >/dev/null 2>&1; then
        gh release upload "$tag" "${new_nars[@]}" --clobber
    else
        gh api -X POST "repos/$GITHUB_REPOSITORY/releases" \
            -f tag_name="$tag" -f name="Nix cache $(date -u +%Y-%m-%d)" \
            -f body="NAR files for the nix-repodata substituter index." \
            -f make_latest=false >/dev/null
        gh release upload "$tag" "${new_nars[@]}" --clobber
    fi
    for nar in "${new_nars[@]}"; do
        asset_tag["$(basename "$nar")"]="$tag"
    done
    echo "cache: uploaded ${#new_nars[@]} new NAR(s) to $tag"
else
    echo "cache: every NAR is already in a previous cache release"
fi

# ---- merge the index ----
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
for narinfo in "$cache"/*.narinfo; do
    url=$(sed -n 's/^URL: nar\///p' "$narinfo" | head -1)
    release=${asset_tag[$url]:-$tag}
    base="https://github.com/$GITHUB_REPOSITORY/releases/download/$release"
    sed -E "s#^URL: nar/#URL: $base/#" "$narinfo" > "$work/tree/$(basename "$narinfo")"
done
git -C "$work/tree" add -A
if git -C "$work/tree" diff --cached --quiet; then
    echo "cache: index unchanged"
    exit 0
fi
git -C "$work/tree" -c user.name=github-actions\[bot\] \
    -c user.email=41898282+github-actions\[bot\]@users.noreply.github.com \
    commit -q -m "nix cache: ${tag}"
git -C "$work/tree" push origin "HEAD:refs/heads/$branch"
echo "substituter: https://raw.githubusercontent.com/$GITHUB_REPOSITORY/$branch"
