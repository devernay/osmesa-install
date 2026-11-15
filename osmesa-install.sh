#!/bin/bash

# environment variables used by this script:
# - OSMESA_PREFIX: where to install osmesa (must be writable)
# - LLVM_PREFIX: where llvm is / should be installed
# - LLVM_BUILD: whether to build LLVM (0/1/auto, auto by default: use the LLVM in LLVM_PREFIX if it
#   is suitable for this Mesa version, build it if there is no LLVM in LLVM_PREFIX, and stop with an
#   error if there is an unsuitable one, which is only replaced with LLVM_BUILD=1)
# - LLVM_SYSTEM: with LLVM_BUILD=auto, if LLVM_PREFIX has no suitable LLVM, use the newest suitable
#   LLVM installed by MacPorts, Homebrew, or the system (0/1, 0 by default). LLVM is still linked
#   statically, but the result depends on that LLVM's dependencies (e.g. libzstd, libxml2) and
#   minimum macOS version, so it is not suitable for redistribution.
# - OSMESA_VERSION: Mesa version (18.3.6 by default; 25.0.7, the last Mesa with OSMesa, uses meson)
# - SILENT_LOG: redirect output and error to log file (0/1, 0 by default)
# - BUILD_OSDEMO: try to compile and run osdemo (0/1, 1 by default)
# - MANGLED: build a mangled OSMesa and GLU (function names are prefixed with "m") (0/1, 1 by default)
# - SHARED: build shared OSMesa libraries (0/1, 0 by default)
# - INTERACTIVE: show the build options and ask for confirmation before building (0/1, 0 by default)

set -e # Exit immediately if a command exits with a non-zero status
set -u # Treat unset variables as an error when substituting.
#set -x # Print commands and their arguments as they are executed.

# prefix to the osmesa installation
osmesaprefix="${OSMESA_PREFIX:-/opt/osmesa}"
# mesa version
mesaversion="${OSMESA_VERSION:-18.3.6}"
# mesa-demos version
demoversion=8.4.0
# glu version
gluversion=9.0.1 # 9.0.2 doesn't support mangled GL, but supports building with meson
# set debug to 1 to compile a version with debugging symbols
debug=${DEBUG:-0}
# set clean to 1 to clean the source directories first (recommended)
clean=1
# number of parallel make jobs, set to 4 by default
mkjobs="${MKJOBS:-4}"
# set osmesadriver to:
# - 1 to use "classic" osmesa resterizer instead of the Gallium driver
# - 2 to use the "softpipe" Gallium driver
# - 3 to use the "llvmpipe" Gallium driver (also includes the softpipe driver, which can
#     be selected at run-time by setting en var GALLIUM_DRIVER to "softpipe")
# - 4 to use the "swr" Gallium driver (also includes the softpipe driver, which can
#     be selected at run-time by setting en var GALLIUM_DRIVER to "softpipe")
osmesadriver=${OSMESA_DRIVER:-4}
# do we want a mangled mesa + GLU ?
mangled="${MANGLED:-1}"
# do we want to build shared libs?
shared="${SHARED:-0}"
# the prefix to the LLVM installation
llvmprefix="${LLVM_PREFIX:-/opt/llvm}"
# do we want to build the proper LLVM static libraries too? or are they already installed ?
buildllvm="${LLVM_BUILD:-auto}"
# Mesa 19 and later (meson build) need LLVM 15 or later, Mesa 18 and earlier need LLVM 14 or earlier
if [ "${mesaversion%%.*}" -ge 19 ]; then
    # LLVM 19 is the version used by Mesa 25.0's CI (LLVM 15.0.7 to 23.1.4 were tested here)
    llvmversion="${LLVM_VERSION:-19.1.7}"
else
    llvmversion="${LLVM_VERSION:-6.0.1}"
fi
# Mesa versions where OSMesa is built with meson
mesonbuild=0
if [ "${mesaversion%%.*}" -ge 19 ]; then
    mesonbuild=1
fi
# redirect output and error to log file; exit script on error.
silentlogging="${SILENT_LOG:-0}"
buildosmesa="${BUILD_OSMESA:-1}"
buildglu="${BUILD_GLU:-1}"
buildosdemo="${BUILD_OSDEMO:-1}"
interactive="${INTERACTIVE:-0}"
osname=$(uname)
# This script
scriptdir=$(cd "$(dirname "$0")"; pwd)
# scriptname is the script name without the suffix (if any)
scriptname=$(basename "$0")
scriptname="${scriptname%.*}"
# Sources are downloaded and built in the current directory: don't do that in the script directory.
if [ "$(pwd)" = "$scriptdir" ]; then
    echo "Error: do not run this script from its own directory. Create a build directory and run it from there:"
    echo "  mkdir build && cd build && bash ../$(basename "$0")"
    exit 1
fi
if [ "$silentlogging" = 1 ]; then
    # Don't overwrite the log of a previous run: use osmesa-install.log, then osmesa-install_1.log, etc.
    logfile="$scriptdir/$scriptname.log"
    i=1
    while [ -e "$logfile" ]; do
        logfile="$scriptdir/${scriptname}_$i.log"
        i=$((i + 1))
    done
    echo "Output is redirected to $logfile"
    if [ "$interactive" = 1 ]; then
        echo "Note: INTERACTIVE is ignored with SILENT_LOG=1"
        interactive=0
    fi
    # Exit script on error, redirect output and error to log file. Open log for realtime updates.
    set -e
    exec </dev/null &>"$logfile"
fi

if [ "$debug" = 1 ]; then
    CFLAGS="${CFLAGS:--g}"
else
    CFLAGS="${CFLAGS:--O3}"
fi
CXXFLAGS="${CXXFLAGS:-${CFLAGS}}"

if [ -z "${CC:-}" ]; then
    CC=gcc
fi
if [ -z "${CXX:-}" ]; then
    CXX=g++
fi

if [ "$osname" = Darwin ]; then
    osver=$(uname -r | awk -F . '{print $1}')
    # Possible $osver values:
    # 9: Mac OS X 10.5 Leopard
    # 10: Mac OS X 10.6 Snow Leopard
    # 11: Mac OS X 10.7 Lion
    # 12: OS X 10.8 Mountain Lion
    # 13: OS X 10.9 Mavericks
    # 14: OS X 10.10 Yosemite
    # 15: OS X 10.11 El Capitan
    # 16: macOS 10.12 Sierra
    # 17: macOS 10.13 High Sierra
    # 18: macOS 10.14 Mojave
    # 19: macOS 10.15 Catalina
    # 20: macOS 11 Big Sur
    # 21: macOS 12 Monterey
    # 22: macOS 13 Ventura
    # 23: macOS 14 Sonoma
    
    if [ "$osver" = 10 ]; then
        # On Snow Leopard (10.6), build universal
        archs="-arch i386 -arch x86_64"
        CFLAGS="$CFLAGS $archs"
        CXXFLAGS="$CXXFLAGS $archs"
    fi
    XCODE_VER=$(xcodebuild -version 2>/dev/null | sed -e 's/Xcode //' | head -n 1)
    case "$XCODE_VER" in
        4.2*|[5-9].*|[1-9][0-9].*)
            # clang became the default compiler on Xcode 4.2
            CC=clang
            CXX=clang++
            ;;
    esac

    # Note: the macOS deployment target (used eg for option -mmacosx-version-min=10.<X>) is set
    # in the script from the MACOSX_DEPLOYMENT_TARGET environment variable.
    # To set it from the command-line, use e.g. "env MACOSX_DEPLOYMENT_TARGET=10.8 ../osmesa-install.sh"

    # Similarly, the SDK root can be set using the SDKROOT environment variable, as in
    # "env MACOSX_DEPLOYMENT_TARGET=10.8 SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.12.sdk ../osmesa-install.sh"

    if [ "$osmesadriver" = 4 ]; then
        #     "swr" (aka OpenSWR) is not supported on macOS,
        #     https://github.com/OpenSWR/openswr/issues/2
        #     https://github.com/OpenSWR/openswr-mesa/issues/11
        osmesadriver=3
    fi
    # We want at least Xcode 9 (LLVM 4, macOS 10.12) to compile LLVM 4 or 6.
    # On anything older than macOS 10.12, let us require a stable version of MacPorts clang.
    if [ "$osver" -lt 16 ]; then
        # On Snow Leopard, libc++ is installed by MacPorts (see https://trac.macports.org/wiki/LibcxxOnOlderSystems)
        if [[ $(type -P clang-mp-9.0) ]]; then
            CC=clang-mp-9.0
            CXX=clang++-mp-9.0
            OSDEMO_LD="clang++-mp-9.0 -stdlib=libc++"
        else
            echo "Error: Please install MacPorts and clang 9 using the following command:"
            echo "sudo port install clang-9.0"
        fi
    fi
