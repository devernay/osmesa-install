#!/bin/bash
# Add archives to the GitHub release TAG as soon as they are built, so that no binary is lost when
# another platform fails: the release is created as a pre-release by the first platform to finish,
# and release/finalize.sh makes it a full release once every platform is there.
# Each ARCHIVE gets ARCHIVE.sha256 next to it, and its anonymous download is checked against it.
# An archive that is already in the release is never replaced: if it is identical (same SHA-256),
# it is skipped, otherwise it is kept and this fails at the end, after publishing the other archives
# (to republish, delete the release and the tag first).
#
# Usage: release/publish.sh TAG ARCHIVE...
# Needs gh (logged in, or GH_TOKEN) and curl. GITHUB_REPOSITORY: owner/repo (devernay/osmesa-install).

set -eu
set -o pipefail

tag=$1; shift
repo=${GITHUB_REPOSITORY:-devernay/osmesa-install}
dir=$(cd "$(dirname "$0")" && pwd)
url="https://github.com/$repo/releases/download/$tag"
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
check=$(mktemp -d)
trap 'rm -rf "$check"' EXIT

# the release, created as a pre-release if it doesn't exist (404); any other error stops here
if ! gh api "repos/$repo/releases/tags/$tag" --silent 2>"$check/err"; then
    grep -q 'HTTP 404' "$check/err" || { cat "$check/err" >&2; exit 1; }
    bash "$dir/notes.sh" "$tag" > "$check/notes.md"
    # another platform's job may create it at the same time
    gh release create "$tag" --repo "$repo" --verify-tag --prerelease --title "$tag" --notes-file "$check/notes.md" \
        || gh release view "$tag" --repo "$repo" >/dev/null
fi
# name and state of each asset ("uploaded", or "starter" for an upload that broke off)
present=$(gh release view "$tag" --repo "$repo" --json assets --jq '.assets[] | "\(.name) \(.state)"')

different=
for f in "$@"; do
    name=$(basename "$f")
    (cd "$(dirname "$f")" && sha256 "$name" > "$name.sha256")
    cat "$f.sha256"
    hash=$(awk '{print $1}' "$f.sha256")
    state=$(echo "$present" | awk -v n="$name" '$1 == n {print $2}')
    if [ -n "$state" ] && [ "$state" != uploaded ]; then
        echo "Error: $name is in release $tag but its upload didn't finish (state $state):" \
             "delete it (gh release delete-asset $tag $name) and re-run" >&2
        different="$different $name"
        continue
    fi
    if [ -n "$state" ]; then
        curl -fsSL --retry 5 -o "$check/$name" "$url/$name"
        if [ "$(sha256 "$check/$name" | awk '{print $1}')" != "$hash" ]; then
            # e.g. a re-run rebuilt an archive that was already published: keep the published one
            echo "Error: $name is already in release $tag with a different SHA-256: not replacing it" >&2
            different="$different $name"
            continue
        fi
        echo "$name: already in the release, identical"
        echo "$present" | awk '{print $1}' | grep -qxF "$name.sha256" || gh release upload "$tag" --repo "$repo" "$f.sha256"
    else
        gh release upload "$tag" --repo "$repo" "$f" "$f.sha256"
        curl -fsSL --retry 5 -o "$check/$name" "$url/$name"
    fi
    # public (anonymous download), and matches its checksum
    curl -fsSL --retry 5 -o "$check/$name.sha256" "$url/$name.sha256"
    (cd "$check" && sha256 -c "$name.sha256")
done
if [ -n "$different" ]; then
    echo "Error: not published (already in the release):$different" >&2
    exit 1
fi
