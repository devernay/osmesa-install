#!/bin/bash
# The Linux release build, run as root in a rockylinux:9 container, by .github/workflows/release.yml
# (one step per stage) and by release/linux-local.sh (all stages). From the repository's root:
#
#   release/linux-build.sh deps-llvm     install the tools to build LLVM
#   release/linux-build.sh deps          install the tools and libraries to build OSMesa (no libdrm)
#   release/linux-build.sh llvm          build LLVM into $LLVM_PREFIX
#   release/linux-build.sh osmesa        build OSMesa, GLU and the osdemos (and LLVM if not there)
#   release/linux-build.sh check ARCH    check the libraries and the test program
#   release/linux-build.sh package NAME ARCH  package out/NAME.tar.xz
#   release/linux-build.sh test-cmake NAME      test the archive with CMake (find_package(OSMesa))
#   release/linux-build.sh test-pkgconfig NAME  test the archive with pkg-config
#
# Environment: CI_MESA_VERSION, CI_LLVM_VERSION (required), LLVM_PREFIX (/root/llvm-$CI_LLVM_VERSION),
# OSMESA_PREFIX (/root/osmesa), MKJOBS (nproc), BUILDINFO (first line of "Built with" in README.txt).

set -eu
set -o pipefail

usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 1; }
[ $# -ge 1 ] || usage
stage=$1; shift
: "${CI_MESA_VERSION:?}" "${CI_LLVM_VERSION:?}"
LLVM_PREFIX=${LLVM_PREFIX:-/root/llvm-$CI_LLVM_VERSION}
OSMESA_PREFIX=${OSMESA_PREFIX:-/root/osmesa}
MKJOBS=${MKJOBS:-$(nproc)}

toolset() {
    # gcc-toolset-14's enable script uses unset variables
    set +u; source /opt/rh/gcc-toolset-14/enable; set -u
}

case "$stage" in
deps-llvm)
    dnf install -y dnf-plugins-core
    dnf install -y gcc-toolset-14 cmake make patch diffutils tar xz which git python3.12
    ;;
deps)
    # no libdrm: Mesa links it when its headers are found, and OSMesa doesn't need it
    dnf install -y dnf-plugins-core epel-release
    dnf config-manager --set-enabled crb
    dnf install -y gcc-toolset-14 cmake make patch diffutils tar xz bzip2 which file git \
        python3.12 python3.12-pip bison flex autoconf automake libtool pkgconfig \
        zlib-devel freeglut-devel
    python3.12 -m pip install meson ninja mako pyyaml packaging
    # freeglut-devel (GL/glut.h, for the osdemos) pulls in mesa-libGL-devel and libdrm-devel:
    # remove libdrm's headers and pkg-config file, so that Mesa can't find and link libdrm
    rpm -e --nodeps libdrm-devel
    if pkg-config --exists libdrm; then echo "Error: libdrm is still installed"; exit 1; fi
    ;;
llvm)
    toolset
    mkdir -p build "$OSMESA_PREFIX" "$LLVM_PREFIX"
    cd build
    env OSMESA_VERSION="$CI_MESA_VERSION" LLVM_VERSION="$CI_LLVM_VERSION" OSMESA_PREFIX="$OSMESA_PREFIX" \
        LLVM_PREFIX="$LLVM_PREFIX" BUILD_OSMESA=0 BUILD_GLU=0 BUILD_OSDEMO=0 MKJOBS="$MKJOBS" \
        bash ../osmesa-install.sh
    ;;
osmesa)
    toolset
    export PATH="/usr/local/bin:$PATH" # meson and ninja from pip
    mkdir -p build "$OSMESA_PREFIX" "$LLVM_PREFIX"
    cd build
    # LLVM_BUILD=auto (the default): builds LLVM if LLVM_PREFIX has none
    env OSMESA_VERSION="$CI_MESA_VERSION" LLVM_VERSION="$CI_LLVM_VERSION" OSMESA_PREFIX="$OSMESA_PREFIX" \
        LLVM_PREFIX="$LLVM_PREFIX" PYTHON=/usr/bin/python3.12 MKJOBS="$MKJOBS" \
        bash ../osmesa-install.sh
    ;;