fi

# On macOS 10.12 and later, if no SDK was given, use the default SDK reported by xcrun, so that the
# SDK used for the build is explicit and is shown in the options below.
if [ "$osname" = Darwin ] && [ "$osver" -ge 16 ] && [ -z "${SDKROOT:-}" ]; then
    SDKROOT=$(xcrun --show-sdk-path 2>/dev/null || true)
    if [ -n "$SDKROOT" ]; then
        export SDKROOT
    else
        unset SDKROOT
    fi
fi

if [ "${mesaversion%%.*}" -ge 21 ] && [ "$osmesadriver" = 1 ]; then
    echo "Error: the classic osmesa (swrast) driver was removed in Mesa 21.0, use OSMESA_DRIVER=2 (softpipe) or 3 (llvmpipe)"
    exit 1
fi
if [ "${mesaversion%%.*}" -ge 22 ] && [ "$osmesadriver" = 4 ]; then
    # the swr driver was removed in Mesa 22.0, use llvmpipe (which also includes softpipe)
    osmesadriver=3
fi

# tell curl to continue downloads and follow redirects
# -f: fail on HTTP errors (e.g. 404) instead of saving the error page, so the "||" fallbacks work
curlopts="-f -L -C -"
srcdir="$scriptdir"

echo "Mesa buid options:"
if [ "$debug" = 1 ]; then
    echo "- debug"
else
    echo "- release, non-debug"
fi
if [ "$mangled" = 1 ]; then
    echo "- mangled (all function names start with mgl instead of gl)"
else
    echo "- non-mangled"
fi

if [ "$osmesadriver" = 1 ]; then
    echo "- classic osmesa software renderer"
elif [ "$osmesadriver" = 2 ]; then
    echo "- softpipe Gallium renderer"
elif [ "$osmesadriver" = 3 ]; then
    echo "- llvmpipe Gallium renderer"
    if [ "$buildllvm" = 1 ]; then
        echo "- also build and install LLVM $llvmversion in $llvmprefix"
    fi
elif [ "$osmesadriver" = 4 ]; then
    echo "- swr Gallium renderer"
    if [ "$buildllvm" = 1 ]; then
        echo "- also build and install LLVM $llvmversion in $llvmprefix"
    fi
else
    echo "Error: osmesadriver must be 1, 2, 3 or 4"
    exit 1
fi
if [ "$clean" = 1 ]; then
    echo "- clean sources"
fi

if [ -n "${MACOSX_DEPLOYMENT_TARGET+x}" ]; then
    echo "- compile for deployment on macOS $MACOSX_DEPLOYMENT_TARGET (mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET)"
fi
if [ -n "${SDKROOT+x}" ]; then
    echo "- OSX SDK root is $SDKROOT"
fi
# tool versions, useful when reading a build log
echo "- CC: $CC ($($CC --version 2>/dev/null | head -n 1 || true))"
echo "- CXX: $CXX ($($CXX --version 2>/dev/null | head -n 1 || true))"
for tool in cmake autoconf automake python scons; do
    if [ -n "$(type -P $tool)" ]; then
        echo "- $tool: $($tool --version 2>&1 | head -n 1 || true)"
    fi
done

if [ "$interactive" = 1 ]; then
    read -r -p "Continue with these options? [Y/n] " answer || answer=n
    case "$answer" in
        n*|N*)
            echo "Exiting."
            exit 0
            ;;
    esac
fi

# elapsed time per stage (SECONDS is the number of seconds since the script started)
function print_elapsed() {
    local seconds=$((SECONDS - $2))
    echo "* $1 took $((seconds / 60))min $((seconds % 60))s"
}

# see https://stackoverflow.com/a/24067243
sort=sort
if [ "$osname" = Darwin ] && [ "$osver" -le 10 ]; then
    sort=gsort
fi
function version_gt() {
    test "$(printf '%s\n' "$@" | $sort -V | head -n 1)" != "$1";
}

# On MacPorts, building Mesa requires the following packages:
# sudo port install xorg-glproto xorg-libXext xorg-libXdamage xorg-libXfixes xorg-libxcb

# On macOS, Mesa's configure is run with SED=gsed (GNU sed), check for it early (before building LLVM)
if [ "$osname" = Darwin ] && [ "$buildosmesa" = 1 ] && [ "$mesonbuild" = 0 ] && [ -z "$(type -P gsed)" ]; then
    echo "Error: GNU sed (gsed) is required to build Mesa on macOS."
    echo "Install it with \"sudo port install gsed\" (MacPorts) or \"brew install gnu-sed\" (Homebrew)."
    exit 1
fi

# Meson builds (Mesa 19 and later) need meson, ninja, and python3 with the mako and yaml modules
pythonbin="${PYTHON:-$(type -P python3 || true)}"
if [ "$buildosmesa" = 1 ] && [ "$mesonbuild" = 1 ]; then
    case "$osname" in
        Msys*|MSYS*|MINGW*)
            echo "Error: building Mesa $mesaversion (meson) on Windows is not supported yet"
            exit 1
            ;;
    esac
    for tool in meson ninja; do
        if [ -z "$(type -P $tool)" ]; then
            echo "Error: $tool is required to build Mesa $mesaversion (e.g. \"sudo port install meson ninja\" or \"brew install meson ninja\")"
            exit 1
        fi
    done
    if [ -z "$pythonbin" ] || ! "$pythonbin" -c "import mako, yaml, packaging" 2>/dev/null; then
        echo "Error: python3 with the mako, yaml and packaging modules is required to build Mesa $mesaversion."
        echo "Install them (e.g. \"python3 -m pip install mako pyyaml packaging\"), or set PYTHON to a python3 that has them."
        exit 1
    fi
fi

# llvm_problems LLVM_CONFIG: print why this LLVM can't be used to build this Mesa version, and return 1,
# or return 0 if it can be used.
function llvm_problems() {
    local cfg="$1"
    local v
    if [ ! -x "$cfg" ]; then
        echo "$cfg does not exist"
        return 1
    fi
    v=$("$cfg" --version)
    if [ "$mesonbuild" = 1 ]; then
        if version_gt 15.0.0 "$v"; then
            echo "LLVM $v is too old for Mesa $mesaversion (LLVM 15 or later is required)"
            return 1
        fi
    elif version_gt "$v" 14.99; then
        echo "LLVM $v is too new for Mesa $mesaversion (LLVM 15 and later don't work with Mesa 18 and earlier)"
        return 1
    fi
    if "$cfg" --help 2>&1 | grep -q has-rtti && [ "$("$cfg" --has-rtti)" != YES ]; then
        echo "LLVM $v in $("$cfg" --prefix) was built without RTTI"
        return 1
    fi
    if "$cfg" --help 2>&1 | grep -q link-static && ! "$cfg" --link-static --libs core >/dev/null 2>&1; then
        echo "LLVM $v in $("$cfg" --prefix) has no static libraries"
        return 1
    fi
    return 0
}

