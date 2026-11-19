#!/bin/bash
# Fallback for when GitHub's Linux runners are unavailable: build the Linux release archives
# (x86_64 and aarch64) locally, in rockylinux:9 containers with podman (or docker), with the same
# script as the release workflow (release/linux-build.sh), and optionally add them to the GitHub
# release. See "Making a release" in README.md.
#
# Usage: release/linux-local.sh [--upload] [TAG]
#   TAG: osmesa-mesa-<mesa version>-llvm-<llvm version> (default: the versions in release.yml). The
#        sources are "git archive TAG" (or HEAD if the tag doesn't exist yet and --upload isn't given;
#        REV=<commit> for a test build of another commit).
#   --upload: add the archives, with ARCHIVE.sha256, to the release TAG with gh (see
#        release/publish.sh and release/finalize.sh), and make it a full release if every platform is
#        there. Architectures already in the release (built on GitHub) are skipped. Without it, the
#        archives are only left in $WORK/out.
#
# Each architecture is built in its own throwaway container (--rm), one at a time; the container
# needs network access (dnf, pip). The architecture that isn't the host's runs under emulation:
# with qemu (podman machine's default on Apple Silicon) LLVM takes hours, with Rosetta (podman
# machine with Rosetta enabled, or OrbStack) it is much faster. LLVM is built in the container.
#
# Host requirements: podman (or CONTAINER=docker), git, curl, and gh for --upload.
# Environment: WORK (/tmp/osmesa-linux-local, must not be in ~/Documents), ARCHS ("aarch64 x86_64"),
# CONTAINER (podman), IMAGE (rockylinux:9), CPUS (4), MEMORY (6g), MKJOBS (4), MAX_LOAD (number of
# CPUs: each build waits until the host load average is below it), MIN_FREE_GB (30: and until that
# much disk space is free), WAIT_IDLE (1: and until no other container is running).

set -eu
set -o pipefail

upload=0
if [ "${1:-}" = --upload ]; then upload=1; shift; fi
repo=$(cd "$(dirname "$0")/.." && pwd)
wf="$repo/.github/workflows/release.yml"
mesaversion=$(sed -n 's/^  CI_MESA_VERSION: *//p' "$wf")
llvmversion=$(sed -n 's/^  CI_LLVM_VERSION: *//p' "$wf")
tag="${1:-osmesa-mesa-$mesaversion-llvm-$llvmversion}"
case "$tag" in
    osmesa-mesa-*-llvm-*) mesaversion=${tag#osmesa-mesa-}; mesaversion=${mesaversion%%-llvm-*}; llvmversion=${tag##*-llvm-};;
    *) echo "Error: TAG must be osmesa-mesa-<mesa version>-llvm-<llvm version>" >&2; exit 1;;
esac
WORK=${WORK:-/tmp/osmesa-linux-local}
ARCHS=${ARCHS:-"aarch64 x86_64"}
CONTAINER=${CONTAINER:-podman}
IMAGE=${IMAGE:-rockylinux:9}
CPUS=${CPUS:-4}
MEMORY=${MEMORY:-6g}
MKJOBS=${MKJOBS:-4}
MIN_FREE_GB=${MIN_FREE_GB:-30}
gluversion=9.0.1
demoversion=8.4.0

log() { echo "[$(date '+%F %T')] $*"; }
die() { echo "Error: $*" >&2; exit 1; }

case "$WORK" in "$HOME"/Documents*) die "WORK must not be in ~/Documents (the container reads it)";; esac
command -v "$CONTAINER" >/dev/null || die "$CONTAINER not found"

# sources: the tagged commit (HEAD for a test build before the tag exists)
if [ -n "${REV:-}" ]; then
    # test build of another commit (e.g. REV=HEAD to test a branch once the tag exists)
    [ "$upload" = 0 ] || die "REV is only for test builds (without --upload)"
    rev=$REV
elif git -C "$repo" rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null; then
    rev=$tag
elif [ "$upload" = 0 ]; then
    rev=HEAD
    log "tag $tag not found, building HEAD (test build)"
else
    die "tag $tag not found (git fetch --tags)"
fi
commit=$(git -C "$repo" rev-parse "$rev^{commit}")

if [ "$upload" = 1 ]; then
    command -v gh >/dev/null || die "gh not found"
    # don't replace archives built on GitHub (the release may not exist yet: publish.sh creates it)
    mkdir -p "$WORK"
    if gh api "repos/devernay/osmesa-install/releases/tags/$tag" --silent 2>"$WORK/gh.err"; then
        present=$(gh release view "$tag" --repo devernay/osmesa-install --json assets --jq '.assets[].name')
    elif grep -q 'HTTP 404' "$WORK/gh.err"; then
        present=
    else
        cat "$WORK/gh.err" >&2; die "can't read release $tag"
    fi
    archs=
    for arch in $ARCHS; do
        if echo "$present" | grep -qxF "osmesa-install-$tag-linux-$arch.tar.xz"; then
            log "$arch: already in release $tag, skipping"
        else
            archs="$archs $arch"
        fi
    done
    ARCHS=$archs
    if [ -z "$ARCHS" ]; then
        log "nothing to build, checking the release"
        ALLOW_MISSING="macos-arm64 macos-x86_64 windows-ucrt64-x86_64" bash "$repo/release/finalize.sh" "$tag"
        exit 0
    fi
