#!/bin/sh -e
# prefix to the osmesa installation
osmesaprefix="/opt/osmesa"
# mesa version
mesaversion=11.2.2
# mesa-demos version
demoversion=8.3.0
# glu version
gluversion=9.0.0
# set debug to 1 to compile a version with debugging symbols
debug=0
# set clean to 1 to clean the source directories first (recommended)
clean=1
# set osmesadriver to:
# - 1 to use "classic" osmesa resterizer instead of the Gallium driver
# - 2 to use the "softpipe" Gallium driver
# - 3 to use the "llvmpipe" Gallium driver (also includes the softpipe driver, which can
#     be selected at run-time by setting en var GALLIUM_DRIVER to "softpipe")
osmesadriver=3
# do we want a mangled mesa + GLU ?
mangled=1
# the prefix to the LLVM installation
llvmprefix="/opt/llvm"
# do we want to build the proper LLVM static libraries too? or are they already installed ?
buildllvm=0
llvmversion=3.8.0
if [ `uname` = Darwin -a `uname -r | awk -F . '{print $1}'` = 10 ]; then
    llvmversion=3.4.2
fi

# tell curl to continue downloads
curlopts="-C -"
srcdir=`dirname $0`

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
else
    echo "Error: osmesadriver must be 1, 2 or 3"
    exit
fi
if [ "$clean" = 1 ]; then
    echo "- clean sources"
fi

if [ "$debug" = 1 ]; then
    CFLAGS="-g"
    CXXFLAGS="-g"
else
    CFLAGS="-O3"
    CXXFLAGS="-O3"
fi

CC=gcc
CXX=g++

if [ `uname` = Darwin ]; then
  if [ `uname -r | awk -F . '{print $1}'` = 10 ]; then
    # On Snow Leopard, build universal
    archs="-arch i386 -arch x86_64"
    CFLAGS="$CFLAGS $archs"
    CXXFLAGS="$CXXFLAGS $archs"
    ## uncomment to use clang 3.4 (not necessary, as long as llvm is not configured to be pedantic)
    #CC=clang-mp-3.4
    #CXX=clang++-mp-3.4
  fi
fi


# On MacPorts, building Mesa requires the following packages:
# sudo port install xorg-glproto xorg-libXext xorg-libXdamage xorg-libXfixes xorg-libxcb

llvmlibs=
if [ ! -d "$osmesaprefix" -o ! -w "$osmesaprefix" ]; then
   echo "Error: $osmesaprefix does not exist or is not user-writable, please create $osmesaprefix and make it user-writable"
   exit