# find_system_llvm: print the llvm-config of the newest suitable LLVM installed by MacPorts, Homebrew or
# the system, and return 1 if there is none.
function find_system_llvm() {
    local cfg best= bestversion= minos
    for cfg in /opt/local/libexec/llvm-*/bin/llvm-config /opt/homebrew/opt/llvm*/bin/llvm-config \
               /usr/local/opt/llvm*/bin/llvm-config /usr/lib/llvm-*/bin/llvm-config \
               $(type -P llvm-config || true); do
        [ -x "$cfg" ] || continue
        llvm_problems "$cfg" >/dev/null || continue
        if [ "$osname" = Darwin ] && [ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
            # skip LLVMs built for a newer macOS than the deployment target
            minos=$(otool -l "$("$cfg" --libdir)/libLLVMSupport.a" 2>/dev/null | awk '/minos/ {print $2; exit}')
            if [ -n "$minos" ] && version_gt "$minos" "$MACOSX_DEPLOYMENT_TARGET"; then
                continue
            fi
        fi
        if [ -z "$best" ] || version_gt "$("$cfg" --version)" "$bestversion"; then
            best="$cfg"
            bestversion=$("$cfg" --version)
        fi
    done
    [ -n "$best" ] || return 1
    echo "$best"
}

# Linker flags to find the dependencies of the LLVM libraries (e.g. libzstd from MacPorts or Homebrew)
llvmdepldflags=

llvmlibs=
if [ ! -d "$osmesaprefix" ] || [ ! -w "$osmesaprefix" ]; then
    echo "Error: $osmesaprefix does not exist or is not user-writable, please create $osmesaprefix and make it user-writable"
    exit 1
fi
if [ "$osmesadriver" = 3 ] || [ "$osmesadriver" = 4 ]; then
    # see also https://wiki.qt.io/Cross_compiling_Mesa_for_Windows
    if [ "$buildllvm" = auto ]; then
        case "$osname" in
            Msys*|MSYS*|MINGW*) llvmconfigbinary="$llvmprefix/bin/llvm-config.exe";;
            *) llvmconfigbinary="$llvmprefix/bin/llvm-config";;
        esac
        if llvmproblem=$(llvm_problems "$llvmconfigbinary"); then
            if [ -n "${LLVM_VERSION:-}" ] && [ "$("$llvmconfigbinary" --version)" != "$LLVM_VERSION" ]; then
                echo "* LLVM $("$llvmconfigbinary" --version) in $llvmprefix is not the requested version $LLVM_VERSION: building LLVM $llvmversion"
                buildllvm=1
            else
                echo "* using LLVM $("$llvmconfigbinary" --version) from $llvmprefix"
                buildllvm=0
            fi
        elif [ "${LLVM_SYSTEM:-0}" = 1 ] && systemllvm=$(find_system_llvm); then
            llvmconfigbinary="$systemllvm"
            llvmprefix=$("$llvmconfigbinary" --prefix)
            buildllvm=0
            case "$llvmprefix" in
                /opt/local/*) llvmdepldflags="-L/opt/local/lib";;
                /opt/homebrew/*) llvmdepldflags="-L/opt/homebrew/lib";;
                /usr/local/*) llvmdepldflags="-L/usr/local/lib";;
            esac
            echo "* using the installed LLVM $("$llvmconfigbinary" --version) from $llvmprefix (LLVM_SYSTEM=1)"
            echo "  Warning: the result also depends on: $("$llvmconfigbinary" --link-static --system-libs)"
            echo "  It is not suitable for redistribution (use a LLVM built by this script for that)."
        elif [ -e "$llvmconfigbinary" ]; then
            # never overwrite an existing LLVM installation automatically (it may be used by other builds)
            echo "Error: $llvmproblem."
            echo "Give the prefix of another LLVM with LLVM_PREFIX, or a new prefix where LLVM $llvmversion will be built"
            echo "(e.g. env LLVM_PREFIX=/opt/llvm-$llvmversion ...), or use LLVM_BUILD=1 to replace the LLVM in $llvmprefix."
            exit 1
        else
            echo "* no LLVM in $llvmprefix: building LLVM $llvmversion there"
            buildllvm=1
        fi
    fi
    if [ "$buildllvm" = 1 ]; then
        if [ ! -d "$llvmprefix" ] || [ ! -w "$llvmprefix" ]; then
            echo "Error: $llvmprefix does not exist or is not user-writable, please create $llvmprefix and make it user-writable"
            exit 1
        fi
        # LLVM must be compiled with RRTI, see https://bugs.freedesktop.org/show_bug.cgi?id=90032
        llvmtopdir=$(pwd)
        # LLVM 15 and later can't be built from the llvm-X.src tarball alone (it needs the separate
        # cmake modules): use the llvm-project tarball.
        llvmproject=0
        if version_gt "$llvmversion" 14.99; then
            llvmproject=1
        fi
        if [ "$clean" = 1 ]; then
            rm -rf llvm-${llvmversion}.src llvm-project-${llvmversion}.src
        fi

        archsuffix=xz
        xzcat=xzcat
        if [ $llvmversion = 3.4.2 ]; then
            archsuffix=gz
            xzcat="gzip -dc"
        fi
        # From Yosemite (14) gunzip can decompress xz files - but only if containing a tar archive.
        #if [ "$osname" = Darwin ] && [ "$osver" -ge 14 ]; then
        #    xzcat="gzip -dc"
        #fi
        if [ "$llvmproject" = 1 ]; then
            if [ ! -f llvm-project-${llvmversion}.src.tar.xz ]; then
                echo "* downloading LLVM ${llvmversion}..."
                curl $curlopts -O "https://github.com/llvm/llvm-project/releases/download/llvmorg-${llvmversion}/llvm-project-${llvmversion}.src.tar.xz"
            fi
        elif [ ! -f llvm-${llvmversion}.src.tar.$archsuffix ]; then
            echo "* downloading LLVM ${llvmversion}..."
            if version_gt "${llvmversion}" 7.0.0; then
                curl $curlopts -O "https://github.com/llvm/llvm-project/releases/download/llvmorg-${llvmversion}/llvm-${llvmversion}.src.tar.$archsuffix"
            else
                # the llvm we server doesnt' allow continuing partial downloads
                curl $curlopts -O "http://www.llvm.org/releases/${llvmversion}/llvm-${llvmversion}.src.tar.$archsuffix"
            fi
        fi
        if [ "$llvmproject" = 1 ]; then
            $xzcat llvm-project-${llvmversion}.src.tar.xz | tar xf -
            cd llvm-project-${llvmversion}.src/llvm
        else
            $xzcat llvm-${llvmversion}.src.tar.$archsuffix | tar xf -
            cd llvm-${llvmversion}.src
        fi
        echo "* building LLVM..."
        llvmstart=$SECONDS
        cmake_archflags=
        if [ $llvmversion = 3.4.2 ] && [ "$osname" = Darwin ] && [ "$osver" = 10 ]; then
            if [ "$debug" = 1 ]; then
                debugopts="--disable-optimized --enable-debug-symbols --enable-debug-runtime --enable-assertions"
            else
                debugopts="--enable-optimized --disable-debug-symbols --disable-debug-runtime --disable-assertions"
            fi
            # On Snow Leopard, build universal
            # and use configure (as macports does)
            # workaround a bug in Apple's shipped gcc driver-driver
            if [ "$CXX" = "g++" ]; then
                echo "static int ___ignoreme;" > tools/llvm-shlib/ignore.c
            fi
            env CC="$CC" CXX="$CXX" REQUIRES_RTTI=1 UNIVERSAL=1 UNIVERSAL_ARCH="i386 x86_64" ./configure --prefix="$llvmprefix" \
                --enable-bindings=none --disable-libffi --disable-shared --enable-static --enable-jit --enable-pic \
                --enable-targets=host --disable-profiling \
                --disable-backtraces \
                --disable-terminfo \
                --disable-zlib \
                $debugopts
            env REQUIRES_RTTI=1 UNIVERSAL=1 UNIVERSAL_ARCH="i386 x86_64" make -j"${mkjobs}" install
            echo "* installing LLVM..."
            env REQUIRES_RTTI=1 UNIVERSAL=1 UNIVERSAL_ARCH="i386 x86_64" make install
        else
            cmakegen="Unix Makefiles" # can be "MSYS Makefiles" on MSYS
            cmake_archflags=""
	    # llvm 4.0.1 patches from:
	    # https://github.com/macports/macports-ports/tree/edc0cff9e8a3b28964a48ae2a4ceddb5e617d906/lang/llvm-4.0
	    # llvm 5.0.2 patches from:
	    # https://github.com/macports/macports-ports/tree/b34bfd6652fad3994effcb1f14486c8ab5431a3b/lang/llvm-5.0
	    # ORC patch to fix building with GCC 8.x, see:
	    # https://bugzilla.redhat.com/show_bug.cgi?id=1540620
        # llvm 6.0.1 patches from:
        # https://github.com/macports/macports-ports/tree/b3959e9bbcef4d6b7adffe779ec116dd832972a9/lang/llvm-6.0
        # + update config.guess to guess aarch64 on M1 Macs
        # llvm 9.0.1 patches from:
        # https://github.com/macports/macports-ports/tree/b3959e9bbcef4d6b7adffe779ec116dd832972a9/lang/llvm-9.0
            llvm_patches="\
	    0001-Fix-return-type-in-ORC-readMem-client-interface.patch \
	    0001-Set-the-Mach-O-CPU-Subtype-to-ppc7400-when-targeting.patch \
	    0002-Define-EXC_MASK_CRASH-and-MACH_EXCEPTION_CODES-if-th.patch \
	    0003-MacPorts-Only-Don-t-embed-the-deployment-target-in-t.patch \
	    0004-Fix-build-issues-pre-Lion-due-to-missing-a-strnlen-d.patch \
	    0005-Dont-build-LibFuzzer-pre-Lion-due-to-missing-__threa.patch \
	    0005-Threading-Only-call-pthread_setname_np-on-SnowLeopar.patch \
        0006-Only-call-setpriority-PRIO_DARWIN_THREAD-0-PRIO_DARW.patch \
        config-guess.patch \
        regex_impl-include-guard.patch \
        sancov-explicit-string.patch \
	    "
            if [ "$osname" = Darwin ] && [ "$osver" = 10 ]; then
                # On Snow Leopard, build universal
                cmake_archflags="$cmake_archflags -DCMAKE_OSX_ARCHITECTURES=i386;x86_64"
                # Proxy for eliminating the dependency on native TLS
                # http://trac.macports.org/ticket/46887
                #cmake_archflags="$cmake_archflags -DLLVM_ENABLE_BACKTRACES=OFF" # flag was added to the common flags below, we don't need backtraces anyway

                # https://llvm.org/bugs/show_bug.cgi?id=25680
                #configure.cxxflags-append -U__STRICT_ANSI__
            fi

            if [ "$osname" = Darwin ]; then
                # Redundant - provided for older compilers that do not pass this option to the linker
                # Address xcode/cmake error: compiler appears to require libatomic, but cannot find it.
                cmake_archflags="$cmake_archflags -DLLVM_ENABLE_LIBCXX=ON"
                if [ "$osver" -ge 12 ]; then
                    # From Mountain Lion onward. We are only building 64bit arch.
                    cmake_archflags="$cmake_archflags -DCMAKE_OSX_ARCHITECTURES=$(uname -m)"
                fi
                # https://cmake.org/cmake/help/v3.0/variable/CMAKE_OSX_DEPLOYMENT_TARGET.html
                if [ -n "${MACOSX_DEPLOYMENT_TARGET+x}" ]; then
                    cmake_archflags="$cmake_archflags -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
                fi
                # https://cmake.org/cmake/help/v3.0/variable/CMAKE_OSX_SYSROOT.html
                if [ -n "${SDKROOT+x}" ]; then
                    cmake_archflags="$cmake_archflags -DCMAKE_OSX_SYSROOT=$SDKROOT"
                fi
            fi

            case "$osname" in
                 Msys*|MSYS*|MINGW*)
                     cmakegen="MSYS Makefiles"
                     #cmake_archflags="-DLLVM_ENABLE_CXX1Y=ON" # is that really what we want???????
                     cmake_archflags="-DLLVM_USE_CRT_DEBUG=MTd -DLLVM_USE_CRT_RELEASE=MT"
                     llvm_patches="msys2_add_pi.patch"
                     ;;
            esac

            for i in $llvm_patches; do
                if [ -f "$srcdir"/patches/llvm-$llvmversion/$i ]; then
                    echo "* applying patch $i"
                    patch -p1 -d . < "$srcdir"/patches/llvm-$llvmversion/$i
                fi
            done
            llvm_new_cmake_flags=
            if [ "$llvmproject" = 1 ]; then
                # only build the libraries (and llvm-config), without optional dependencies,
                # so that programs linking LLVM statically only depend on system libraries
                llvm_new_cmake_flags="-DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_BUILD_TOOLS=OFF"
            fi
            mkdir build
            cd build
            if [ "$debug" = 1 ]; then
                debugopts="-DCMAKE_BUILD_TYPE=Debug -DLLVM_ENABLE_ASSERTIONS=ON -DLLVM_INCLUDE_TESTS=ON -DLLVM_INCLUDE_EXAMPLES=ON"
            else
                debugopts="-DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF"
            fi

            env CC="$CC" CXX="$CXX" REQUIRES_RTTI=1 cmake -G "$cmakegen" .. -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_INSTALL_PREFIX="${llvmprefix}" \
                -DLLVM_TARGETS_TO_BUILD="host" \
                -DLLVM_ENABLE_RTTI=ON \
                -DLLVM_REQUIRES_RTTI=ON \
                -DBUILD_SHARED_LIBS=OFF \
                -DBUILD_STATIC_LIBS=ON \
                -DLLVM_ENABLE_FFI=OFF \
                -DLLVM_BINDINGS_LIST=none \
                -DLLVM_ENABLE_PEDANTIC=OFF \
                -DLLVM_INCLUDE_TESTS=OFF \
                -DLLVM_ENABLE_BACKTRACES=OFF \
                -DLLVM_ENABLE_TERMINFO=OFF \
                -DLLVM_ENABLE_ZLIB=OFF \
                $llvm_new_cmake_flags \
                $debugopts $cmake_archflags
            env REQUIRES_RTTI=1 make -j"${mkjobs}"
            echo "* installing LLVM..."
            env REQUIRES_RTTI=1 make install
            if [ "$llvmproject" = 1 ]; then
                # tools are not built (LLVM_BUILD_TOOLS=OFF), except llvm-config, which Mesa needs
                env REQUIRES_RTTI=1 make -j"${mkjobs}" llvm-config
                mkdir -p "$llvmprefix/bin"
                cp bin/llvm-config "$llvmprefix/bin/"
            fi
            cd ..
        fi
        cd "$llvmtopdir"
        print_elapsed "LLVM build" $llvmstart
    fi
    llvmconfigbinary=
    case "$osname" in
        Msys*|MSYS*|MINGW*)
            llvmconfigbinary="$llvmprefix/bin/llvm-config.exe"
            ;;
        *)
            llvmconfigbinary="$llvmprefix/bin/llvm-config"
            ;;
    esac
    # Check if llvm installed
    if [ ! -x "$llvmconfigbinary" ]; then
        # could not find installation.
        if [ "$buildllvm" = 0 ]; then
            # advise user to turn on automatic download, build and install option
            echo "Error: $llvmconfigbinary does not exist, set environment variable LLVM_BUILD to 1 to automatically download and install llvm, as in:"
            echo "  env LLVM_BUILD=1 $0"
            echo "Or alternatively give the path to an existing LLVM installation as in:"
            echo "  env LLVM_PREFIX=/opt/local/libexec/llvm-6.0 $0"
        else
            echo "Error: $llvmconfigbinary does not exist, please install LLVM with RTTI support in $llvmprefix"
            echo " download the LLVM sources from llvm.org, and configure it with:"
            echo " env CC=$CC CXX=$CXX cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$llvmprefix -DBUILD_SHARED_LIBS=OFF -DLLVM_ENABLE_RTTI=1 -DLLVM_REQUIRES_RTTI=1 -DLLVM_ENABLE_PEDANTIC=0 $cmake_archflags"
            echo " env REQUIRES_RTTI=1 make -j${mkjobs}"
        fi
        exit 1
    elif [ "$mesonbuild" = 1 ]; then
        if ! llvmproblem=$(llvm_problems "$llvmconfigbinary"); then
            echo "Error: $llvmproblem"
            echo "Build a suitable LLVM with LLVM_BUILD=1 (LLVM $llvmversion), or give another LLVM_PREFIX."
            exit 1
        fi
        if version_gt "$("$llvmconfigbinary" --version)" 23.1.4; then
            echo "Warning: LLVM $("$llvmconfigbinary" --version) is newer than the versions tested with Mesa $mesaversion (15.0.7 to 23.1.4)."
        fi
    else
	if version_gt $("$llvmconfigbinary" --version) 6.0.1; then
	    echo "Warning: LLVM version is $($llvmconfigbinary --version), but this script was only tested with versions 3.3 to 6.0.1"
	    echo "LLVM 4.0.1 is the best option for Mesa 17.x."
        echo "LLVM 6.0.1 works with Mesa 18.x."
        echo "LLVM 9.0.1 hangs on osdemo16, at least up to Mesa 18.2.8, but may work with Mesa 18.3.6 and later."
        echo "LLVM 15 and greater will NOT work, because of:"
        echo " - https://discourse.llvm.org/t/rfc-remove-most-constant-expressions/63179/11 (LLVM 15)"
        echo " - https://llvm.org/docs/OpaquePointers.html#frontends (LLVM 16)"
	    echo "Please modify this script and file a github issue if it works with this version."
        if version_gt $("$llvmconfigbinary" --version) 14.99; then
            exit 1
        fi
	    echo "Continuing anyway after 10s."
	    sleep 10
	fi
    fi
    llvmcomponents="engine mcjit"
    case "$(uname -m)" in
    i386*|x86*)
        llvmcomponents="$llvmcomponents x86codegen x86disassembler"
        ;;
    arm64*|aarch64*)
        llvmcomponents="$llvmcomponents aarch64codegen aarch64disassembler"
        ;;
    ppc*|powerpc*)
        llvmcomponents="$llvmcomponents powerpccodegen powerpcdisassembler"
        ;;
    esac
    if [ "$debug" = 1 ]; then
        llvmcomponents="$llvmcomponents mcdisassembler"
    fi
    if [ "$mesonbuild" = 1 ]; then
        # the LLVM components used by Mesa's llvmpipe (see llvm_modules in Mesa's meson.build)
        llvmcomponents="bitwriter engine mcdisassembler mcjit core executionengine scalaropts transformutils instcombine coroutines native passes"
        llvmlibs=$("${llvmconfigbinary}" --link-static --ldflags --libs $llvmcomponents)
        llvmlibsadd="$llvmdepldflags $("${llvmconfigbinary}" --link-static --system-libs)"
    else
    llvmlibs=$("${llvmconfigbinary}" --ldflags --libs $llvmcomponents)
    if "${llvmconfigbinary}" --help 2>&1 | grep -q system-libs; then
        llvmlibsadd=$("${llvmconfigbinary}" --system-libs)
    else
        # on old llvm, system libs are in the ldflags
        llvmlibsadd=$("${llvmconfigbinary}" --ldflags)
    fi
    fi
    llvmlibs="$llvmlibs $llvmlibsadd"
fi

# Mesa/LLVM compatibility checks (llvmconfigbinary is only set for the llvmpipe/swr drivers)
if [ -n "${llvmconfigbinary:-}" ]; then
if version_gt $("$llvmconfigbinary" --version) 4.0.1 && version_gt 18.0.0 "$mesaversion"; then
    echo "Building for an unsupported combination of Mesa/LLVM."
    echo "LLVM 4.0.1 is the best option for Mesa 17.x."
    echo "Continuing anyway after 10s."
    sleep 10
fi

if version_gt $("$llvmconfigbinary" --version) 6.0.1 && version_gt 19.0.0 "$mesaversion"; then
    echo "Building for an unsupported combination of Mesa/LLVM."
    echo "LLVM 6.0.1 is the best option for Mesa 18.x."
    echo "LLVM 9.0.1 and later hang when running osdemo16 with Mesa up to 18.1.8."
    echo "LLVM 15 and greater will NOT work, because of:"
    echo " - https://discourse.llvm.org/t/rfc-remove-most-constant-expressions/63179/11 (LLVM 15)"
    echo " - https://llvm.org/docs/OpaquePointers.html#frontends (LLVM 16)"
    echo "Please modify this script and file a github issue if it works with this version."
    if version_gt $("$llvmconfigbinary" --version) 14.99; then
        exit 1
    fi
    echo "Continuing anyway after 10s."
    sleep 10
fi
fi # llvmconfigbinary

if [ "$clean" = 1 ]; then
    rm -rf "mesa-$mesaversion" "mesa-demos-$demoversion" "glu-$gluversion"
fi

if [ "$buildosmesa" = 1 ]; then
osmesastart=$SECONDS

archsuffix=xz
xzcat=xzcat
if [ ! -f "mesa-${mesaversion}.tar.${archsuffix}" ]; then
    echo "* downloading Mesa ${mesaversion}..."
    # ftp.freedesktop.org refuses connections (as of 2026): try archive.mesa3d.org (HTTPS) first,
    # where releases are at the root (23.x and later), in older-versions/X.x/ (14.x to 22.x),
    # or in older-versions/X.x/X.Y.Z/ (13.x and earlier)
    mesaurlroot="https://archive.mesa3d.org/mesa-${mesaversion}.tar.${archsuffix}"
    mesaurlolder="https://archive.mesa3d.org/older-versions/${mesaversion/.*/.x}/mesa-${mesaversion}.tar.${archsuffix}"
    if [ "${mesaversion%%.*}" -ge 23 ]; then
        mesaurl1="$mesaurlroot"
        mesaurl2="$mesaurlolder"
    else
        mesaurl1="$mesaurlolder"
        mesaurl2="$mesaurlroot"
    fi
    curl $curlopts -O "$mesaurl1" \
    || curl $curlopts -O "$mesaurl2" \
    || curl $curlopts -O "https://archive.mesa3d.org/older-versions/${mesaversion/.*/.x}/${mesaversion}/mesa-${mesaversion}.tar.${archsuffix}" \
    || curl $curlopts -O "ftp://ftp.freedesktop.org/pub/mesa/mesa-${mesaversion}.tar.${archsuffix}" \
    || curl $curlopts -O "ftp://ftp.freedesktop.org/pub/mesa/older-versions/${mesaversion/.*/.x}/mesa-${mesaversion}.tar.${archsuffix}" \
    || curl $curlopts -O "ftp://ftp.freedesktop.org/pub/mesa/older-versions/${mesaversion/.*/.x}/${mesaversion}/mesa-${mesaversion}.tar.${archsuffix}"    
