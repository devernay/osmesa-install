#!/bin/bash
# Fallback for when GitHub's macOS runners are unavailable: build the macOS release archives (arm64
# and x86_64) in throwaway macOS 14 Sonoma tart VMs, and optionally upload them to the GitHub release
# made by .github/workflows/release.yml with the repository variable CI_MACOS_ON_VM=1 (which then
# builds and publishes only Windows and Linux). See "Making a release" in README.md.
#
# Usage: release/macos-vm.sh [--upload] [TAG]
#   TAG: osmesa-mesa-<mesa version>-llvm-<llvm version> (default: the versions in release.yml). The
#        sources are "git archive TAG" (or HEAD if the tag doesn't exist yet and --upload isn't given;
#        REV=<commit> for a test build of another commit).
#   --upload: add the archives, with ARCHIVE.sha256, to the release TAG with gh (as the account gh is
#        logged in with; see release/publish.sh and release/finalize.sh), update SHA256SUMS, check
#        anonymous downloads, and make it a full release if every platform is there. Architectures
#        already in the release (built on GitHub) are skipped. Without it, the archives are only left
#        in $WORK/out.
#
# The VM is a clone of ghcr.io/cirruslabs/macos-sonoma-base, which has the Xcode Command Line Tools
# (Apple clang, the macOS 14 and 15 SDKs, python3, bison, flex) and Rosetta. Nothing is installed in
# it: the sources, the tarballs and the Python build tools (meson, ninja, cmake, pkgconf, mako,
# pyyaml, packaging, from PyPI wheels) are prepared on this host in $WORK, which is shared with the
# VM, and the build output is written back there. The guest needs no network. Homebrew, which the
# base image contains, is kept out of PATH. Each architecture is built in its own clone, which is
# deleted afterwards; x86_64 is built under Rosetta ("arch -x86_64"). LLVM is built in the VM too.
#
# Host requirements: tart, git, curl, a python3 with pip (only to download the wheels; the Command
# Line Tools' /usr/bin/python3 by default), and gh for --upload.
# Environment: WORK (/tmp/osmesa-macos-vm, must not be in ~/Documents), ARCHS ("arm64 x86_64"),
# BASE_IMAGE, VM_CPU (4), VM_MEMORY (8192 MB), MKJOBS (4), HOST_PYTHON (/usr/bin/python3), KEEP_VM (0),
# MAX_LOAD (number of CPUs: each VM waits until the host load average is below it), MIN_FREE_GB (30:
# and until that much disk space is free).

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
WORK=${WORK:-/tmp/osmesa-macos-vm}
ARCHS=${ARCHS:-"arm64 x86_64"}
BASE_IMAGE=${BASE_IMAGE:-ghcr.io/cirruslabs/macos-sonoma-base:latest}
VM_CPU=${VM_CPU:-4}
VM_MEMORY=${VM_MEMORY:-8192}
MKJOBS=${MKJOBS:-4}
HOST_PYTHON=${HOST_PYTHON:-/usr/bin/python3}
KEEP_VM=${KEEP_VM:-0}
MIN_FREE_GB=${MIN_FREE_GB:-30}
deploymenttarget=14.0
gluversion=9.0.1
demoversion=8.4.0

log() { echo "[$(date '+%F %T')] $*"; }
die() { echo "Error: $*" >&2; exit 1; }

case "$WORK" in "$HOME"/Documents*) die "WORK must not be in ~/Documents (the VM reads it)";; esac
command -v tart >/dev/null || die "tart not found"

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
    if gh api "repos/devernay/osmesa-install/releases/tags/$tag" --silent 2>"$WORK.err"; then
        present=$(gh release view "$tag" --repo devernay/osmesa-install --json assets --jq '.assets[].name')
    elif grep -q 'HTTP 404' "$WORK.err"; then
        present=   # no release yet: publish.sh creates it
    else
        cat "$WORK.err" >&2; die "can't read release $tag"
    fi
    rm -f "$WORK.err"
    archs=
    for arch in $ARCHS; do
        if echo "$present" | grep -qx "osmesa-install-$tag-macos-$arch.tar.xz"; then
            log "$arch: already in release $tag, skipping"
        else
            archs="$archs $arch"
        fi
    done
    ARCHS=$archs
    if [ -z "$ARCHS" ]; then
        log "nothing to build, checking the release"
        ALLOW_MISSING="windows-ucrt64-x86_64 linux-x86_64 linux-aarch64" bash "$repo/release/finalize.sh" "$tag"
        exit 0
    fi
fi

mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
rm -rf "$WORK/src" "$WORK/out" "$WORK"/py-* "$WORK"/guest-build.sh
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

# Python build tools for the CLT's python3 (3.9), one directory per architecture
for arch in $ARCHS; do
    log "downloading the Python build tools for $arch"
    "$HOST_PYTHON" -m pip install --quiet --disable-pip-version-check --target "$WORK/py-$arch" \
        --platform "macosx_14_0_$arch" --python-version 3.9 --implementation cp --abi cp39 --only-binary=:all: \
        meson ninja "cmake<4" pkgconf mako pyyaml packaging
