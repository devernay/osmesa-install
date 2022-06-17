#!/bin/bash

# environment variables used by this script:
# - OSMESA_PREFIX: where to install osmesa (must be writable)
# - LLVM_PREFIX: where llvm is / should be installed
# - LLVM_BUILD: whether to build LLVM (0/1, 0 by default)
# - SILENT_LOG: redirect output and error to log file (0/1, 0 by default)
# - BUILD_OSDEMO: try to compile and run osdemo (0/1, 1 by default)
# - MANGLED: build a mangled OSMesa and GLU (function names are prefixed with "m") (0/1, 1 by default)
# - SHARED: build shared OSMesa libraries (0/1, 0 by default)

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
buildllvm="${LLVM_BUILD:-0}"
llvmversion="${LLVM_VERSION:-6.0.1}"
# redirect output and error to log file; exit script on error.
silentlogging="${SILENT_LOG:-0}"
buildosmesa="${BUILD_OSMESA:-1}"
buildglu="${BUILD_GLU:-1}"
buildosdemo="${BUILD_OSDEMO:-1}"
osname=$(uname)
# This script
scriptdir=$(cd "$(dirname "$0")"; pwd)
# scriptname is the script name without the suffix (if any)
scriptname=$(basename "$0")
scriptname="${scriptname%.*}"
if [ "$silentlogging" = 1 ]; then
    # Exit script on error, redirect output and error to log file. Open log for realtime updates.
    set -e
    exec </dev/null &>"$scriptdir/$scriptname.log"
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
    
    if [ "$osver" = 10 ]; then
        # On Snow Leopard (10.6), build universal
        archs="-arch i386 -arch x86_64"
        CFLAGS="$CFLAGS $archs"
        CXXFLAGS="$CXXFLAGS $archs"
    fi
    XCODE_VER=$(xcodebuild -version | sed -e 's/Xcode //' | head -n 1)
    case "$XCODE_VER" in
        4.2*|[5-9].*|1[0-9].*)
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

# tell curl to continue downloads and follow redirects
curlopts="-L -C -"
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
    exit
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

llvmlibs=
if [ ! -d "$osmesaprefix" ] || [ ! -w "$osmesaprefix" ]; then
    echo "Error: $osmesaprefix does not exist or is not user-writable, please create $osmesaprefix and make it user-writable"
    exit
fi
if [ "$osmesadriver" = 3 ] || [ "$osmesadriver" = 4 ]; then
    # see also https://wiki.qt.io/Cross_compiling_Mesa_for_Windows
    if [ "$buildllvm" = 1 ]; then
        if [ ! -d "$llvmprefix" ] || [ ! -w "$llvmprefix" ]; then
            echo "Error: $llvmprefix does not exist or is not user-writable, please create $llvmprefix and make it user-writable"
            exit
        fi
        # LLVM must be compiled with RRTI, see https://bugs.freedesktop.org/show_bug.cgi?id=90032
        if [ "$clean" = 1 ]; then
            rm -rf llvm-${llvmversion}.src
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
        if [ ! -f llvm-${llvmversion}.src.tar.$archsuffix ]; then
            echo "* downloading LLVM ${llvmversion}..."
            if version_gt "${llvmversion}" 7.0.0; then
                curl $curlopts -O "https://github.com/llvm/llvm-project/releases/download/llvmorg-${llvmversion}/llvm-${llvmversion}.src.tar.$archsuffix"
            else
                # the llvm we server doesnt' allow continuing partial downloads
                curl $curlopts -O "http://www.llvm.org/releases/${llvmversion}/llvm-${llvmversion}.src.tar.$archsuffix"
            fi
        fi
        $xzcat llvm-${llvmversion}.src.tar.$archsuffix | tar xf -
        cd llvm-${llvmversion}.src
        echo "* building LLVM..."
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
                $debugopts $cmake_archflags
            env REQUIRES_RTTI=1 make -j"${mkjobs}"
            echo "* installing LLVM..."
            env REQUIRES_RTTI=1 make install
            cd ..
        fi
        cd ..
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
        else
            echo "Error: $llvmconfigbinary does not exist, please install LLVM with RTTI support in $llvmprefix"
            echo " download the LLVM sources from llvm.org, and configure it with:"
            echo " env CC=$CC CXX=$CXX cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$llvmprefix -DBUILD_SHARED_LIBS=OFF -DLLVM_ENABLE_RTTI=1 -DLLVM_REQUIRES_RTTI=1 -DLLVM_ENABLE_PEDANTIC=0 $cmake_archflags"
            echo " env REQUIRES_RTTI=1 make -j${mkjobs}"
        fi
        exit 1
    else
	if version_gt $("$llvmconfigbinary" --version) 6.0.1; then
	    echo "Warning: LLVM version is $($llvmconfigbinary --version), but this script was only tested with versions 3.3 to 6.0.1"
	    echo "LLVM 4.0.1 is the best option for Mesa 17.x."
        echo "LLVM 6.0.1 works with Mesa 18.x."
        echo "LLVM 9.0.1 hangs on osdemo16, at least up to Mesa 18.2.8, but may work with Mesa 18.3.6 and later."
	    echo "Please modify this script and file a github issue if it works with this version."
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
    llvmlibs=$("${llvmconfigbinary}" --ldflags --libs $llvmcomponents)
    if "${llvmconfigbinary}" --help 2>&1 | grep -q system-libs; then
        llvmlibsadd=$("${llvmconfigbinary}" --system-libs)
    else
        # on old llvm, system libs are in the ldflags
        llvmlibsadd=$("${llvmconfigbinary}" --ldflags)
    fi
    llvmlibs="$llvmlibs $llvmlibsadd"