fi
$xzcat "mesa-${mesaversion}.tar.${archsuffix}" | tar xf -

# apply patches from MacPorts

echo "* applying patches..."

#add_pi.patch still valid with Mesa 17.0.3
#gallium-once-flag.patch only for Mesa < 12.0.1
#gallium-osmesa-threadsafe.patch still valid with Mesa 17.0.3
#glapi-getproc-mangled.patch only for Mesa < 11.2.2
#install-GL-headers.patch still valid with Mesa 17.0.3
#lp_scene-safe.patch still valid with Mesa 17.0.3
#mesa-glversion-override.patch
#osmesa-gallium-driver.patch still valid with Mesa 17.0.3
#redefinition-of-typedef-nirshader.patch only for Mesa 12.0.x
#scons25.patch only for Mesa < 12.0.1
#scons-llvm-3-9-libs.patch still valid with Mesa 17.0.3
#swr-sched.patch still valid with Mesa 17.0.3
#disable_shader_cache.patch still valid with Mesa 17.1.6 and should be applied on Mavericks and earlier (may be fixed later, check https://trac.macports.org/ticket/54638#comment:8)
#osmesa-gl-DispatchTSD.patch still valid with Mesa 17.1.10
#osmesa-configure-ac.patch still valid with Mesa 17.1.10

