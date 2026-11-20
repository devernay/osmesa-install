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

OS=macos
OSNAME=macOS
DEFAULT_ARCHS="arm64 x86_64"
DEFAULT_WORK=/tmp/osmesa-macos-vm
# shellcheck source=release/common.sh
. "$(dirname "$0")/common.sh"
init "$@"
BASE_IMAGE=${BASE_IMAGE:-ghcr.io/cirruslabs/macos-sonoma-base:latest}
VM_CPU=${VM_CPU:-4}
VM_MEMORY=${VM_MEMORY:-8192}
MKJOBS=${MKJOBS:-4}
HOST_PYTHON=${HOST_PYTHON:-/usr/bin/python3}
KEEP_VM=${KEEP_VM:-0}
deploymenttarget=14.0

command -v tart >/dev/null || die "tart not found"
resolve_source
skip_published
rm -rf "$WORK"/py-* "$WORK"/guest-build.sh
prepare_sources

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

# one VM at a time, started only when the host isn't overloaded (the clone grows by up to ~20 GB)
for arch in $ARCHS; do
    wait_for_host "$WORK"
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

publish_archives macos-vm.sh
