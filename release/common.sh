# shellcheck shell=bash
# Shared by the local release fallbacks, release/macos-vm.sh and release/linux-local.sh (sourced).
# The caller sets OS (macos or linux), DEFAULT_ARCHS and DEFAULT_WORK, then calls, in order:
#   init "$@"           parses [--upload] [TAG]; sets upload, tag, mesaversion, llvmversion, WORK, ARCHS
#   resolve_source      sets commit: the tag, or HEAD for a test build (without --upload)
#   skip_published      with --upload: drops the architectures already in the release
#   prepare_sources     $WORK/src (git archive $commit), $WORK/dl (tarballs, kept), $WORK/out
#   wait_for_host DIR   waits until the host load is below MAX_LOAD and DIR has MIN_FREE_GB free
#   publish_archives SCRIPT  with --upload: adds $WORK/out's archives to the release and checks it

set -eu
set -o pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
github_repo=devernay/osmesa-install
gluversion=9.0.1
demoversion=8.4.0
PLATFORMS="macos-arm64 macos-x86_64 windows-ucrt64-x86_64 windows-clangarm64-aarch64 linux-x86_64 linux-aarch64"

log() { echo "[$(date '+%F %T')] $*"; }
die() { echo "Error: $*" >&2; exit 1; }

init() {
    upload=0
    if [ "${1:-}" = --upload ]; then upload=1; shift; fi
    local wf="$repo/.github/workflows/release.yml"
    mesaversion=$(sed -n 's/^  CI_MESA_VERSION: *//p' "$wf")
    llvmversion=$(sed -n 's/^  CI_LLVM_VERSION: *//p' "$wf")
    tag="${1:-osmesa-mesa-$mesaversion-llvm-$llvmversion}"
    case "$tag" in
        osmesa-mesa-*-llvm-*)
            mesaversion=${tag#osmesa-mesa-}; mesaversion=${mesaversion%%-llvm-*}; llvmversion=${tag##*-llvm-};;
        *) die "TAG must be osmesa-mesa-<mesa version>-llvm-<llvm version>";;
    esac
    WORK=${WORK:-$DEFAULT_WORK}
    ARCHS=${ARCHS:-$DEFAULT_ARCHS}
    MIN_FREE_GB=${MIN_FREE_GB:-30}
    # the VM or container reads it: macOS would ask for access to ~/Documents
    case "$WORK" in "$HOME"/Documents*) die "WORK must not be in ~/Documents";; esac
    mkdir -p "$WORK"
    WORK=$(cd "$WORK" && pwd -P) # e.g. /private/tmp/...: podman machine shares /private, not /tmp
    [ "$upload" = 0 ] || command -v gh >/dev/null || die "gh not found"
}

resolve_source() {
    local rev
    if git -C "$repo" rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null; then
        rev=$tag
    elif [ "$upload" = 0 ]; then
        rev=HEAD
        log "tag $tag not found, building HEAD (test build)"
    else
        die "tag $tag not found (git fetch --tags)"
    fi
    commit=$(git -C "$repo" rev-parse "$rev^{commit}")
}