fi

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
    echo "Continuing anyway after 10s."
    sleep 10
fi

if [ "$clean" = 1 ]; then
    rm -rf "mesa-$mesaversion" "mesa-demos-$demoversion" "glu-$gluversion"
fi

if [ "$buildosmesa" = 1 ]; then

archsuffix=xz
xzcat=xzcat
if [ ! -f "mesa-${mesaversion}.tar.${archsuffix}" ]; then
    echo "* downloading Mesa ${mesaversion}..."
    curl $curlopts -O "ftp://ftp.freedesktop.org/pub/mesa/mesa-${mesaversion}.tar.${archsuffix}" \
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

#if mangled, add mgl_export (for mingw)
if [ "$mangled" = 1 ]; then
    PATCHES="$PATCHES mgl_export.patch"
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
fi

for i in $PATCHES; do
    if [ -f "$srcdir/patches/mesa-$mesaversion/$i" ]; then
        echo "* applying patch $i"
        patch -p1 -d "mesa-${mesaversion}" < "$srcdir/patches/mesa-$mesaversion/$i"
    fi
done

cd "mesa-${mesaversion}"

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

    test -f Mafefile && make -j"${mkjobs}" distclean # if in an existing build

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
    echo "Error: Meson build not yet implemented"
    if [ "$mangled" = 1 ]; then
        echo "Error: meson build, which is the only way to build Mesa 19 and later, when autoconf support was dropped, cannot handle mangled GL"
    fi
    exit 1
else
    echo "Error: cannot figure out build system"
    exit 1
fi

cd ..

fi # if [ "$buildosmesa" = 1 ];

if [ "$buildglu" = 1 ]; then

if [ ! -f glu-${gluversion}.tar.gz ]; then
    echo "* downloading GLU ${gluversion}..."
    curl $curlopts -O "ftp://ftp.freedesktop.org/pub/mesa/glu/glu-${gluversion}.tar.gz"
fi
tar zxf glu-${gluversion}.tar.gz
cd glu-${gluversion}
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

fi # if [ "$buildglu" = 1 ];

if [ "$buildosdemo" = 1 ]; then
# build the demo
cd ..
if [ ! -f mesa-demos-${demoversion}.tar.bz2 ]; then
    echo "* downloading Mesa Demos ${demoversion}..."
    curl $curlopts -O "ftp://ftp.freedesktop.org/pub/mesa/demos/${demoversion}/mesa-demos-${demoversion}.tar.bz2" \
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
fi # buildosdemo == 1

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