check)
    arch=$1
    lib=$OSMESA_PREFIX/lib
    t=$(ls build/mesa-demos-*/src/osdemos/osmesa_mt_test)
    test "$(nm -g "$lib/libMangledOSMesa32.a" 2>/dev/null | grep -c ' T gl[A-Z]' || true)" = 0
    test "$(nm -g "$lib/libMangledOSMesa32.a" 2>/dev/null | grep -c ' T mgl[A-Z]' || true)" -gt 1000
    test "$(nm -g "$lib/libMangledGLU.a" 2>/dev/null | grep -c ' T glu[A-Z]' || true)" = 0
    # no libdrm, no zlib
    test "$(nm -u "$lib/libMangledOSMesa32.a" 2>/dev/null | grep -c ' drm' || true)" = 0
    test "$(nm -u "$lib/libMangledOSMesa32.a" 2>/dev/null | grep -cE ' (inflate|deflate)' || true)" = 0
    # the architecture
    if ! file "$t" | grep "$( [ "$arch" = aarch64 ] && echo 'ARM aarch64' || echo 'x86-64')" >/dev/null; then
        echo "Error: osmesa_mt_test is not for $arch: $(file "$t")"; exit 1
    fi
    # the test program only needs the system runtime (libc, libm, libpthread, libdl, librt,
    # libstdc++, libgcc_s), as plug-in bundles require
    ldd "$t"
    if ldd "$t" | grep -vE '^\s*(linux-vdso|/lib(64)?/ld-linux|lib(c|m|pthread|dl|rt|stdc\+\+|gcc_s)\.so)'; then
        echo "Error: osmesa_mt_test depends on non-system libraries"; exit 1
    fi
    # linked with gcc-toolset-14, it must only need the libstdc++ of Rocky 9's GCC 11
    # (GLIBCXX_3.4.29, CXXABI_1.3.13): newer symbols come from libstdc++_nonshared.a;
    # and the glibc of Rocky 9 (GLIBC_2.34)
    gccmax=7.0.0; [ "$arch" = aarch64 ] && gccmax=11.0
    for v in "GLIBCXX_ 3.4.29" "CXXABI_ 1.3.13" "GLIBC_ 2.34" "GCC_ $gccmax"; do
        set -- $v
        # (none of a family: nothing required)
        newest=$(objdump -T "$t" | { grep -o "$1[0-9.]*" || true; } | sed "s/^$1//" | sort -uV | tail -1)
        echo "newest $1: $newest (Rocky 9: $2)"
        test "$(printf '%s\n' "$newest" "$2" | sort -V | tail -1)" = "$2"
    done
    # no packed relative relocations (DT_RELR), which EL9's loader doesn't support
    if readelf -d "$t" | grep RELR >/dev/null; then echo "Error: osmesa_mt_test has DT_RELR"; exit 1; fi
    ;;
package)
    name=$1 arch=$2
    toolset
    mkdir -p out
    {
        echo "  Rocky Linux $(rpm -E %rhel) container, $(gcc --version | head -1), glibc $(ldd --version | head -1 | awk '{print $NF}')"
        [ -z "${BUILDINFO:-}" ] || echo "  $BUILDINFO"
    } > "out/$name.buildinfo"
    bash release/package.sh "$name" "$OSMESA_PREFIX" "$LLVM_PREFIX" build out \
        "Linux $arch, glibc 2.34 and later (Rocky/RHEL 9), gcc-toolset-14"
    tar tJf "out/$name.tar.xz" | sed -n 1,40p
    ;;
test-cmake)
    # find_package(OSMesa CONFIG), OSMesa::OSMesa
    name=$1
    toolset
    rm -rf /tmp/unpack /tmp/cmaketest
    mkdir -p /tmp/unpack /tmp/cmaketest && tar xJf "out/$name.tar.xz" -C /tmp/unpack
    cp osdemo/osmesa_mt_test.c /tmp/cmaketest/
    printf '%s\n' 'cmake_minimum_required(VERSION 3.16)' 'project(t C CXX)' \
        'find_package(OSMesa CONFIG REQUIRED)' 'find_package(Threads REQUIRED)' \
        'add_executable(t osmesa_mt_test.c)' 'target_compile_definitions(t PRIVATE MANGLED)' \
        'target_link_libraries(t PRIVATE OSMesa::GLU Threads::Threads)' \
        'set_target_properties(t PROPERTIES LINKER_LANGUAGE CXX)' > /tmp/cmaketest/CMakeLists.txt
    cmake -S /tmp/cmaketest -B /tmp/cmaketest/build -DOSMesa_DIR="/tmp/unpack/$name/osmesa/lib/cmake/OSMesa"
    cmake --build /tmp/cmaketest/build
    /tmp/cmaketest/build/t 8 20 2
    ldd /tmp/cmaketest/build/t
    ;;
test-pkgconfig)
    # pkg-config --static --cflags --libs osmesa, without -DMANGLED: the .pc file's Cflags must
    # select the mgl* names (USE_MGL_NAMESPACE)
    name=$1
    toolset
    rm -rf /tmp/unpack-pc
    mkdir -p /tmp/unpack-pc && tar xJf "out/$name.tar.xz" -C /tmp/unpack-pc
    export PKG_CONFIG_PATH="/tmp/unpack-pc/$name/osmesa/lib/pkgconfig"
    pkg-config --static --cflags --libs osmesa
    # shellcheck disable=SC2046 # word splitting of the flags is intended
    gcc -c osdemo/osmesa_mt_test.c -o /tmp/pctest.o $(pkg-config --cflags osmesa)
    # shellcheck disable=SC2046
    g++ /tmp/pctest.o -o /tmp/pctest $(pkg-config --static --libs osmesa) -lpthread
    /tmp/pctest 8 20 2
    ;;
*)
    echo "Error: unknown stage $stage" >&2; exit 1;;
esac
