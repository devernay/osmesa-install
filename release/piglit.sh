#!/bin/bash
# Run piglit (Mesa's OpenGL test suite) on a release archive, with piglit's OSMesa framework
# (patches/piglit-<commit>/), and compare the results with Mesa's llvmpipe CI expectations, so that
# only new failures count. Run from the repository's root, on Linux (as root in a rockylinux:9
# container: "deps" installs what it needs) or on macOS (MacPorts' cmake, libpng and a python3
# with mako and numpy, given with PYTHON):
#
#   release/piglit.sh deps                 install the tools to build and run piglit
#   release/piglit.sh fetch                clone piglit at PIGLIT_COMMIT in $WORK/piglit, and patch it
#   release/piglit.sh build ARCHIVE        build piglit against ARCHIVE (osmesa-install-*.tar.xz, or
#                                          the directory it unpacks to: osmesa/, llvm/, link-flags.txt)
#   release/piglit.sh expectations         Mesa's llvmpipe expectations, in $WORK/expectations
#   release/piglit.sh run [PROFILE]        run a piglit profile (default: $PROFILE) into
#                                          $WORK/results/PROFILE
#   release/piglit.sh compare [PROFILE]    compare the results with the expectations: fails if there
#                                          are new failures
#   release/piglit.sh all ARCHIVE [PROFILE...]  all of the above (default profiles: $PROFILE)
#   release/piglit.sh local ARCHIVE [PROFILE...]  "all", in a throwaway rockylinux:9 container
#                                          (podman or docker; on the host, e.g. macOS)
#
# Profiles: sanity (a few tests, 1 min), llvmpipe_gl (quick_gl without its slowest tests, as
# Mesa's CI runs on llvmpipe; the default), quick_gl, or any profile in piglit's tests/.
# The tests that Mesa's CI skips on llvmpipe (*-skips.txt) are excluded (piglit run -x).
#
# Environment: WORK (/root/piglit-work; for "local", on the host: /tmp/osmesa-piglit-local),
# PROFILE (llvmpipe_gl), JOBS (4: tests run in parallel), MKJOBS (4), TIMEOUT (120 s per test),
# GALLIUM_DRIVER (llvmpipe; or softpipe), PYTHON (python3: runs piglit and piglit-compare.py),
# CMAKE_PREFIX_PATH (/opt/local on macOS, for libpng), MESA_VERSION (from the archive's README.txt, else
# 25.0.7: the Mesa release whose CI expectations are used).
# "local" only: CONTAINER (podman), IMAGE (docker.io/library/rockylinux:9), PLATFORM (the host's:
# linux/arm64 or linux/amd64), CPUS (4), MEMORY_GB (6).

set -eu
set -o pipefail

# piglit: the commit used by Mesa 25.0's CI (.gitlab-ci/container/build-piglit.sh in Mesa 25.0.7)
PIGLIT_COMMIT=68658566da1c9cd6a378b5ca36999617e26440e7
PIGLIT_URL=https://gitlab.freedesktop.org/mesa/piglit.git
# applied in this order, from patches/piglit-<first 7 characters of PIGLIT_COMMIT>/
PIGLIT_PATCHES="osmesa-framework.patch disable-vs_in.patch numpy2-reshape.patch"