done

# the build, run in the guest as: bash guest-build.sh ARCH
cat > "$WORK/guest-build.sh" <<'GUEST'
#!/bin/bash
set -eu
set -o pipefail
arch=$1
# the shared directory, at a path without spaces (meson and libtool don't like them)
sudo ln -sfn "/Volumes/My Shared Files/work" /opt/w
w=/opt/w
. "$w/out/versions"
HOME=${HOME:-/Users/$(id -un)}
export HOME
b=$HOME/build
rm -rf "$b" "$HOME/osmesa" "$HOME/llvm"
mkdir -p "$b/bin" "$b/run" "$HOME/osmesa" "$HOME/llvm"
mkdir -p "$b/src"
cp -R "$w/src/." "$b/src/"
cp "$w"/dl/* "$b/run/"

# tools: only the Command Line Tools and the Python wheels, no Homebrew
py="$w/py-$arch"
export PATH="$b/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PYTHONPATH="$py"
export PYTHONNOUSERSITE=1
unset $(env | sed -n 's/^\(HOMEBREW_[A-Za-z_]*\)=.*/\1/p') CPATH LIBRARY_PATH PKG_CONFIG_PATH || true
printf '#!/bin/sh\nexec /usr/bin/python3 -m mesonbuild.mesonmain "$@"\n' > "$b/bin/meson"
# the executables in the wheels (bin/cmake and bin/pkgconf are Python scripts for the host's python)
ln -s "$py/bin/ninja" "$b/bin/ninja"
ln -s "$py/cmake/data/bin/cmake" "$b/bin/cmake"
ln -s "$py/pkgconf/.bin/pkgconf" "$b/bin/pkg-config"
if [ ! -x /usr/bin/xz ]; then
    # xz for the tarballs and package.sh, with Python's lzma module
    printf '#!/bin/sh\nexec /usr/bin/python3 -c "import lzma,shutil,sys; shutil.copyfileobj(lzma.open(sys.argv[1]), sys.stdout.buffer)" "$1"\n' > "$b/bin/xzcat"
    printf '#!/bin/sh\n# only "xz -9 -T0" (stdin to stdout) is used, by package.sh\nexec /usr/bin/python3 -c "import lzma,shutil,sys; f=lzma.open(sys.stdout.buffer, \\"wb\\", preset=9); shutil.copyfileobj(sys.stdin.buffer, f); f.close()"\n' > "$b/bin/xz"
fi
chmod +x "$b"/bin/*
sdk=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX14.*.sdk | sort | tail -n 1)
echo "arch $(arch -$arch /usr/bin/uname -m), SDK $sdk, $(clang --version | head -n 1)"
for t in meson ninja cmake pkg-config xzcat; do printf '%s: ' $t; $t --version 2>/dev/null | head -n 1 || echo ok; done

cd "$b/run"
arch -$arch /usr/bin/env MACOSX_DEPLOYMENT_TARGET=$deploymenttarget SDKROOT="$sdk" \
    OSMESA_VERSION=$mesaversion OSMESA_PREFIX="$HOME/osmesa" \
    LLVM_BUILD=1 LLVM_VERSION=$llvmversion LLVM_PREFIX="$HOME/llvm" \
    PYTHON=/usr/bin/python3 MKJOBS=$mkjobs CC=clang CXX=clang++ \
    /bin/bash ../src/osmesa-install.sh

# checks (as in release.yml)
lib="$HOME/osmesa/lib"
test "$(nm -g "$lib/libMangledOSMesa32.a" 2>/dev/null | grep -c ' T _gl[A-Z]' || true)" = 0
test "$(nm -g "$lib/libMangledOSMesa32.a" 2>/dev/null | grep -c ' T _mgl[A-Z]' || true)" -gt 1000
test "$(nm -g "$lib/libMangledGLU.a" 2>/dev/null | grep -c ' T _glu[A-Z]' || true)" = 0
for a in "$lib/libMangledOSMesa32.a" "$lib/libMangledGLU.a" "$HOME/llvm/lib/libLLVMCore.a"; do
    archs=$(lipo -archs "$a")
    minos=$(otool -l "$a" | awk '/minos/ {print $2}' | sort -u | tr '\n' ' ')
    echo "$a: $archs, minos $minos"
    test "$archs" = "$arch"
    test "$minos" = "$deploymenttarget "
done
for f in osdemo osdemo16 osdemo32 osmesa_mt_test; do
    p=$(ls mesa-demos-*/src/osdemos/$f)
    test "$(lipo -archs "$p")" = "$arch"
    if otool -L "$p" | tail -n +2 | grep -Ev '^[[:space:]]*(/usr/lib/|/System/)'; then
        echo "Error: $f depends on non-system libraries"; exit 1
    fi
