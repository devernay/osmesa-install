#!/bin/bash
# Add archives to the GitHub release TAG as soon as they are built, so that no binary is lost when
# another platform fails: the release is created as a pre-release by the first platform to finish,
# and release/finalize.sh makes it a full release once every platform is there.
# Each ARCHIVE gets ARCHIVE.sha256 next to it, and its anonymous download is checked against it.
#
# Usage: release/publish.sh TAG ARCHIVE...
# Needs gh (logged in, or GH_TOKEN) and curl. GITHUB_REPOSITORY: owner/repo (devernay/osmesa-install).

set -eu
set -o pipefail

tag=$1; shift
repo=${GITHUB_REPOSITORY:-devernay/osmesa-install}
dir=$(cd "$(dirname "$0")" && pwd)
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

if ! gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    notes=$(mktemp)
    bash "$dir/notes.sh" "$tag" > "$notes"
    # another platform's job may create it at the same time
    gh release create "$tag" --repo "$repo" --verify-tag --prerelease --title "$tag" --notes-file "$notes" \
        || gh release view "$tag" --repo "$repo" >/dev/null
    rm -f "$notes"
fi

check=$(mktemp -d)
for f in "$@"; do
    name=$(basename "$f")
    (cd "$(dirname "$f")" && sha256 "$name" > "$name.sha256")
    cat "$f.sha256"
    gh release upload "$tag" --repo "$repo" --clobber "$f" "$f.sha256"
    # public (anonymous download), and matches its checksum
    for g in "$name" "$name.sha256"; do
        curl -fsSL --retry 5 -o "$check/$g" "https://github.com/$repo/releases/download/$tag/$g"
    done
    (cd "$check" && sha256 -c "$name.sha256")
done
rm -rf "$check"