repo=$(cd "$(dirname "$0")/.." && pwd)
usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 1; }
die() { echo "Error: $*" >&2; exit 1; }
log() { echo "[$(date '+%F %T')] $*"; }
[ $# -ge 1 ] || usage
stage=$1; shift

PROFILE=${PROFILE:-llvmpipe_gl}
JOBS=${JOBS:-4}
MKJOBS=${MKJOBS:-4}
TIMEOUT=${TIMEOUT:-120}
export GALLIUM_DRIVER=${GALLIUM_DRIVER:-llvmpipe}
PYTHON=${PYTHON:-python3}
osname=$(uname)
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

toolset() {
    # gcc-toolset-14's enable script uses unset variables
    if [ -f /opt/rh/gcc-toolset-14/enable ]; then
        set +u
        # shellcheck disable=SC1091
        . /opt/rh/gcc-toolset-14/enable
        set -u
    fi
}

# the archive's directory: unpacks ARCHIVE.tar.xz in $WORK/archive
archive_dir() {
    local a=$1 d
    case "$a" in
    *.tar.xz)
        [ -f "$a" ] || die "$a not found"
        d=$WORK/archive/$(basename "$a" .tar.xz)
        if [ ! -d "$d" ]; then
            mkdir -p "$WORK/archive"
            tar xJf "$a" -C "$WORK/archive"
        fi;;
    *) d=$a;;
    esac
    [ -f "$d/link-flags.txt" ] && [ -d "$d/osmesa/lib" ] && [ -d "$d/llvm/lib" ] \
        || die "$d is not an osmesa-install release archive (osmesa/, llvm/, link-flags.txt)"
    (cd "$d" && pwd)
}

mesa_version() {
    local v=""
    [ -f "$WORK/archive-dir" ] && v=$(sed -n 's/^- Mesa \([0-9.]*\) OSMesa.*/\1/p' "$(cat "$WORK/archive-dir")/README.txt")
    echo "${MESA_VERSION:-${v:-25.0.7}}"
}

piglit_dir() { echo "$WORK/piglit"; }

do_deps() {
    dnf install -y dnf-plugins-core epel-release
    dnf config-manager --set-enabled crb
    # piglit: cmake, python3 with mako and numpy, libpng (to write images), git to fetch it
    dnf install -y gcc-toolset-14 cmake make patch diffutils tar xz bzip2 which file git \
        python3 python3-mako python3-numpy libpng-devel zlib-devel pkgconfig
}

do_fetch() {
    local p short d
    p=$(piglit_dir)
    short=$(echo "$PIGLIT_COMMIT" | cut -c1-7)
    d=$repo/patches/piglit-$short
    [ -d "$d" ] || die "no patches for piglit $short ($d)"
    rm -rf "$p"
    mkdir -p "$WORK"
    git clone --quiet --no-checkout "$PIGLIT_URL" "$p"
    git -C "$p" checkout --quiet "$PIGLIT_COMMIT"
    for patch in $PIGLIT_PATCHES; do
        log "piglit: applying $patch"
        patch -d "$p" -p1 < "$d/$patch"
    done
}

# libOSMesaPiglit.so: the archive's static OSMesa and LLVM in one shared library, which every
# piglit test links (instead of statically linking LLVM into each of ~2000 programs). The
# archives are built with -fPIC. -u pulls the OSMesa API, and with it every GL function, which
# piglit-dispatch gets from OSMesaGetProcAddress (with gl* names, also with a mangled OSMesa).
build_osmesa_lib() {
    local d=$1 out=$2 lib l libs f
    lib=
    for l in libMangledOSMesa32.a libOSMesa32.a libOSMesa.a; do
        if [ -f "$d/osmesa/lib/$l" ]; then lib=$l; break; fi
    done
    [ -n "$lib" ] || die "no OSMesa static library in $d/osmesa/lib"
    # link-flags.txt: -lMangledGLU -lMangledOSMesa32 -lLLVM... and the system libraries; no GLU
    libs=$(sed -e 's/-lMangledGLU //' -e 's/-lGLU //' "$d/link-flags.txt")
    mkdir -p "$(dirname "$out")"
    if [ "$osname" = Darwin ]; then
        # a dylib named by its absolute path (the tests find it without rpath); symbols have a
        # leading underscore; undefined symbols are errors by default
        # shellcheck disable=SC2086 # word splitting of the flags is intended
        clang++ -dynamiclib -o "$out" -install_name "$out" \
            -Wl,-u,_OSMesaCreateContextAttribs -Wl,-u,_OSMesaMakeCurrent -Wl,-u,_OSMesaDestroyContext \
            -Wl,-u,_OSMesaGetProcAddress -Wl,-u,_OSMesaPixelStore \
            -L"$d/osmesa/lib" -L"$d/llvm/lib" $libs
        f=$(nm -gU "$out")
        echo "$out ($lib): $(echo "$f" | grep -c ' T _mgl[A-Z]' || true) mgl* and" \
            "$(echo "$f" | grep -c ' T _gl[A-Z]' || true) gl* functions exported"
        return 0
    fi
    # shellcheck disable=SC2086 # word splitting of the flags is intended
    g++ -shared -o "$out" -Wl,-soname,"$(basename "$out")" \
        -Wl,-u,OSMesaCreateContextAttribs -Wl,-u,OSMesaMakeCurrent -Wl,-u,OSMesaDestroyContext \
        -Wl,-u,OSMesaGetProcAddress -Wl,-u,OSMesaPixelStore \
        -L"$d/osmesa/lib" -L"$d/llvm/lib" $libs -Wl,--no-undefined
    echo "$out ($lib): $(nm -D --defined-only "$out" | grep -c ' T mgl[A-Z]' || true) mgl* and" \
        "$(nm -D --defined-only "$out" | grep -c ' T gl[A-Z]' || true) gl* functions exported"
}

