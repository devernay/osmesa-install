#!/bin/bash
# Package an OSMesa installation made by osmesa-install.sh (static, mangled, llvmpipe) and its LLVM
# into a self-contained archive NAME.tar.xz, with one top-level directory NAME containing:
#   osmesa/include/                GL/osmesa.h, the mangled GL headers, GLU headers
#   osmesa/lib/                    libMangledOSMesa32.a, libMangledGLU.a
#   osmesa/lib/pkgconfig/osmesa.pc Libs.private lists the LLVM and system libraries of a static link
#   llvm/bin/llvm-config[.exe]     llvm/lib/libLLVM*.a (static), llvm/include/
#   link-flags.txt, licenses/, README.txt
#
# Usage: release/package.sh NAME OSMESA_PREFIX LLVM_PREFIX BUILD_DIR OUT_DIR PLATFORM_DESCRIPTION
#   NAME: archive name (e.g. osmesa-install-osmesa-mesa-25.0.7-llvm-19.1.7-macos-arm64), BUILD_DIR:
#   the directory where osmesa-install.sh was run (for the Mesa and GLU licenses), OUT_DIR: where
#   NAME.tar.xz goes.

set -eu
set -o pipefail

name="$1"
osmesaprefix="$2"
llvmprefix="$3"
builddir="$4"
outdir="$5"
platform="$6"
scriptdir=$(cd "$(dirname "$0")"; pwd)

# the LLVM components used by Mesa's llvmpipe (see llvm_modules in Mesa's meson.build)
llvmcomponents="bitwriter engine mcdisassembler mcjit core executionengine scalaropts transformutils instcombine coroutines native passes"
llvmconfig="$llvmprefix/bin/llvm-config"
[ -x "$llvmconfig" ] || llvmconfig="$llvmprefix/bin/llvm-config.exe"

mkdir -p "$outdir"
outdir=$(cd "$outdir"; pwd)
d="$outdir/$name"
rm -rf "$d" "$outdir/$name.tar.xz"
mkdir -p "$d/osmesa/include" "$d/osmesa/lib/pkgconfig" "$d/llvm/bin" "$d/llvm/lib" "$d/licenses"

# OSMesa: headers (GL/gl.h, glext.h, gl_mangle.h, osmesa.h, glu.h, glu_mangle.h, KHR/khrplatform.h)
# and static libraries
cp -R "$osmesaprefix/include/." "$d/osmesa/include/"
cp "$osmesaprefix/lib/libMangledOSMesa32.a" "$osmesaprefix/lib/libMangledGLU.a" "$d/osmesa/lib/"

# LLVM: llvm-config, the static libraries and the headers (llvm-config finds them relative to itself)
cp "$llvmconfig" "$d/llvm/bin/"
llvmlibdir=$("$llvmconfig" --libdir)
cp "$llvmlibdir"/libLLVM*.a "$d/llvm/lib/"
cp -R "$("$llvmconfig" --includedir)" "$d/llvm/"
llvmlibs=$("$llvmconfig" --link-static --libs $llvmcomponents | tr '\n' ' ')
llvmsyslibs=$("$llvmconfig" --link-static --system-libs | tr '\n' ' ')
case "$(uname)" in
    Darwin) syslibs="-lz -lc++";;
    Linux) syslibs="-lz -lpthread -lm -ldl -lstdc++";;
    *) syslibs="-lz -lsynchronization -lws2_32 -lstdc++";; # MSYS2/MinGW
esac
libs="-lMangledGLU -lMangledOSMesa32 $llvmlibs $llvmsyslibs $syslibs"
libs=$(echo $libs) # normalize spaces

# link flags, to use as: -I<dir>/osmesa/include ... -L<dir>/osmesa/lib -L<dir>/llvm/lib $(cat <dir>/link-flags.txt)
echo "$libs" > "$d/link-flags.txt"

# pkg-config file (pkg-config --static --libs osmesa): relocatable, and prefix= can also be rewritten
# to the unpacked osmesa directory; the LLVM libraries are in ../llvm/lib
cat > "$d/osmesa/lib/pkgconfig/osmesa.pc" <<EOF
prefix=\${pcfiledir}/../..
libdir=\${prefix}/lib
includedir=\${prefix}/include
llvmlibdir=\${prefix}/../llvm/lib