PATCHES="\
add_pi.patch \
gallium-once-flag.patch \
gallium-osmesa-threadsafe.patch \
glapi-getproc-mangled.patch \
install-GL-headers.patch \
lp_scene-safe.patch \
mesa-glversion-override.patch \
osmesa-gallium-driver.patch \
redefinition-of-typedef-nirshader.patch \
scons25.patch \
scons-llvm-3-9-libs.patch \
swr-sched.patch \
scons-swr-cc-arch.patch \
msys2_scons_fix.patch \
osmesa-gl-DispatchTSD.patch \
osmesa-configure-ac.patch \
gallivm_math_h.patch \
gallium_llvm.patch \
"

if [ "$osname" = Darwin ] && [ "$osver" -lt 14 ]; then
    # See https://trac.macports.org/ticket/54638
    # See https://trac.macports.org/ticket/54643
    PATCHES="$PATCHES disable_shader_cache.patch"
fi

#if mangled, add mgl_export (for mingw), and mgl-namespace (put back mangling support, for Mesa >= 19.2.2)
if [ "$mangled" = 1 ]; then
    PATCHES="$PATCHES mgl_export.patch mgl-namespace.patch"
fi

# mingw-specific patches (for maintainability, prefer putting everything in the main patch list)
mingw=0
case "$osname" in
    Msys*|MSYS*|MINGW*)
    mingw=1
    ;;
esac
if [ "$mingw" = 1 ]; then
    PATCHES="$PATCHES scons31-python39-001.patch scons31-python39-002.patch"
fi

if [ "$osname" = Darwin ]; then
    # patches for Mesa 12.0.1 from
    # https://github.com/macports/macports-ports/tree/master/x11/mesa/files
    PATCHES="$PATCHES \
    0001-mesa-Deal-with-size-differences-between-GLuint-and-G.patch \
    0002-applegl-Provide-requirements-of-_SET_DrawBuffers.patch \
    0002-Hack-to-address-build-failure-when-using-newer-macOS.patch \
    0003-glext.h-Add-missing-include-of-stddef.h-for-ptrdiff_.patch \
    5002-darwin-Suppress-type-conversion-warnings-for-GLhandl.patch \
    static-strndup.patch \
    no-missing-prototypes-error.patch \
    o-cloexec.patch \
    patch-include-GL-mesa_glinterop_h.diff \
    missing_clock_gettime.patch \
    "
    if [ "$mesonbuild" = 0 ]; then
        # Mesa's configure needs GNU sed (only for the autoconf build, GLU works with BSD sed)
        SED=gsed
        export SED
    fi