done

name="osmesa-install-$tag-macos-$arch"
echo "  macOS $(sw_vers -productVersion) tart VM (cirruslabs macos-sonoma-base), Command Line Tools $(pkgutil --pkg-info=com.apple.pkg.CLTools_Executables | sed -n 's/^version: //p'), $(basename "$sdk"), Apple clang $(clang -dumpversion), $([ "$arch" = x86_64 ] && echo 'x86_64 under Rosetta, ')Python build tools from PyPI, MACOSX_DEPLOYMENT_TARGET=$deploymenttarget, osmesa-install $commit (release/macos-vm.sh)" > "$w/out/$name.buildinfo"
arch -$arch /usr/bin/env MACOSX_DEPLOYMENT_TARGET=$deploymenttarget \
    /bin/bash ../src/release/package.sh "$name" "$HOME/osmesa" "$HOME/llvm" . "$w/out" \
    "macOS $deploymenttarget and later, $arch"
rm -f "$w/out/$name.buildinfo"
tar tJf "$w/out/$name.tar.xz" | sed -n 1,40p
echo "guest build $arch: OK"
GUEST
cat > "$WORK/out/versions" <<EOF
tag=$tag
commit=$commit
mesaversion=$mesaversion
llvmversion=$llvmversion
deploymenttarget=$deploymenttarget
mkjobs=$MKJOBS
EOF

vm=
cleanup() {
    if [ -n "$vm" ] && [ "$KEEP_VM" = 0 ]; then
        tart stop "$vm" >/dev/null 2>&1 || true
        tart delete "$vm" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# one VM at a time, started only when the host isn't overloaded
maxload=${MAX_LOAD:-$(sysctl -n hw.ncpu)}
for arch in $ARCHS; do
    while load=$(sysctl -n vm.loadavg | awk '{print int($2)}'); [ "$load" -ge "$maxload" ]; do
        log "host load $load >= $maxload (MAX_LOAD), waiting"
        sleep 120
    done
    # the clone grows by up to ~20 GB during the build
    while free=$(df -g "$WORK" | awk 'NR==2 {print $4}'); [ "$free" -lt "$MIN_FREE_GB" ]; do
        log "only $free GB free on the disk of $WORK (< MIN_FREE_GB=$MIN_FREE_GB), waiting"
        sleep 300
    done
    vm="osmesa-macos-vm-$arch-$$"
    log "$arch: cloning $BASE_IMAGE as $vm"
    tart clone "$BASE_IMAGE" "$vm"
    tart set "$vm" --cpu "$VM_CPU" --memory "$VM_MEMORY"
    tart run --no-graphics --dir="work:$WORK" "$vm" > "$WORK/out/tart-$arch.log" 2>&1 &
    for i in $(seq 120); do
        tart exec "$vm" true >/dev/null 2>&1 && break
        [ "$i" = 120 ] && die "$vm doesn't answer (tart exec)"
        sleep 5
    done
    log "$arch: building in $vm (log: $WORK/out/build-$arch.log)"
    tart exec "$vm" /bin/bash "/Volumes/My Shared Files/work/guest-build.sh" "$arch" > "$WORK/out/build-$arch.log" 2>&1 \
        || die "$arch build failed, see $WORK/out/build-$arch.log"
    tail -n 1 "$WORK/out/build-$arch.log"
    cleanup
    vm=
done
ls -la "$WORK"/out/*.tar.xz

if [ "$upload" = 1 ]; then
    # add the archives (and their .sha256) to the release, creating it as a pre-release if needed,
    # then check it and make it a full release if every platform is there
    log "uploading to release $tag"
    files=
    for arch in $ARCHS; do files="$files $WORK/out/osmesa-install-$tag-macos-$arch.tar.xz"; done
    # publish.sh never replaces an archive already in the release (e.g. built on GitHub meanwhile)
    bash "$repo/release/publish.sh" "$tag" $files
    # say in the release notes which archives were built here
    notes=$(gh release view "$tag" --repo devernay/osmesa-install --json body --jq .body)
    line="Some macOS archives were built in macOS 14 VMs by [release/macos-vm.sh](https://github.com/devernay/osmesa-install/blob/$commit/release/macos-vm.sh) (see \"Built with\" in their README.txt)."
    case "$notes" in *"release/macos-vm.sh"*) ;; *)
        printf '%s\n\n%s\n' "$notes" "$line" > "$WORK/notes.md"
        gh release edit "$tag" --repo devernay/osmesa-install --notes-file "$WORK/notes.md";;
    esac
    # Windows or Linux may still be building on GitHub: the workflow's release job finalizes then
    ALLOW_MISSING="windows-ucrt64-x86_64 linux-x86_64 linux-aarch64" bash "$repo/release/finalize.sh" "$tag" \
        || die "release check failed"
    log "release $tag: macOS archives uploaded and verified"
fi