Name: osmesa
Description: Mesa Off-screen Rendering Library (static, mangled mgl* symbols, llvmpipe and softpipe)
Version: $(sed -n 's/^Version: //p' "$osmesaprefix/lib/pkgconfig/osmesa.pc")
Libs: -L\${libdir} -lMangledOSMesa32
Libs.private: -L\${llvmlibdir} $(echo "$libs" | sed -e 's/-lMangledGLU //' -e 's/-lMangledOSMesa32 //')
Cflags: -I\${includedir}
EOF

# licenses
for f in "$builddir"/mesa-*/docs/license.rst; do
    [ -f "$f" ] && cp "$f" "$d/licenses/Mesa-license.rst"
done
for f in "$builddir"/glu-*/COPYING "$builddir"/glu-*/LICENSE*; do
    [ -f "$f" ] && cp "$f" "$d/licenses/GLU-$(basename "$f")"
done
cp "$scriptdir/LLVM-LICENSE.TXT" "$d/licenses/LLVM-LICENSE.TXT"
cp "$scriptdir/GLU-LICENSE.txt" "$d/licenses/GLU-LICENSE.txt"

mesaversion=$(sed -n 's/^Version: //p' "$osmesaprefix/lib/pkgconfig/osmesa.pc")
llvmversion=$("$llvmconfig" --version)
cat > "$d/README.txt" <<EOF
$name

OSMesa (Mesa's off-screen OpenGL renderer), built by osmesa-install
(https://github.com/devernay/osmesa-install), for $platform.

- Mesa $mesaversion OSMesa, static library, llvmpipe and softpipe drivers, thread-safe.
- Mangled: all OpenGL functions are named mgl* (include GL/gl_mangle.h before GL/gl.h, or compile
  with -DUSE_MGL_NAMESPACE), so OSMesa can be used in the same process as the system's OpenGL.
- OSMESA_GALLIUM_DRIVER context attribute: 0 = softpipe, 1 = llvmpipe, 2 = swr (now llvmpipe).
- GLU 9.0.1, static, mangled (mglu*).
- LLVM $llvmversion, static libraries (lib/libLLVM*.a), built without zlib, zstd and libxml2.

Contents:
  osmesa/include/                 GL/gl.h, glext.h, gl_mangle.h, osmesa.h, glu.h, glu_mangle.h, KHR/
  osmesa/lib/libMangledOSMesa32.a OSMesa
  osmesa/lib/libMangledGLU.a      GLU
  osmesa/lib/pkgconfig/osmesa.pc  pkg-config --static --cflags --libs osmesa (relocatable; Libs.private
                                  has the LLVM and system libraries)
  llvm/bin/llvm-config            LLVM $llvmversion: llvm-config, static libraries (llvm/lib/libLLVM*.a)
  llvm/lib/, llvm/include/        and headers
  link-flags.txt                  all the libraries to link, in order
  licenses/                       Mesa (MIT), GLU (SGI Free Software License B 2.0), LLVM (Apache 2.0
                                  with LLVM exceptions)

Link line:
  -I<dir>/osmesa/include ... -L<dir>/osmesa/lib -L<dir>/llvm/lib $libs

OSMesa build: osmesa-install.sh with OSMESA_VERSION=$mesaversion (meson: -Dosmesa=true
-Dgallium-drivers=llvmpipe,softpipe -Dllvm=enabled -Dshared-llvm=disabled -Dshared-glapi=disabled
-Dplatforms= (windows on Windows) -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dgles1=disabled
-Dgles2=disabled -Dvulkan-drivers= -Dzstd=disabled -Dxmlconfig=disabled -Dexpat=disabled, with
-DUSE_MGL_NAMESPACE and the patches in patches/mesa-$mesaversion), no libdrm.
LLVM build: osmesa-install.sh (static, RTTI, host target only, without zlib, zstd, libxml2, libedit).

Built with:
$(cat "$outdir/$name.buildinfo" 2>/dev/null || echo "  (see the release workflow)")
EOF

# archive
(cd "$outdir" && tar cf - "$name" | xz -9 -T0 > "$name.tar.xz")
rm -rf "$d"
ls -la "$outdir/$name.tar.xz"