do_build() {
    local d p lib ext=so prefixpath cxxflags
    [ $# -ge 1 ] || usage
    toolset
    d=$(archive_dir "$1")
    mkdir -p "$WORK"
    echo "$d" > "$WORK/archive-dir"
    p=$(piglit_dir)
    [ -d "$p" ] || do_fetch
    [ "$osname" != Darwin ] || ext=dylib
    lib=$WORK/lib/libOSMesaPiglit.$ext
    build_osmesa_lib "$d" "$lib"
    prefixpath=${CMAKE_PREFIX_PATH:-}
    cxxflags=
    if [ "$osname" = Darwin ]; then
        prefixpath=${prefixpath:-/opt/local}
        # piglit is built with gcc in Mesa's CI: clang makes some of its narrowing conversions
        # errors (e.g. tests/util/piglit-test-pattern.cpp)
        cxxflags="-Wno-c++11-narrowing"
    fi
    # in the source tree, as Mesa's CI does: "piglit run" runs from there
    cmake -S "$p" -B "$p" -DCMAKE_BUILD_TYPE=Release \
        -DPIGLIT_USE_OSMESA=ON -DPython_EXECUTABLE="$(command -v "$PYTHON")" \
        -DPYTHON_EXECUTABLE="$(command -v "$PYTHON")" ${prefixpath:+-DCMAKE_PREFIX_PATH="$prefixpath"} \
        -DOSMesa_LIBRARIES="$lib" -DOSMesa_INCLUDE_DIR="$d/osmesa/include" \
        ${cxxflags:+-DCMAKE_CXX_FLAGS="$cxxflags"} \
        -DPIGLIT_BUILD_GL_TESTS=ON -DPIGLIT_BUILD_GLES1_TESTS=OFF -DPIGLIT_BUILD_GLES2_TESTS=OFF \
        -DPIGLIT_BUILD_GLES3_TESTS=OFF -DPIGLIT_BUILD_CL_TESTS=OFF -DPIGLIT_BUILD_VK_TESTS=OFF \
        -DPIGLIT_BUILD_DMA_BUF_TESTS=OFF
    cmake --build "$p" -j "$MKJOBS" > "$WORK/piglit-build.log" 2>&1 \
        || { tail -n 50 "$WORK/piglit-build.log"; die "piglit build failed, see $WORK/piglit-build.log"; }
    tail -n 3 "$WORK/piglit-build.log"
    echo "piglit: $(find "$p/bin" -type f | wc -l) programs in $p/bin"
    # a quick check that a test runs
    "$p/bin/glinfo" -auto | sed -n '1,/^GL_EXTENSIONS/p' | grep -v '^GL_EXTENSIONS' || true
}

# Mesa's CI expectations for llvmpipe (and its skips for every driver), from the Mesa release
# tarball (gitlab.freedesktop.org refuses scripted downloads)
do_expectations() {
    local v e t ci
    v=$(mesa_version)
    e=$WORK/expectations
    t=$WORK/dl/mesa-$v.tar.xz
    if [ -f "$e/mesa-$v" ]; then return 0; fi
    mkdir -p "$WORK/dl" "$e"
    if [ ! -f "$t" ]; then
        curl -fL --retry 3 -o "$t.part" "https://archive.mesa3d.org/mesa-$v.tar.xz"
        mv "$t.part" "$t"
    fi
    if [ "$v" = 25.0.7 ]; then
        echo "592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6  $t" | sha256 -c -
    fi
    ci=mesa-$v/src/gallium/drivers/llvmpipe/ci
    rm -rf "$WORK/mesa-ci" && mkdir -p "$WORK/mesa-ci"
    tar xJf "$t" -C "$WORK/mesa-ci" "$ci/llvmpipe-fails.txt" "$ci/llvmpipe-flakes.txt" \
        "$ci/llvmpipe-skips.txt" "mesa-$v/.gitlab-ci/all-skips.txt"
    cp "$WORK/mesa-ci/$ci/"llvmpipe-{fails,flakes,skips}.txt "$e/"
    cp "$WORK/mesa-ci/mesa-$v/.gitlab-ci/all-skips.txt" "$e/all-skips.txt"
    rm -rf "$WORK/mesa-ci"
    touch "$e/mesa-$v"
}

do_run() {
    local profile=${1:-$PROFILE} p r excludes f line short
    p=$(piglit_dir)
    r=$WORK/results/$profile
    do_expectations
    excludes=()
    for f in llvmpipe-skips.txt all-skips.txt; do
        while IFS= read -r line; do
            case "$line" in ''|'#'*) continue;; esac
            excludes+=(-x "$line")
        done < "$WORK/expectations/$f"
    done
    # ours (patches/piglit-*/osmesa-skips.txt): tests that can't work without a window system
    short=$(echo "$PIGLIT_COMMIT" | cut -c1-7)
    if [ -f "$repo/patches/piglit-$short/osmesa-skips.txt" ]; then
        while IFS= read -r line; do
            case "$line" in ''|'#'*) continue;; esac
            excludes+=(-x "$line")
        done < "$repo/patches/piglit-$short/osmesa-skips.txt"
    fi
    rm -rf "$r"
    mkdir -p "$WORK/results"
    log "piglit: running $profile with $GALLIUM_DRIVER ($JOBS jobs, ${TIMEOUT}s timeout) into $r"
    # results go to the log; the summary is in "compare"
    local start=$SECONDS
    # PIGLIT_NO_FAST_SKIP: piglit's runner pre-filters tests with wflinfo (waffle), which has no
    # OSMesa backend; without it, every test with a GL or GLSL version requirement would be skipped
    # as needing more than "0.0". Each test then checks its own requirements when it runs.
    (cd "$p" && PIGLIT_PLATFORM=osmesa PIGLIT_NO_FAST_SKIP=1 "$PYTHON" ./piglit run -p osmesa -j "$JOBS" --timeout "$TIMEOUT" \
        -l verbose "${excludes[@]}" "$profile" "$r") > "$WORK/results/$profile.log" 2>&1 \
        || { tail -n 30 "$WORK/results/$profile.log"; die "piglit run failed, see $WORK/results/$profile.log"; }
    log "piglit: $profile ran in $((SECONDS - start)) s"
}