fi
if [ "$osmesadriver" = 3 ]; then
   if [ "$buildllvm" = 1 ]; then
      if [ ! -d "$llvmprefix" -o ! -w "$llvmprefix" ]; then
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
      if [ ! -f llvm-${llvmversion}.src.tar.$archsuffix ]; then
	  # the llvm we server doesnt' allow continuing partial downloads
	  curl $curlopts -O http://www.llvm.org/releases/${llvmversion}/llvm-${llvmversion}.src.tar.$archsuffix
      fi
      $xzcat llvm-${llvmversion}.src.tar.$archsuffix | tar xf -
      cd llvm-${llvmversion}.src
      cmake_archflags=
      if [ $llvmversion = 3.4.2 -a `uname` = Darwin -a `uname -r | awk -F . '{print $1}'` = 10 ]; then
	  if [ "$debug" = 1 ]; then
	      debugopts="--disable-optimized --enable-debug-symbols --enable-debug-runtime --enable-assertions"
	  else
	      debugopts="--enable-optimized --disable-debug-symbols --disable-debug-runtime --disable-assertions"
	  fi
          # On Snow Leopard, build universal
	  # and use configure (as macports does)
	  # workaround a bug in Apple's shipped gcc driver-driver
          if [ "$CXX" != clang-mp-3.4 ]; then
	      echo "static int ___ignoreme;" > tools/llvm-shlib/ignore.c
	  fi
          env CC="$CC" CXX="$CXX" REQUIRES_RTTI=1 UNIVERSAL=1 UNIVERSAL_ARCH="i386 x86_64" ./configure --prefix="$llvmprefix" \
	      --enable-bindings=none --disable-libffi --disable-shared --enable-static --enable-jit --enable-pic \
              --enable-targets=host --disable-profiling \
	      --disable-backtraces $debugopts
	  env REQUIRES_RTTI=1 UNIVERSAL=1 UNIVERSAL_ARCH="i386 x86_64" make -j4 install
      else
	  if [ `uname` = Darwin -a `uname -r | awk -F . '{print $1}'` = 10 ]; then
              # On Snow Leopard, build universal
	      cmake_archflags="-DCMAKE_OSX_ARCHITECTURES=i386;x86_64"
	      # Proxy for eliminating the dependency on native TLS
              # http://trac.macports.org/ticket/46887
              cmake_archflags="$cmake_archflags -DLLVM_ENABLE_BACKTRACES=OFF"

              # https://llvm.org/bugs/show_bug.cgi?id=25680
              #configure.cxxflags-append -U__STRICT_ANSI__
	  fi
          mkdir build
          cd build
	  if [ "$debug" = 1 ]; then
	      debugopts="-DCMAKE_BUILD_TYPE=Debug -DLLVM_ENABLE_ASSERTIONS=ON -DLLVM_INCLUDE_TESTS=ON -DLLVM_INCLUDE_EXAMPLES=ON"
	  else
	      debugopts="-DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF"
	  fi

          env CC="$CC" CXX="$CXX" REQUIRES_RTTI=1 cmake .. -DCMAKE_INSTALL_PREFIX=${llvmprefix} \
	      -DLLVM_TARGETS_TO_BUILD="host" \
	      -DLLVM_ENABLE_RTTI=ON \
	      -DLLVM_REQUIRES_RTTI=ON \
	      -DBUILD_SHARED_LIBS=OFF \
	      -DBUILD_STATIC_LIBS=ON \
	      -DLLVM_ENABLE_FFI=ON \
	      -DLLVM_BINDINGS_LIST=none \
	      -DLLVM_ENABLE_PEDANTIC=OFF \
	      $debugopts $cmake_archflags
          env REQUIRES_RTTI=1 make -j4
          make install
          cd ..
      fi
      cd ..
   fi
   if [ ! -x "$llvmprefix/bin/llvm-config" ]; then
      echo "Error: $llvmprefix/bin/llvm-config does not exist, please install LLVM with RTTI support in $llvmprefix"
      echo " download the LLVM sources from llvm.org, and configure it with:"
      echo " env CC=$CC CXX=$CXX cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$llvmprefix -DBUILD_SHARED_LIBS=OFF -DLLVM_ENABLE_RTTI=1 -DLLVM_REQUIRES_RTTI=1 -DLLVM_ENABLE_PEDANTIC=0 $cmake_archflags"
      echo " env REQUIRES_RTTI=1 make -j4"
      exit
   fi
   llvmcomponents="engine"
   if [ "$debug" = 1 ]; then
       llvmcomponents="$llvmcomponents mcdisassembler"
   fi
   llvmlibs=`${llvmprefix}/bin/llvm-config --ldflags --libs $llvmcomponents`
   if /opt/llvm/bin/llvm-config --help 2>&1 | grep -q system-libs; then
       llvmlibsadd=`${llvmprefix}/bin/llvm-config --system-libs`
   else
       # on old llvm, system libs are in the ldflags
       llvmlibsadd=`${llvmprefix}/bin/llvm-config --ldflags`
   fi
   llvmlibs="$llvmlibs $llvmlibsadd"
fi

if [ "$clean" = 1 ]; then
    rm -rf "mesa-$mesaversion" "mesa-demos-$demoversion" "glu-$gluversion"
fi

echo "* downloading Mesa ${mesaversion}..."
curl $curlopts -O ftp://ftp.freedesktop.org/pub/mesa/${mesaversion}/mesa-${mesaversion}.tar.gz
tar zxf mesa-${mesaversion}.tar.gz

#download and apply patches from MacPorts

echo "* applying patches..."

PATCHES="\
glapi-getproc-mangled.patch \
mesa-glversion-override.patch \
gallium-osmesa-threadsafe.patch \
lp_scene-safe.patch \
gallium-once-flag.patch \
osmesa-gallium-driver.patch \
"

if [ `uname` = Darwin ]; then
    # patches for Mesa 11.1.2 from
    # https://trac.macports.org/export/146733/trunk/dports/x11/mesa/files/5001-glext.h-Add-missing-include-of-stddef.h-for-ptrdiff_.patch
    PATCHES="$PATCHES \
    5001-glext.h-Add-missing-include-of-stddef.h-for-ptrdiff_.patch \
    5002-darwin-Suppress-type-conversion-warnings-for-GLhandl.patch \
    5003-applegl-Provide-requirements-of-_SET_DrawBuffers.patch \
    static-strndup.patch \
    no-missing-prototypes-error.patch \
    "
fi

for i in $PATCHES; do
    if [ -f "$srcdir"/patches/mesa-$mesaversion/$i ]; then
	echo "* applying patch $i"
	patch -p1 -d mesa-${mesaversion} < "$srcdir"/patches/mesa-$mesaversion/$i
    fi
done

cd mesa-${mesaversion}


echo "* fixing gl_mangle.h..."
# edit include/GL/gl_mangle.h, add ../GLES/gl.h to the "files" variable and change GLAPI in the grep line to GL_API
(cd include/GL; sed -e 's@gl.h glext.h@gl.h glext.h ../GLES/gl.h@' -e 's@\^GLAPI@^GL_\\?API@' -i.orig gl_mangle.h)
(cd include/GL; sh ./gl_mangle.h > gl_mangle.h.new && mv gl_mangle.h.new gl_mangle.h)

echo "* fixing src/mapi/glapi/glapi_getproc.c..."
# functions in the dispatch table sre not stored with the mgl prefix
sed -i.bak -e 's/MANGLE/MANGLE_disabled/' src/mapi/glapi/glapi_getproc.c