fi

for i in $PATCHES; do
    if [ -f "$srcdir/patches/mesa-$mesaversion/$i" ]; then
        echo "* applying patch $i"
        patch -p1 -d "mesa-${mesaversion}" < "$srcdir/patches/mesa-$mesaversion/$i"
    fi
done

cd "mesa-${mesaversion}"

if [ -f include/GL/gl_mangle.h ]; then
echo "* fixing gl_mangle.h..."
# edit include/GL/gl_mangle.h, add ../GLES*/gl[0-9]*.h to the "files" variable and change GLAPI in the grep line to GL_API
gles=
for h in GLES/gl.h GLES2/gl2.h GLES3/gl3.h GLES3/gl31.h GLES3/gl32.h; do
    if [ -f include/$h ]; then
        gles="$gles ../$h"
    fi
done
(cd include/GL; sed -e 's@gl.h glext.h@gl.h glext.h '"$gles"'@' -e 's@\^GLAPI@^GL_\\?API@' -i.orig gl_mangle.h)
(cd include/GL; sh ./gl_mangle.h > gl_mangle.h.new && mv gl_mangle.h.new gl_mangle.h)
elif [ "$mangled" = 1 ]; then
    # Mesa >= 19.2.2 doesn't have gl_mangle.h anymore: generate it from the GL and GLES headers
    if [ ! -f "$srcdir/patches/mesa-$mesaversion/gl_mangle.h.in" ]; then
        echo "Error: mangled GL is not supported with Mesa $mesaversion (missing patches/mesa-$mesaversion/gl_mangle.h.in)"
        exit 1
    fi
    echo "* generating gl_mangle.h..."
    (cd include/GL; sh "$srcdir/patches/mesa-$mesaversion/gl_mangle.h.in" > gl_mangle.h)
fi

echo "* fixing src/mapi/glapi/glapi_getproc.c..."
# functions in the dispatch table sre not stored with the mgl prefix
sed -i.bak -e 's/MANGLE/MANGLE_disabled/' src/mapi/glapi/glapi_getproc.c

echo "* building Mesa..."
use_scons=0
use_autoconf=0
use_meson=0

case "$osname" in
    Msys*|MSYS*|MINGW*)
        use_scons=1
        if [ "$mangled" = 1 ] && version_gt "$mesaversion" 19.2.1; then
            echo "Error: mangled GL support was dropped with Mesa 19.2.2"
            exit 1
        fi
        ;;
    *)
        if version_gt 19.0.0 "$mesaversion"; then
            use_autoconf=1
        else
            use_meson=1
        fi
        ;;
esac

if [ "$use_scons" = 1 ]; then
    ####################################################################
    # Windows build uses scons
    case "$osname" in
        MINGW64_NT-*)
            scons_machine="x86_64"
            ;;
        *)
            scons_machine="x86"
            ;;
    esac
    scons_cflags="$CFLAGS"
    scons_cxxflags="$CXXFLAGS -std=c++11"
    scons_ldflags="-s"
    if [ "$shared" = 0 ]; then
        scons_ldflags="-static $scons_ldflags"
    fi
    if [ "$mangled" = 1 ]; then
        scons_cflags="-DUSE_MGL_NAMESPACE"
    fi
    if [ "$debug" = 1 ]; then
        scons_build="debug"
    else
        scons_build="release"
    fi
    if [ "$osmesadriver" = 3 ] || [ "$osmesadriver" = 4 ]; then
        scons_llvm=yes
    else
        scons_llvm=no
    fi
    if [ "$osmesadriver" = 4 ]; then
        scons_swr=1
    else
        scons_swr=0
    fi
    mkdir -p "$osmesaprefix/include" "$osmesaprefix/lib/pkgconfig"
    env LLVM_CONFIG="$llvmconfigbinary" LLVM="$llvmprefix" CFLAGS="$scons_cflags" CXXFLAGS="$scons_cxxflags" LDFLAGS="$scons_ldflags" scons build="$scons_build" platform=windows toolchain=mingw machine="$scons_machine" texture_float=yes llvm="$scons_llvm" swr="$scons_swr" verbose=yes osmesa
    cp "build/windows-$scons_machine/gallium/targets/osmesa/osmesa.dll" "$osmesaprefix/lib/osmesa.dll"
    cp "build/windows-$scons_machine/gallium/targets/osmesa/libosmesa.a" "$osmesaprefix/lib/libMangledOSMesa32.a"
    cp -a "include/GL" "$osmesaprefix/include/" || exit 1
    cat <<EOF > "$osmesaprefix/lib/pkgconfig/osmesa.pc"
prefix=${osmesaprefix}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: osmesa
Description: Mesa Off-screen Rendering library
Requires:
Version: $mesaversion
Libs: -L\${libdir} -lMangledOSMesa32
Cflags: -I\${includedir}
EOF
    cp $osmesaprefix/lib/pkgconfig/osmesa.pc $osmesaprefix/lib/pkgconfig/gl.pc

    # end of SCons build
    ####################################################################
elif [ "$use_autoconf" = 1 ]; then
    ####################################################################
    # Unix builds for version up to 18 use configure

    # Mesa's configure (Mesa <= 18) uses $PYTHON if set. It works with Python 2, but rejects recent
    # Python 3 versions ("Python interpreter is too old" with Python 3.13). PYTHON is meant for the
    # meson build of newer Mesa versions, so ignore it here if it is not Python 2.
    if [ -n "${PYTHON:-}" ] && ! "$PYTHON" -c 'import sys; sys.exit(sys.version_info[0] != 2)' 2>/dev/null; then
        echo "* ignoring PYTHON=$PYTHON, which is not Python 2, for Mesa's configure"
        unset PYTHON
    fi

    test -f Makefile && make -j"${mkjobs}" distclean # if in an existing build

    autoupdate
    autoreconf -fi

    platformsopt="--with-platforms="
    llvmopt="llvm"
    omx="omx-bellagio"
    if version_gt 17.1.0 "$mesaversion"; then
        # configure: WARNING: --with-egl-platforms is deprecated. Use --with-platforms instead.
        platformsopt="--with-egl-platforms="
        # configure: WARNING: The --enable-gallium-llvm option has been deprecated. Use --enable-llvm instead.
        llvmopt="gallium-llvm"
    fi
    if version_gt 17.3.0 "$mesaversion"; then
        omx="omx"
    fi
    confopts="\
        --disable-dependency-tracking \
        --enable-texture-float \
        --disable-gles1 \
        --disable-gles2 \
        --disable-dri \
        --disable-dri3 \
        --disable-glx \
        --disable-glx-tls \
        --disable-egl \
        --disable-gbm \
        --disable-xvmc \
        --disable-vdpau \
        --disable-$omx \
        --disable-va \
        --disable-opencl \
        --disable-shared-glapi \
        --disable-driglx-direct \
        --with-dri-drivers= \
        --with-osmesa-bits=32 \
        $platformsopt \
        --prefix=$osmesaprefix \
        "
    if [ "$shared" = 1 ]; then
        confopts="$confopts --enable-shared --disable-static"
    else
        confopts="$confopts --disable-shared --enable-static"
    fi

    if [ "$osmesadriver" = 1 ]; then
        # pure osmesa (swrast) OpenGL 2.1, GLSL 1.20
        confopts="${confopts} \
                --enable-osmesa \
                --disable-gallium-osmesa \
                --disable-$llvmopt \
                --with-gallium-drivers= \
        "
    elif [ "$osmesadriver" = 2 ]; then
        # gallium osmesa (softpipe) OpenGL 3.0, GLSL 1.30
        confopts="${confopts} \
                --disable-osmesa \
                --enable-gallium-osmesa \
                --disable-$llvmopt \
                --with-gallium-drivers=swrast \
        "
    elif [ "$osmesadriver" = 3 ]; then
        # gallium osmesa (llvmpipe) OpenGL 3.0, GLSL 1.30
        confopts="${confopts} \
                --disable-osmesa \
                --enable-gallium-osmesa \
                --enable-$llvmopt=yes \
                --with-llvm-prefix=$llvmprefix \
                --disable-llvm-shared-libs \
                --with-gallium-drivers=swrast \
        "
    else
        # gallium osmesa (swr) OpenGL 3.0, GLSL 1.30
        confopts="${confopts} \
                --disable-osmesa \
                --enable-gallium-osmesa \
                --enable-$llvmopt=yes \
                --with-llvm-prefix=$llvmprefix \
                --disable-llvm-shared-libs \
                --with-gallium-drivers=swrast,swr \
        "
    fi

    if [ "$debug" = 1 ]; then
        confopts="${confopts} \
                --enable-debug"
    fi

    if [ "$mangled" = 1 ]; then
        confopts="${confopts} \
                --enable-mangling"
        #sed -i.bak -e 's/"gl"/"mgl"/' src/mapi/glapi/gen/remap_helper.py
        #rm src/mesa/main/remap_helper.h
    fi

    if [ "$osname" = Darwin ]; then
        osxflags=""
        if [ "$osver" -ge 12 ]; then
            # From Mountain Lion onward so we are only building 64bit arch.
            osxflags="$osxflags -arch $(uname -m)"
        fi
        if [ -n "${MACOSX_DEPLOYMENT_TARGET+x}" ]; then
            osxflags="$osxflags -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
        fi
        if [ -n "${SDKROOT+x}" ]; then
            osxflags="$osxflags -isysroot $SDKROOT"
        fi
        # clang >= 15 started treating int <-> ptr conversions as errors
        # (test the compiler itself: CC may be "gcc", which is clang with only the Command Line Tools)
        if $CC --version 2>/dev/null | grep -q clang; then
            osxflags="$osxflags -Wno-int-conversion"
        fi

        if [ -n "$osxflags" ]; then
            CFLAGS="$CFLAGS $osxflags"
            CXXFLAGS="$CXXFLAGS $osxflags"
        fi
    fi

    env CC="$CC" CXX="$CXX" PTHREADSTUBS_CFLAGS=" " PTHREADSTUBS_LIBS=" " ./configure ${confopts} CC="$CC" CFLAGS="$CFLAGS" CXX="$CXX" CXXFLAGS="$CXXFLAGS"

    make -j"${mkjobs}"

    echo "* installing Mesa..."
    make install

    if [ "$osname" = Darwin ] && [ "$shared" = 0 ]; then
        # fix the following error:
        #Undefined symbols for architecture x86_64:
        #  "_lp_dummy_tile", referenced from:
        #      _lp_rast_create in libMangledOSMesa32.a(lp_rast.o)
        #      _lp_setup_set_fragment_sampler_views in libMangledOSMesa32.a(lp_setup.o)
        #ld: symbol(s) not found for architecture x86_64
        #clang: error: linker command failed with exit code 1 (use -v to see invocation)
        for f in "$osmesaprefix/lib/"lib*.a; do
                ranlib -c "$f"
        done
    fi

    # End of configure-based build
    ####################################################################