do_compare() {
    local profile=${1:-$PROFILE} short e args kind f
    short=$(echo "$PIGLIT_COMMIT" | cut -c1-7)
    e=$WORK/expectations
    args=(--fails "$e/llvmpipe-fails.txt" --flakes "$e/llvmpipe-flakes.txt"
          --skips "$e/llvmpipe-skips.txt" --skips "$e/all-skips.txt")
    # ours: failures with OSMesa that Mesa's CI (with a window system) doesn't have
    for kind in fails flakes skips; do
        f=$repo/patches/piglit-$short/osmesa-$kind.txt
        [ ! -f "$f" ] || args+=("--$kind" "$f")
    done
    "$PYTHON" -I "$repo/release/piglit-compare.py" "$WORK/results/$profile" "${args[@]}" \
        --list-out "$WORK/results/$profile.txt"
}

do_local() {
    [ $# -ge 1 ] || usage
    local a=$1; shift
    local container=${CONTAINER:-podman} image=${IMAGE:-docker.io/library/rockylinux:9}
    local platform=${PLATFORM:-} host
    case "$(uname -m)" in arm64|aarch64) host=linux/arm64;; *) host=linux/amd64;; esac
    platform=${platform:-$host}
    case "$WORK" in "$HOME"/Documents*) die "WORK must not be in ~/Documents";; esac
    [ -f "$a" ] || die "$a not found (a release archive, osmesa-install-*-linux-*.tar.xz)"
    command -v "$container" >/dev/null || die "$container not found"
    mkdir -p "$WORK/src" "$WORK/out"
    WORK=$(cd "$WORK" && pwd -P) # e.g. /private/tmp/...: podman machine shares /private, not /tmp
    cp "$a" "$WORK/out/"
    # the sources: this checkout's release/ and patches/ (uncommitted changes included)
    rm -rf "$WORK/src" && mkdir -p "$WORK/src"
    cp -R "$repo/release" "$repo/patches" "$WORK/src/"
    log "piglit in a $image container ($platform; log: $WORK/out/piglit.log)"
    # label=disable: SELinux hosts would deny access to the shared directory
    # shellcheck disable=SC2016 # expanded in the container
    "$container" run --rm --platform "$platform" --security-opt label=disable \
        --cpus "${CPUS:-4}" --memory "${MEMORY_GB:-6}g" -v "$WORK:/host" \
        -e MKJOBS="$MKJOBS" -e JOBS="$JOBS" -e TIMEOUT="$TIMEOUT" -e GALLIUM_DRIVER="$GALLIUM_DRIVER" \
        -e ARCHIVE="/host/out/$(basename "$a")" -e PROFILES="$*" \
        "$image" bash -c '
            set -eu
            cp -R /host/src /root/w && cd /root/w
            bash release/piglit.sh deps > /root/deps.log 2>&1 || { tail -n 30 /root/deps.log; exit 1; }
            status=0
            WORK=/root/piglit-work bash release/piglit.sh all "$ARCHIVE" $PROFILES || status=$?
            mkdir -p /host/out/results
            cp -R /root/piglit-work/results/. /host/out/results/
            cp /root/piglit-work/piglit-build.log /host/out/ 2>/dev/null || true
            exit $status' > "$WORK/out/piglit.log" 2>&1 \
        || { tail -n 60 "$WORK/out/piglit.log"; die "piglit failed, see $WORK/out/piglit.log"; }
    tail -n 30 "$WORK/out/piglit.log"
}

if [ "$stage" = local ]; then WORK=${WORK:-/tmp/osmesa-piglit-local}; else WORK=${WORK:-/root/piglit-work}; fi
case "$stage" in
deps) do_deps;;
fetch) do_fetch;;
build) do_build "$@";;
expectations) do_expectations;;
run) do_run "$@";;
compare) do_compare "$@";;
all)
    [ $# -ge 1 ] || usage
    a=$1; shift
    [ $# -ge 1 ] || set -- "$PROFILE"
    do_fetch
    do_build "$a"
    do_expectations
    status=0
    for profile in "$@"; do
        do_run "$profile"
        do_compare "$profile" || status=1
    done
    exit $status;;
local) do_local "$@";;
*)
    die "unknown stage $stage";;
esac