echo "* building Mesa..."

test -f Mafefile && make -j4 distclean # if in an existing build
 
autoreconf -fi

confopts="\
    --disable-dependency-tracking \
    --enable-static \
    --disable-shared \
    --enable-texture-float \
    --disable-gles1 \
    --disable-gles2 \
    --disable-dri \
    --disable-dri3 \
    --disable-glx \
    --disable-egl \
    --disable-gbm \
    --disable-xvmc \
    --disable-vdpau \
    --disable-omx \
    --disable-va \
    --disable-opencl \
    --disable-shared-glapi \
    --disable-driglx-direct \
    --with-dri-drivers= \
    --with-osmesa-bits=32 \
    --with-egl-platforms= \
    --prefix=$osmesaprefix \
"

if [ "$osmesadriver" = 1 ]; then
    # pure osmesa (swrast) OpenGL 2.1, GLSL 1.20
    confopts="${confopts} \
     --enable-osmesa \
     --disable-gallium-osmesa \
     --disable-gallium-llvm \
     --with-gallium-drivers= \
    "
elif [ "$osmesadriver" = 2 ]; then
    # gallium osmesa (softpipe) OpenGL 3.0, GLSL 1.30
    confopts="${confopts} \
     --disable-osmesa \
     --enable-gallium-osmesa \
     --disable-gallium-llvm \
     --with-gallium-drivers=swrast \
    "
else
    # gallium osmesa (llvmpipe) OpenGL 3.0, GLSL 1.30
    confopts="${confopts} \
     --enable-gallium-osmesa \
     --enable-gallium-llvm=yes \
     --with-llvm-prefix=$llvmprefix \
     --disable-llvm-shared-libs \
     --with-gallium-drivers=swrast \
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

env PKG_CONFIG_PATH= CC="$CC" CXX="$CXX" ./configure ${confopts} CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS"

make -j4

echo "* installing Mesa..."

make install
if [ `uname` = Darwin ]; then
    # fix the following error:
    #Undefined symbols for architecture x86_64:
    #  "_lp_dummy_tile", referenced from:
    #      _lp_rast_create in libMangledOSMesa32.a(lp_rast.o)
    #      _lp_setup_set_fragment_sampler_views in libMangledOSMesa32.a(lp_setup.o)
    #ld: symbol(s) not found for architecture x86_64
    #clang: error: linker command failed with exit code 1 (use -v to see invocation)
    for f in $osmesaprefix/lib/lib*.a; do
	ranlib -c $f
    done
fi

cd ..

curl $curlopts -O ftp://ftp.freedesktop.org/pub/mesa/glu/glu-${gluversion}.tar.bz2
tar jxf glu-${gluversion}.tar.bz2
cd glu-${gluversion}
confopts="\
    --disable-dependency-tracking \
    --enable-static \
    --disable-shared \
    --enable-osmesa \
    --prefix=$osmesaprefix"
if [ "$mangled" = 1 ]; then
    confopts="${confopts} \
     CPPFLAGS=-DUSE_MGL_NAMESPACE"
fi

env PKG_CONFIG_PATH="$osmesaprefix"/lib/pkgconfig ./configure ${confopts} CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS"
make -j4
make install
if [ "$mangled" = 1 ]; then
    mv "$osmesaprefix/lib/libGLU.a" "$osmesaprefix/lib/libMangledGLU.a" 
    mv "$osmesaprefix/lib/libGLU.la" "$osmesaprefix/lib/libMangledGLU.la"
    sed -e s/libGLU/libMangledGLU/g -i.bak "$osmesaprefix/lib/libMangledGLU.la" 
    sed -e s/-lGLU/-lMangledGLU/g -i.bak "$osmesaprefix/lib/pkgconfig/glu.pc"
fi

# build the demo
cd ..
curl $curlopts -O ftp://ftp.freedesktop.org/pub/mesa/demos/${demoversion}/mesa-demos-${demoversion}.tar.bz2
tar jxf mesa-demos-${demoversion}.tar.bz2
cd mesa-demos-${demoversion}/src/osdemos
# We need to include gl_mangle.h and glu_mangle.h, because osdemo32.c doesn't include them

INCLUDES="-include $osmesaprefix/include/GL/gl.h -include $osmesaprefix/include/GL/glu.h"
if [ "$mangled" = 1 ]; then
    INCLUDES="-include $osmesaprefix/include/GL/gl_mangle.h -include $osmesaprefix/include/GL/glu_mangle.h $INCLUDES"
    LIBS32="-lMangledOSMesa32 -lMangledGLU"
else
    LIBS32="-lOSMesa32 -lGLU"
fi
echo c++ $CFLAGS -I$osmesaprefix/include -I../../src/util $INCLUDES  -o osdemo32 osdemo32.c -L$osmesaprefix/lib $LIBS32 $llvmlibs
c++ $CFLAGS -I$osmesaprefix/include -I../../src/util $INCLUDES  -o osdemo32 osdemo32.c -L$osmesaprefix/lib $LIBS32 $llvmlibs
./osdemo32 image.tga
# result is in image.tga

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