elif [ "$use_meson" = 1 ]; then
    ####################################################################
    # Mesa 19 and later use meson
    if [ "$mangled" = 1 ]; then
        osmesalib=MangledOSMesa32
    else
        osmesalib=OSMesa32
    fi
    mesonopts="\
        --prefix=$osmesaprefix \
        -Dlibdir=lib \
        -Dosmesa=true \
        -Dplatforms= \
        -Dglx=disabled \
        -Degl=disabled \
        -Dgbm=disabled \
        -Dgles1=disabled \
        -Dgles2=disabled \
        -Dshared-glapi=disabled \
        -Dvulkan-drivers= \
        -Dvalgrind=disabled \
        -Dlibunwind=disabled \
        -Dzstd=disabled \
        -Dxmlconfig=disabled \
        -Dexpat=disabled"
    if [ "$debug" = 1 ]; then
        mesonopts="$mesonopts -Dbuildtype=debug"
    else
        mesonopts="$mesonopts -Dbuildtype=release"
    fi
    # the native file gives the python and llvm-config to use
    echo "[binaries]" > meson-native.ini
    echo "python = '$pythonbin'" >> meson-native.ini
    if [ "$osmesadriver" = 2 ]; then
        mesonopts="$mesonopts -Dgallium-drivers=softpipe -Dllvm=disabled"
    else
        # llvmpipe (also includes softpipe, which can be selected at run-time)
        mesonopts="$mesonopts -Dgallium-drivers=llvmpipe,softpipe -Dllvm=enabled -Dshared-llvm=disabled"
        echo "llvm-config = '$llvmconfigbinary'" >> meson-native.ini
    fi
    mesonflags=
    if [ "$mangled" = 1 ]; then
        mesonflags="-DUSE_MGL_NAMESPACE"
    fi
    if [ "$osname" = Darwin ]; then
        mesonflags="$mesonflags -arch $(uname -m)"
        if [ -n "${MACOSX_DEPLOYMENT_TARGET+x}" ]; then
            mesonflags="$mesonflags -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
        fi
        if [ -n "${SDKROOT+x}" ]; then
            mesonflags="$mesonflags -isysroot $SDKROOT"
        fi
    fi
    rm -rf build-meson
    env CC="$CC" CXX="$CXX" CFLAGS="$CFLAGS $mesonflags" CXXFLAGS="$CXXFLAGS $mesonflags" LDFLAGS="${LDFLAGS:-} $llvmdepldflags" \
        meson setup build-meson $mesonopts --native-file meson-native.ini
    ninja -C build-meson -j"${mkjobs}"
    echo "* installing Mesa..."
    ninja -C build-meson install

    # Mesa only builds OSMesa as a shared library, which links all of Mesa's internal static libraries.
    osmesatarget=$(ninja -C build-meson -t targets all | grep -E '^src/gallium/targets/osmesa/libOSMesa[^:/]*\.(dylib|so[.0-9]*): .*LINKER' | cut -d: -f1 | head -n 1)
    if [ -z "$osmesatarget" ]; then
        echo "Error: cannot find the OSMesa library target in build-meson"
        exit 1
    fi
    if [ "$shared" = 1 ]; then
        # the library is installed as libOSMesa: also make it available as lib$osmesalib
        for f in "$osmesaprefix/lib/"libOSMesa.*; do
            ln -sf "$(basename "$f")" "$osmesaprefix/lib/lib$osmesalib${f#$osmesaprefix/lib/libOSMesa}"
        done
    else
        # Build the static library lib$osmesalib.a from the objects and static libraries that are linked
        # into the shared library, and remove the shared library.
        echo "* creating static library lib$osmesalib.a..."
        osmesaobjs=
        for w in $(ninja -C build-meson -t commands "$osmesatarget" | tail -n 1); do
            case "$w" in
                /*) ;; # external libraries (LLVM, system)
                *.a|*.o)
                    if [ -f "build-meson/$w" ]; then
                        osmesaobjs="$osmesaobjs build-meson/$w"
                    fi
                    ;;
            esac
        done
        rm -f "$osmesaprefix/lib/lib$osmesalib.a"
        if [ "$osname" = Darwin ]; then
            # -c: include common symbols in the table of contents
            libtool -static -c -no_warning_for_no_symbols -o "$osmesaprefix/lib/lib$osmesalib.a" $osmesaobjs
        else
            {
                echo "create $osmesaprefix/lib/lib$osmesalib.a"
                for f in $osmesaobjs; do
                    case "$f" in
                        *.a) echo "addlib $f";;
                        *) echo "addmod $f";;
                    esac
                done
                echo "save"
                echo "end"
            } | ar -M
            ranlib "$osmesaprefix/lib/lib$osmesalib.a"
        fi
        rm -f "$osmesaprefix/lib/"libOSMesa.*dylib "$osmesaprefix/lib/"libOSMesa.so*
        # pkg-config file for the static library
        osmesalibsprivate="-lz -lpthread -lm"
        if [ "$osmesadriver" != 2 ]; then
            osmesalibsprivate="$llvmlibs $osmesalibsprivate"
        fi
        if [ "$osname" = Darwin ]; then
            osmesalibsprivate="$osmesalibsprivate -lc++"
        else
            osmesalibsprivate="$osmesalibsprivate -lstdc++"
        fi
        cat > "$osmesaprefix/lib/pkgconfig/osmesa.pc" <<EOF
prefix=$osmesaprefix
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: osmesa
Description: Mesa Off-screen Rendering Library (static)
Version: $mesaversion
Libs: -L\${libdir} -l$osmesalib
Libs.private: $(echo $osmesalibsprivate)
Cflags: -I\${includedir}
EOF
    fi
    # End of meson-based build
    ####################################################################
else
    echo "Error: cannot figure out build system"
    exit 1
fi

cd ..

print_elapsed "Mesa build" $osmesastart
fi # if [ "$buildosmesa" = 1 ];

if [ "$buildglu" = 1 ]; then
glustart=$SECONDS

if [ ! -f glu-${gluversion}.tar.gz ]; then
    echo "* downloading GLU ${gluversion}..."
    curl $curlopts -O "https://archive.mesa3d.org/glu/glu-${gluversion}.tar.gz" \
    || curl $curlopts -O "ftp://ftp.freedesktop.org/pub/mesa/glu/glu-${gluversion}.tar.gz"
fi
tar zxf glu-${gluversion}.tar.gz
cd glu-${gluversion}
if [ "$mangled" = 1 ] && ! grep -q gluDeleteNurbsTessellatorEXT include/GL/glu_mangle.h; then
    # glu_mangle.h misses gluDeleteNurbsTessellatorEXT, which would be exported unmangled
    sed -e '/#define gluNurbsCallbackDataEXT/a\
#define gluDeleteNurbsTessellatorEXT mgluDeleteNurbsTessellatorEXT
' include/GL/glu_mangle.h > include/GL/glu_mangle.h.new && mv include/GL/glu_mangle.h.new include/GL/glu_mangle.h
fi
echo "* building GLU..."
confopts="\
    --disable-dependency-tracking \
    --enable-osmesa \
    --prefix=$osmesaprefix"
if [ "$shared" = 1 ]; then
    confopts="${confopts} --disable-static --enable-shared"
else
    confopts="${confopts} --enable-static --disable-shared"
fi
if [ "$mangled" = 1 ]; then
    confopts="${confopts} \
     CPPFLAGS=-DUSE_MGL_NAMESPACE"
fi

env PKG_CONFIG_PATH="${osmesaprefix}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}" ./configure ${confopts} CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS"
make -j"${mkjobs}"

echo "* installing GLU..."
make install

if [ "$mangled" = 1 ]; then
    if [ "$shared" = 0 ]; then
        mv "$osmesaprefix/lib/libGLU.a" "$osmesaprefix/lib/libMangledGLU.a"
        mv "$osmesaprefix/lib/libGLU.la" "$osmesaprefix/lib/libMangledGLU.la"
        sed -e s/libGLU/libMangledGLU/g -i.bak "$osmesaprefix/lib/libMangledGLU.la"
        sed -e s/-lGLU/-lMangledGLU/g -i.bak "$osmesaprefix/lib/pkgconfig/glu.pc"
    fi
fi

print_elapsed "GLU build" $glustart
fi # if [ "$buildglu" = 1 ];

if [ "$buildosdemo" = 1 ]; then
osdemostart=$SECONDS
# build the demo
cd ..
if [ ! -f mesa-demos-${demoversion}.tar.bz2 ]; then
    echo "* downloading Mesa Demos ${demoversion}..."
    curl $curlopts -O "https://archive.mesa3d.org/demos/${demoversion}/mesa-demos-${demoversion}.tar.bz2" \
    || curl $curlopts -O "ftp://ftp.freedesktop.org/pub/mesa/demos/${demoversion}/mesa-demos-${demoversion}.tar.bz2" \
    || curl $curlopts -O "ftp://ftp.freedesktop.org/pub/mesa/demos/mesa-demos-${demoversion}.tar.bz2"
fi
tar jxf mesa-demos-${demoversion}.tar.bz2

cd mesa-demos-${demoversion}/src/osdemos
echo "* building Mesa Demo..."
# We need to include gl_mangle.h and glu_mangle.h, because osdemo32.c doesn't include them
# Fix a wrong declaration (mesa-demos 8.4.0)
sed -i.bak -e 's/void \*buffer/GLubyte *buffer/' -e 's/buffer = malloc/buffer = (GLubyte *)malloc/' osdemo.c
CFLAGS="$CFLAGS -fpermissive"
INCLUDES="-include $osmesaprefix/include/GL/gl.h -include $osmesaprefix/include/GL/glu.h"
if [ "$mangled" = 1 ]; then
    INCLUDES="-include $osmesaprefix/include/GL/gl_mangle.h -include $osmesaprefix/include/GL/glu_mangle.h $INCLUDES"
    LIBS32="-lMangledOSMesa32 -lMangledGLU"
else
    LIBS32="-lOSMesa32 -lGLU"
fi
if [ -z "${OSDEMO_LD:-}" ]; then
    OSDEMO_LD="$CXX"
fi
if [ "$osname" = Darwin ] || [ "$osname" = Linux ]; then
    # strange, got 'Undefined symbols for architecture x86_64' without zlib for both llvmpipe and softpipe drivers.
    # missing symbols are _deflate, _deflateEnd, _deflateInit_, _inflate, _inflateEnd and _inflateInit
    LIBS32="$LIBS32 -lz"
fi
if [ "$osname" = Darwin ] || [ "$osname" = Linux ]; then
    allowfail=false
else
    # build on windows may fail because osmesa is a dll but glu is not, thus:
    #G:\msys64\tmp\mingw32\cclAYXEC.o:osdemo32.c:(.text.startup+0x11f): undefined reference to `_imp__mgluNewQuadric@0'
    #G:\msys64\tmp\mingw32\cclAYXEC.o:osdemo32.c:(.text.startup+0x480): undefined reference to `_imp__mgluCylinder@36'
    #G:\msys64\tmp\mingw32\cclAYXEC.o:osdemo32.c:(.text.startup+0x4f8): undefined reference to `_imp__mgluSphere@20'
    #G:\msys64\tmp\mingw32\cclAYXEC.o:osdemo32.c:(.text.startup+0x513): undefined reference to `_imp__mgluDeleteQuadric@4'
    #collect2.exe: error: ld returned 1 exit status
    allowfail=true
fi
set -x
$OSDEMO_LD $CFLAGS -I$osmesaprefix/include -I../../src/util $INCLUDES  -o osdemo32 osdemo32.c -L$osmesaprefix/lib $LIBS32 $llvmlibs || $allowfail
./osdemo32 image32.tga || $allowfail
$OSDEMO_LD $CFLAGS -I$osmesaprefix/include -I../../src/util $INCLUDES  -o osdemo osdemo.c -L$osmesaprefix/lib $LIBS32 $llvmlibs || $allowfail
./osdemo image.tga || $allowfail
# osdemo16 hangs and runs forever on 17.3.9
$OSDEMO_LD $CFLAGS -I$osmesaprefix/include -I../../src/util $INCLUDES  -o osdemo16 osdemo16.c -L$osmesaprefix/lib $LIBS32 $llvmlibs || $allowfail
./osdemo16 image16.tga || $allowfail
# results are in image32.tga image16.tga image.tga
# multithreaded test: each thread renders with its own context into its own buffer
mtdriver=-1
if [ "$osmesadriver" = 3 ] || [ "$osmesadriver" = 4 ]; then
    mtdriver=2 # alternate softpipe and llvmpipe between threads (needs OSMESA_GALLIUM_DRIVER)
fi
mtflags=
if [ "$mangled" = 1 ]; then
    mtflags="-DMANGLED"
fi
$OSDEMO_LD $CFLAGS $mtflags -I$osmesaprefix/include -o osmesa_mt_test "$srcdir/osdemo/osmesa_mt_test.c" -L$osmesaprefix/lib $LIBS32 $llvmlibs -lpthread || $allowfail
if [ "$mesonbuild" = 1 ]; then
    ./osmesa_mt_test 8 50 $mtdriver || $allowfail
else
    # Mesa 18.3.6 with the thread-safety patches can still crash rarely in this test
    if ! ./osmesa_mt_test 8 50 $mtdriver; then
        echo "Warning: the multithreaded test failed"
        if [ -n "${GITHUB_ACTIONS:-}" ]; then
            echo "::warning::the multithreaded test failed with Mesa $mesaversion (a known rare crash of Mesa <= 18)"
        fi
    fi
fi
set +x
print_elapsed "osdemo build and run" $osdemostart
fi # buildosdemo == 1

print_elapsed "Total" 0
exit

# Useful information:
# Configuring osmesa 9.2.2:
# http://www.paraview.org/Wiki/ParaView/ParaView_And_Mesa_3D#OSMesa.2C_Mesa_without_graphics_hardware

# MESA_GL_VERSION_OVERRIDE an OSMesa should not be used before Mesa 11.2,
# + patch for earlier versions:
# https://cmake.org/pipermail/paraview/2015-December/035804.html
# patch: http://public.kitware.com/pipermail/paraview/attachments/20151217/4854b0ad/attachment.bin

# llvmpipe vs swrast benchmarks:
# https://cmake.org/pipermail/paraview/2015-December/035807.html

#env MESA_GL_VERSION_OVERRIDE=3.2 MESA_GLSL_VERSION_OVERRIDE=150 ./osdemo32

# Local Variables:
# indent-tabs-mode: nil
# sh-basic-offset: 4
# sh-indentation: 4
