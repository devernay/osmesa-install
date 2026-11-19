#!/bin/bash
# Check the GitHub release TAG and, if it has every platform's archive, make it a full release.
# Every archive in the release is downloaded anonymously and checked against its ARCHIVE.sha256 (or,
# for older releases without it, against the release's SHA256SUMS), and SHA256SUMS is rebuilt from
# them. If a platform is missing, the release stays a pre-release, and this fails unless all the
# missing platforms are in ALLOW_MISSING.
#
# Usage: release/finalize.sh TAG
# Needs gh (logged in, or GH_TOKEN) and curl. GITHUB_REPOSITORY: owner/repo (devernay/osmesa-install).
# PLATFORMS: the expected archive suffixes. ALLOW_MISSING: platforms that may be missing (e.g. the
# macOS ones, added later by release/macos-vm.sh). Exit status: 0 if the release is complete or only
# allowed platforms are missing, 1 otherwise.

set -eu
set -o pipefail

tag=$1
repo=${GITHUB_REPOSITORY:-devernay/osmesa-install}
url="https://github.com/$repo/releases/download/$tag"
PLATFORMS=${PLATFORMS:-"macos-arm64 macos-x86_64 windows-ucrt64-x86_64 linux-x86_64 linux-aarch64"}
ALLOW_MISSING=${ALLOW_MISSING:-}
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
check=$(mktemp -d)
trap 'rm -rf "$check"' EXIT
cd "$check"

archives() { # the release's archives, sorted (fails if the release can't be read)
    local names
    names=$(gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name') || return 1
    echo "$names" | grep '\.tar\.xz$' | sort || true
}

# another finalize.sh (e.g. the workflow's and macos-vm.sh's) may add archives meanwhile: redo
# until the list of archives is the same before and after writing SHA256SUMS
for attempt in 1 2 3; do
    assets=$(archives) || { echo "Error: can't read release $tag"; exit 1; }
    [ -n "$assets" ] || { echo "Error: release $tag has no archives"; exit 1; }
    curl -fsSL --retry 5 -o SHA256SUMS.old "$url/SHA256SUMS" 2>/dev/null || : > SHA256SUMS.old
    nochecksum=
    for f in $assets; do
        curl -fsSL --retry 5 -o "$f" "$url/$f"
        if ! curl -fsSL --retry 5 -o "$f.sha256" "$url/$f.sha256" 2>/dev/null; then
            # older release without ARCHIVE.sha256 (use SHA256SUMS), or publish.sh still uploading it
            grep "  $f\$" SHA256SUMS.old > "$f.sha256" || { nochecksum=$f; break; }
        fi
        sha256 -c "$f.sha256"
    done
    if [ -n "$nochecksum" ]; then
        [ "$attempt" = 3 ] && { echo "Error: no checksum for $nochecksum"; exit 1; }
        echo "no checksum for $nochecksum yet, checking again in a minute"
        rm -f ./*; sleep 60; continue
    fi
    sha256 $assets > SHA256SUMS
    cat SHA256SUMS
    gh release upload "$tag" --repo "$repo" --clobber SHA256SUMS
    [ "$(archives)" = "$assets" ] && break
    [ "$attempt" = 3 ] && { echo "Error: the release's archives keep changing"; exit 1; }
    echo "the release's archives changed meanwhile, checking again"
    rm -f ./*
done
rm -f SHA256SUMS
curl -fsSL --retry 5 -o SHA256SUMS "$url/SHA256SUMS"
sha256 -c SHA256SUMS

missing=
for p in $PLATFORMS; do
    echo "$assets" | grep -qxF "osmesa-install-$tag-$p.tar.xz" || missing="$missing $p"
done
if [ -n "$missing" ]; then
    echo "Release $tag stays a pre-release, missing:$missing"
    for p in $missing; do
        case " $ALLOW_MISSING " in *" $p "*) ;; *) exit 1;; esac
    done
    exit 0
fi
# "Latest" only if no newer osmesa-mesa-* release exists (an older tag may be completed later)
newest=$(gh release list --repo "$repo" --limit 100 --json tagName --jq '.[].tagName' | grep '^osmesa-mesa-' | sort -V | tail -n 1)
latest=false
[ "$newest" = "$tag" ] && latest=true
gh release edit "$tag" --repo "$repo" --prerelease=false --latest=$latest
echo "Release $tag: every platform is there, published as a full release"