skip_published() {
    [ "$upload" = 1 ] || return 0
    local present archs arch
    # don't replace archives already in the release (the release may not exist yet: publish.sh
    # creates it)
    if gh api "repos/$github_repo/releases/tags/$tag" --silent 2>"$WORK/gh.err"; then
        present=$(gh release view "$tag" --repo "$github_repo" --json assets \
            --jq '.assets[] | "\(.name) \(.state)"')
    elif grep -q 'HTTP 404' "$WORK/gh.err"; then
        present=
    else
        cat "$WORK/gh.err" >&2; die "can't read release $tag"
    fi
    rm -f "$WORK/gh.err"
    archs=
    local name state
    for arch in $ARCHS; do
        name="osmesa-install-$tag-$OS-$arch.tar.xz"
        state=$(echo "$present" | awk -v n="$name" '$1 == n {print $2}')
        if [ -n "$state" ] && [ "$state" != uploaded ]; then
            # its upload broke off: publish.sh would refuse it after the build
            die "$name is in release $tag but its upload didn't finish (state $state): gh release delete-asset $tag $name"
        elif [ -n "$state" ]; then
            log "$arch: already in release $tag, skipping"
        else
            archs="$archs $arch"
        fi
    done
    ARCHS=${archs# }
    if [ -z "$ARCHS" ]; then
        log "nothing to build, checking the release"
        finalize_release
        exit 0
    fi
}

prepare_sources() {
    rm -rf "$WORK/src" "$WORK/out"
    mkdir -p "$WORK/src" "$WORK/dl" "$WORK/out"
    rm -f "$WORK"/dl/*.part
    git -C "$repo" archive "$commit" | tar -x -C "$WORK/src"
    fetch "llvm-project-$llvmversion.src.tar.xz" "https://github.com/llvm/llvm-project/releases/download/llvmorg-$llvmversion/llvm-project-$llvmversion.src.tar.xz"
    fetch "mesa-$mesaversion.tar.xz" "https://archive.mesa3d.org/mesa-$mesaversion.tar.xz"
    fetch "glu-$gluversion.tar.gz" "https://archive.mesa3d.org/glu/glu-$gluversion.tar.gz"
    fetch "mesa-demos-$demoversion.tar.bz2" "https://archive.mesa3d.org/demos/$demoversion/mesa-demos-$demoversion.tar.bz2"
}

fetch() { # file url (kept between runs)
    [ -f "$WORK/dl/$1" ] && return 0
    log "downloading $1"
    curl -fL --retry 3 -o "$WORK/dl/$1.part" "$2" && mv "$WORK/dl/$1.part" "$WORK/dl/$1"
}

wait_for_host() { # DIR: where the build's free space is measured
    local maxload load free
    maxload=${MAX_LOAD:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}
    while load=$(awk '{print int($1)}' /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg | awk '{print int($2)}')
          number "$load" "the host load"; [ "$load" -ge "$maxload" ]; do
        log "host load $load >= $maxload (MAX_LOAD), waiting"
        sleep 120
    done
    while free=$(df -Pk "$1" | awk 'NR==2 {print int($4 / 1048576)}')
          number "$free" "the free space"; [ "$free" -lt "$MIN_FREE_GB" ]; do
        log "only $free GB free for the build (< $MIN_FREE_GB), waiting"
        sleep 300
    done
}

number() { # value what: stop (fail closed) if a measurement isn't a number
    case "$1" in ''|*[!0-9]*) die "can't measure $2 (got '$1')";; esac
}

finalize_release() {
    # the platforms not built here may be missing (built on GitHub, possibly not finished yet)
    local allow='' p arch built
    for p in $PLATFORMS; do
        built=0
        for arch in $ARCHS; do [ "$p" = "$OS-$arch" ] && built=1; done
        [ "$built" = 1 ] || allow="$allow $p"
    done
    ALLOW_MISSING="$allow" bash "$repo/release/finalize.sh" "$tag" || die "release check failed"
}

publish_archives() { # script: the fallback's name, for the release notes
    [ "$upload" = 1 ] || return 0
    local files=() arch notes line
    log "uploading to release $tag"
    for arch in $ARCHS; do files+=("$WORK/out/osmesa-install-$tag-$OS-$arch.tar.xz"); done
    # publish.sh never replaces an archive already in the release (e.g. built on GitHub meanwhile)
    bash "$repo/release/publish.sh" "$tag" "${files[@]}"
    # say in the release notes that some archives were built here
    notes=$(gh release view "$tag" --repo "$github_repo" --json body --jq .body)
    line="Some $OSNAME archives were built locally by [release/$1](https://github.com/$github_repo/blob/$commit/release/$1) (see \"Built with\" in their README.txt)."
    case "$notes" in *"release/$1"*) ;; *)
        printf '%s\n\n%s\n' "$notes" "$line" > "$WORK/notes.md"
        gh release edit "$tag" --repo "$github_repo" --notes-file "$WORK/notes.md";;
    esac
    finalize_release
    log "release $tag: $OS archives uploaded and verified"
}
