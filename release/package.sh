#!/bin/bash
# Package an OSMesa installation made by osmesa-install.sh (static, mangled, llvmpipe) into a
# self-contained archive: headers, libMangledOSMesa32.a, libMangledGLU.a, the LLVM static libraries
# they need, link flags, licenses and a README.
#
# Usage: release/package.sh NAME OSMESA_PREFIX LLVM_PREFIX BUILD_DIR OUT_DIR PLATFORM_DESCRIPTION
#   NAME: archive name (e.g. osmesa-mesa-25.0.7-llvm-19.1.7-macos-arm64), BUILD_DIR: the directory
#   where osmesa-install.sh was run (for the Mesa and GLU licenses), OUT_DIR: where NAME.tar.xz goes.

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
mkdir -p "$d/include" "$d/lib/pkgconfig" "$d/licenses"

# headers (GL/gl.h, glext.h, gl_mangle.h, osmesa.h, glu.h, glu_mangle.h, KHR/khrplatform.h)
cp -R "$osmesaprefix/include/." "$d/include/"

# OSMesa, GLU, and the LLVM libraries they need
cp "$osmesaprefix/lib/libMangledOSMesa32.a" "$osmesaprefix/lib/libMangledGLU.a" "$d/lib/"
llvmlibdir=$("$llvmconfig" --libdir)
for f in $("$llvmconfig" --link-static --libnames $llvmcomponents); do
    cp "$llvmlibdir/$f" "$d/lib/"
done
llvmlibs=$("$llvmconfig" --link-static --libs $llvmcomponents | tr '\n' ' ')
llvmsyslibs=$("$llvmconfig" --link-static --system-libs | tr '\n' ' ')
case "$(uname)" in
    Darwin) syslibs="-lz -lc++";;
    Linux) syslibs="-lz -lpthread -lm -ldl -lstdc++";;
    *) syslibs="-lz -lsynchronization -lws2_32 -lstdc++";; # MSYS2/MinGW
esac
libs="-lMangledGLU -lMangledOSMesa32 $llvmlibs $llvmsyslibs $syslibs"
libs=$(echo $libs) # normalize spaces

# link flags, to use as: -I<dir>/include ... -L<dir>/lib $(cat <dir>/link-flags.txt)
echo "$libs" > "$d/link-flags.txt"

# pkg-config file, relocatable (pkg-config --static --libs osmesa)
cat > "$d/lib/pkgconfig/osmesa.pc" <<EOF
prefix=\${pcfiledir}/../..
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: osmesa
Description: Mesa Off-screen Rendering Library (static, mangled mgl* symbols, llvmpipe and softpipe)
Version: $(sed -n 's/^Version: //p' "$osmesaprefix/lib/pkgconfig/osmesa.pc")
Libs: -L\${libdir} -lMangledOSMesa32
Libs.private: -L\${libdir} $(echo "$libs" | sed -e 's/-lMangledGLU //' -e 's/-lMangledOSMesa32 //')
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
  include/                  GL/gl.h, GL/glext.h, GL/gl_mangle.h, GL/osmesa.h, GL/glu.h, GL/glu_mangle.h, ...
  lib/libMangledOSMesa32.a  OSMesa
  lib/libMangledGLU.a       GLU
  lib/libLLVM*.a            the LLVM libraries used by llvmpipe
  lib/pkgconfig/osmesa.pc   relocatable: pkg-config --static --cflags --libs osmesa
  link-flags.txt            all the libraries to link, in order (use with -L<this directory>/lib)
  licenses/                 Mesa (MIT), GLU (SGI Free Software License B 2.0), LLVM (Apache 2.0 with LLVM exceptions)

Link line:
  -I<dir>/include ... -L<dir>/lib $libs

Built with:
$(cat "$outdir/$name.buildinfo" 2>/dev/null || echo "  (see the release workflow)")
EOF

# archive
(cd "$outdir" && tar cf - "$name" | xz -9 -T0 > "$name.tar.xz")
rm -rf "$d"
ls -la "$outdir/$name.tar.xz"