fi

mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd -P) # e.g. /private/tmp/...: podman machine shares /private, not /tmp
rm -rf "$WORK/src" "$WORK/out"
mkdir -p "$WORK/src" "$WORK/dl" "$WORK/out"
git -C "$repo" archive "$commit" | tar -x -C "$WORK/src"

# tarballs (kept between runs)
fetch() { # file url
    [ -f "$WORK/dl/$1" ] && return 0
    log "downloading $1"
    curl -fL --retry 3 -o "$WORK/dl/$1.part" "$2" && mv "$WORK/dl/$1.part" "$WORK/dl/$1"
}
fetch "llvm-project-$llvmversion.src.tar.xz" "https://github.com/llvm/llvm-project/releases/download/llvmorg-$llvmversion/llvm-project-$llvmversion.src.tar.xz"
fetch "mesa-$mesaversion.tar.xz" "https://archive.mesa3d.org/mesa-$mesaversion.tar.xz"
fetch "glu-$gluversion.tar.gz" "https://archive.mesa3d.org/glu/glu-$gluversion.tar.gz"
fetch "mesa-demos-$demoversion.tar.bz2" "https://archive.mesa3d.org/demos/$demoversion/mesa-demos-$demoversion.tar.bz2"

# one container at a time, started only when the host isn't overloaded
maxload=${MAX_LOAD:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}
for arch in $ARCHS; do
    while load=$(awk '{print int($1)}' /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg | awk '{print int($2)}'); [ "$load" -ge "$maxload" ]; do
        log "host load $load >= $maxload (MAX_LOAD), waiting"
        sleep 120
    done
    while free=$(df -Pk "$WORK" | awk 'NR==2 {print int($4 / 1048576)}'); [ "$free" -lt "$MIN_FREE_GB" ]; do
        log "only $free GB free on the disk of $WORK (< MIN_FREE_GB=$MIN_FREE_GB), waiting"
        sleep 300
    done
    # podman machine's memory is shared with other containers: wait until none is running
    while [ "${WAIT_IDLE:-1}" = 1 ] && [ -n "$("$CONTAINER" ps -q)" ]; do
        log "other containers are running ($("$CONTAINER" ps --format '{{.Names}}' | tr '\n' ' ')), waiting (WAIT_IDLE=0 to skip)"
        sleep 120
    done
    case "$arch" in aarch64) platform=linux/arm64;; x86_64) platform=linux/amd64;; *) die "unknown arch $arch";; esac
    name="osmesa-install-$tag-linux-$arch"
    log "$arch: building in a $IMAGE container ($platform; log: $WORK/out/build-$arch.log)"
    # the build runs in the container's own filesystem; only the sources, the tarballs and the
    # output are on the shared directory
    "$CONTAINER" run --rm --platform "$platform" --cpus "$CPUS" --memory "$MEMORY" \
        -v "$WORK:/host" -e CI_MESA_VERSION="$mesaversion" -e CI_LLVM_VERSION="$llvmversion" \
        -e MKJOBS="$MKJOBS" -e NAME="$name" -e ARCH="$arch" \
        -e BUILDINFO="$CONTAINER $platform on $(uname -s) $(uname -m), osmesa-install $commit (release/linux-local.sh)" \
        "$IMAGE" bash -c '
            set -eu
            cp -R /host/src /root/w && cd /root/w
            mkdir -p build && cp /host/dl/* build/
            echo "arch: $(uname -m)"
            bash release/linux-build.sh deps
            bash release/linux-build.sh osmesa
            bash release/linux-build.sh check "$ARCH"
            bash release/linux-build.sh package "$NAME" "$ARCH"
            bash release/linux-build.sh test "$NAME"
            cp "out/$NAME.tar.xz" /host/out/
            echo "container build $ARCH: OK"' > "$WORK/out/build-$arch.log" 2>&1 \
        || die "$arch build failed, see $WORK/out/build-$arch.log"
    tail -n 1 "$WORK/out/build-$arch.log"
done
ls -la "$WORK"/out/*.tar.xz

if [ "$upload" = 1 ]; then
    log "uploading to release $tag"
    files=
    for arch in $ARCHS; do files="$files $WORK/out/osmesa-install-$tag-linux-$arch.tar.xz"; done
    # publish.sh never replaces an archive already in the release (e.g. built on GitHub meanwhile)
    bash "$repo/release/publish.sh" "$tag" $files
    notes=$(gh release view "$tag" --repo devernay/osmesa-install --json body --jq .body)
    line="Some Linux archives were built locally in $IMAGE containers by [release/linux-local.sh](https://github.com/devernay/osmesa-install/blob/$commit/release/linux-local.sh) (see \"Built with\" in their README.txt)."
    case "$notes" in *"release/linux-local.sh"*) ;; *)
        printf '%s\n\n%s\n' "$notes" "$line" > "$WORK/notes.md"
        gh release edit "$tag" --repo devernay/osmesa-install --notes-file "$WORK/notes.md";;
    esac
    # macOS or Windows may still be building: the workflow's release job finalizes then
    ALLOW_MISSING="macos-arm64 macos-x86_64 windows-ucrt64-x86_64" bash "$repo/release/finalize.sh" "$tag" \
        || die "release check failed"
    log "release $tag: Linux archives uploaded and verified"
fi
