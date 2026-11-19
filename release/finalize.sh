#!/bin/bash
# Check the GitHub release TAG and, if it has every platform's archive, make it a full release.
# Every archive in the release is downloaded anonymously and checked against its .sha256, and
# SHA256SUMS is rebuilt from them. Exits with status 2 (and leaves it a pre-release) if a platform is
# missing, 1 on other errors.
#
# Usage: release/finalize.sh TAG
# Needs gh (logged in, or GH_TOKEN) and curl. GITHUB_REPOSITORY: owner/repo (devernay/osmesa-install).
# PLATFORMS: the expected archive suffixes.

set -eu
set -o pipefail

tag=$1
repo=${GITHUB_REPOSITORY:-devernay/osmesa-install}
PLATFORMS=${PLATFORMS:-"macos-arm64 macos-x86_64 windows-ucrt64-x86_64 linux-x86_64 linux-aarch64"}
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

check=$(mktemp -d)
cd "$check"
assets=$(gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name' | grep '\.tar\.xz$' || true)
[ -n "$assets" ] || { echo "Error: release $tag has no archives"; exit 1; }
for f in $assets; do
    for g in "$f" "$f.sha256"; do
        curl -fsSL --retry 5 -o "$g" "https://github.com/$repo/releases/download/$tag/$g"
    done
    sha256 -c "$f.sha256"
done
sha256 $assets > SHA256SUMS
cat SHA256SUMS
gh release upload "$tag" --repo "$repo" --clobber SHA256SUMS
rm -f SHA256SUMS
curl -fsSL --retry 5 -o SHA256SUMS "https://github.com/$repo/releases/download/$tag/SHA256SUMS"
sha256 -c SHA256SUMS

missing=
for p in $PLATFORMS; do
    echo "$assets" | grep -qx "osmesa-install-$tag-$p.tar.xz" || missing="$missing $p"
done
cd / && rm -rf "$check"
if [ -n "$missing" ]; then
    echo "Release $tag stays a pre-release, missing:$missing"
    exit 2
fi
gh release edit "$tag" --repo "$repo" --prerelease=false --latest
echo "Release $tag: every platform is there, published as a full release"
