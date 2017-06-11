#!/bin/sh -e

# environment variables used by this script:
# - OSMESA_PREFIX: where to install osmesa (must be writable)
# - LLVM_PREFIX: where llvm is / should be installed
# - LLVM_BUILD: whether to build LLVM (0/1, 0 by default)

# prefix to the osmesa installation
osmesaprefix="${OSMESA_PREFIX:-/opt/osmesa}"
# mesa version
mesaversion="${OSMESA_VERSION:-17.1.1}"
# mesa-demos version
demoversion=8.3.0
# glu version
gluversion=9.0.0
# set debug to 1 to compile a version with debugging symbols
debug=0
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
osmesadriver=4
# do we want a mangled mesa + GLU ?
mangled=1
# the prefix to the LLVM installation
llvmprefix="${LLVM_PREFIX:-/opt/llvm}"
# do we want to build the proper LLVM static libraries too? or are they already installed ?
buildllvm="${LLVM_BUILD:-0}"
llvmversion="${LLVM_VERSION:-4.0.0}"
osname=`uname`
if [ "$osname" = Darwin ]; then
     if [ "$osmesadriver" = 4 ]; then
         #     "swr" (aka OpenSWR) is not supported on macOS,
         #     https://github.com/OpenSWR/openswr/issues/2
         #     https://github.com/OpenSWR/openswr-mesa/issues/11
         osmesadriver=3
     fi
     osver=`uname -r | awk -F . '{print $1}'`
     if [ "$osver" = 10 ]; then
         # On Snow Leopard, if using the system's gcci with libstdc++, build with llvm 3.4.2.
         # If using libc++ (see https://trac.macports.org/wiki/LibcxxOnOlderSystems), compile
         # everything with clang-4.0
         if grep -q -e '^cxx_stdlib.*libc\+\+' /opt/local/etc/macports/macports.conf; then
             CC=clang-mp-4.0
             CXX=clang++-mp-4.0
             OSDEMO_LD="clang++-mp-4.0 -stdlib=libc++"
         elif [ -z ${LLVM_VERSION+x} ]; then
             llvmversion=3.4.2
         fi
     fi
fi

# tell curl to continue downloads and follow redirects
curlopts="-L -C -"
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
if [ "$osmesadriver" = 3 ] || [ "$osmesadriver" = 4 ]; then
    # see also https://wiki.qt.io/Cross_compiling_Mesa_for_Windows
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
		  curl $curlopts -O "http://www.llvm.org/releases/${llvmversion}/llvm-${llvmversion}.src.tar.$archsuffix"
      fi
      $xzcat llvm-${llvmversion}.src.tar.$archsuffix | tar xf -
      cd llvm-${llvmversion}.src
      cmake_archflags=
      if [ $llvmversion = 3.4.2 -a "$osname" = Darwin -a `uname -r | awk -F . '{print $1}'` = 10 ]; then
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
	      --disable-backtraces \
	      --disable-terminfo \
	      --disable-zlib \
	      $debugopts
		  env REQUIRES_RTTI=1 UNIVERSAL=1 UNIVERSAL_ARCH="i386 x86_64" make -j${mkjobs} install
      else
		  cmakegen="Unix Makefiles" # can be "MSYS Makefiles" on MSYS
		  cmake_archflags=""
		  llvm_patches=""
		  if [ "$osname" = Darwin -a `uname -r | awk -F . '{print $1}'` = 10 ]; then
              # On Snow Leopard, build universal
		      cmake_archflags="-DCMAKE_OSX_ARCHITECTURES=i386;x86_64"
		      # Proxy for eliminating the dependency on native TLS
              # http://trac.macports.org/ticket/46887
              #cmake_archflags="$cmake_archflags -DLLVM_ENABLE_BACKTRACES=OFF" # flag was added to the common flags below, we don't need backtraces anyway

              # https://llvm.org/bugs/show_bug.cgi?id=25680
              #configure.cxxflags-append -U__STRICT_ANSI__
		  fi
	      if [ "$osname" = "Msys" ] || [ "$osname" = "MINGW64_NT-6.1" ] || [ "$osname" = "MINGW32_NT-6.1" ]; then
              cmakegen="MSYS Makefiles"
              #cmake_archflags="-DLLVM_ENABLE_CXX1Y=ON" # is that really what we want???????
		      cmake_archflags="-DLLVM_USE_CRT_DEBUG=MTd -DLLVM_USE_CRT_RELEASE=MT"
              llvm_patches="msys2_add_pi.patch"
		  fi
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

	      env CC="$CC" CXX="$CXX" REQUIRES_RTTI=1 cmake -G "$cmakegen" .. -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_INSTALL_PREFIX=${llvmprefix} \
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
	      env REQUIRES_RTTI=1 make -j${mkjobs}
	      make install
	      cd ..
      fi
      cd ..
   fi
   llvmconfigbinary=
   if [ "$osname" = "Msys" ] || [ "$osname" = "MINGW64_NT-6.1" ] || [ "$osname" = "MINGW32_NT-6.1" ]; then
       llvmconfigbinary="$llvmprefix/bin/llvm-config.exe"
   else
       llvmconfigbinary="$llvmprefix/bin/llvm-config"
   fi
   if [ ! -x "$llvmconfigbinary" ]; then
      echo "Error: $llvmconfigbinary does not exist, please install LLVM with RTTI support in $llvmprefix"
      echo " download the LLVM sources from llvm.org, and configure it with:"
      echo " env CC=$CC CXX=$CXX cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$llvmprefix -DBUILD_SHARED_LIBS=OFF -DLLVM_ENABLE_RTTI=1 -DLLVM_REQUIRES_RTTI=1 -DLLVM_ENABLE_PEDANTIC=0 $cmake_archflags"
      echo " env REQUIRES_RTTI=1 make -j${mkjobs}"
      exit
   fi
   llvmcomponents="engine mcjit"
   if [ "$debug" = 1 ]; then
       llvmcomponents="$llvmcomponents mcdisassembler"
   fi
   llvmlibs=`"${llvmconfigbinary}" --ldflags --libs $llvmcomponents`
   if "${llvmconfigbinary}" --help 2>&1 | grep -q system-libs; then
       llvmlibsadd=`"${llvmconfigbinary}" --system-libs`
   else
       # on old llvm, system libs are in the ldflags
       llvmlibsadd=`"${llvmconfigbinary}" --ldflags`
   fi
   llvmlibs="$llvmlibs $llvmlibsadd"
fi

if [ "$clean" = 1 ]; then
    rm -rf "mesa-$mesaversion" "mesa-demos-$demoversion" "glu-$gluversion"
fi

echo "* downloading Mesa ${mesaversion}..."
curl $curlopts -O "ftp://ftp.freedesktop.org/pub/mesa/mesa-${mesaversion}.tar.gz" || curl $curlopts -O "ftp://ftp.freedesktop.org/pub/mesa/${mesaversion}/mesa-${mesaversion}.tar.gz"
tar zxf mesa-${mesaversion}.tar.gz

#download and apply patches from MacPorts

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
"

#if mangled and mingw, add mgl_export
#if mingw, add scons_fix.patch ??
if [ "$osname" = "Msys" ] || [ "$osname" = "MINGW64_NT-6.1" ] || [ "$osname" = "MINGW32_NT-6.1" ]; then
    PATCHES="$PATCHES msys2_scons_fix.patch scons-swr-cc-arch.patch"
    if [ "$mangled" = 1 ]; then
	PATCHES="$PATCHES mgl_export.patch"
    fi
fi

if [ "$osname" = Darwin ]; then
    # patches for Mesa 11.2.1 from
    # https://trac.macports.org/browser/trunk/dports/x11/mesa
    PATCHES="$PATCHES \
    0001-mesa-Deal-with-size-differences-between-GLuint-and-G.patch \
    0002-applegl-Provide-requirements-of-_SET_DrawBuffers.patch \
    0003-glext.h-Add-missing-include-of-stddef.h-for-ptrdiff_.patch \
    5002-darwin-Suppress-type-conversion-warnings-for-GLhandl.patch \
    static-strndup.patch \
    no-missing-prototypes-error.patch \
    o-cloexec.patch \
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

if [ "$osname" = "Msys" ] || [ "$osname" = "MINGW64_NT-6.1" ] || [ "$osname" = "MINGW32_NT-6.1" ]; then

    ####################################################################
    # Windows build uses scons

    if [ "$osname" = "MINGW64_NT-6.1" ]; then
        scons_machine="x86_64"
    else
        scons_machine="x86"
    fi
    scons_cflags="$CFLAGS"
    scons_cxxflags="$CXXFLAGS -std=c++11"
    scons_ldflags="-static -s"
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
    mkdir -p $osmesaprefix/include $osmesaprefix/lib/pkgconfig    
    env LLVM_CONFIG="$llvmconfigbinary" LLVM="$llvmprefix" CFLAGS="$scons_cflags" CXXFLAGS="$scons_cxxflags" LDFLAGS="$scons_ldflags" scons build="$scons_build" platform=windows toolchain=mingw machine="$scons_machine" texture_float=yes llvm="$scons_llvm" swr="$scons_swr" verbose=yes osmesa
    cp build/windows-$scons_machine/gallium/targets/osmesa/osmesa.dll $osmesaprefix/lib/
    cp -a include/GL $osmesaprefix/include/ || exit 1
    cat <<EOF > $osmesaprefix/lib/pkgconfig/osmesa.pc
prefix=${osmesaprefix}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: osmesa
Description: Mesa Off-screen Rendering library
Requires: 
Version: $mesaversion
Libs: -L\${libdir} -lOSMesa
Cflags: -I\${includedir}
EOF
    cp $osmesaprefix/lib/pkgconfig/osmesa.pc $osmesaprefix/lib/pkgconfig/gl.pc

    # end of SCons build
    ####################################################################
else

    ####################################################################
    # Unix builds use configure
    
    test -f Mafefile && make -j${mkjobs} distclean # if in an existing build
    
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
    --disable-glx-tls \
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
    elif [ "$osmesadriver" = 3 ]; then
		# gallium osmesa (llvmpipe) OpenGL 3.0, GLSL 1.30
		confopts="${confopts} \
	         --disable-osmesa \
	         --enable-gallium-osmesa \
	         --enable-gallium-llvm=yes \
	         --with-llvm-prefix=$llvmprefix \
	         --disable-llvm-shared-libs \
	         --with-gallium-drivers=swrast \
	    "
    else
		# gallium osmesa (swr) OpenGL 3.0, GLSL 1.30
		confopts="${confopts} \
	         --disable-osmesa \
	         --enable-gallium-osmesa \
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

    env PKG_CONFIG_PATH= CC="$CC" CXX="$CXX" PTHREADSTUBS_CFLAGS=" " PTHREADSTUBS_LIBS=" " ./configure ${confopts} CC="$CC" CFLAGS="$CFLAGS" CXX="$CXX" CXXFLAGS="$CXXFLAGS"

    make -j${mkjobs}

    echo "* installing Mesa..."

    make install
    if [ "$osname" = Darwin ]; then
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

    # End of configure-based build
    ####################################################################    
fi

cd ..

curl $curlopts -O "ftp://ftp.freedesktop.org/pub/mesa/glu/glu-${gluversion}.tar.bz2"
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
make -j${mkjobs}
make install
if [ "$mangled" = 1 ]; then
    mv "$osmesaprefix/lib/libGLU.a" "$osmesaprefix/lib/libMangledGLU.a" 
    mv "$osmesaprefix/lib/libGLU.la" "$osmesaprefix/lib/libMangledGLU.la"
    sed -e s/libGLU/libMangledGLU/g -i.bak "$osmesaprefix/lib/libMangledGLU.la" 
    sed -e s/-lGLU/-lMangledGLU/g -i.bak "$osmesaprefix/lib/pkgconfig/glu.pc"
fi

# build the demo
cd ..
curl $curlopts -O "ftp://ftp.freedesktop.org/pub/mesa/demos/${demoversion}/mesa-demos-${demoversion}.tar.bz2"
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
if [ -z "${OSDEMO_LD:-}" ]; then
    OSDEMO_LD="$CXX"
fi
echo "$OSDEMO_LD $CFLAGS -I$osmesaprefix/include -I../../src/util $INCLUDES  -o osdemo32 osdemo32.c -L$osmesaprefix/lib $LIBS32 $llvmlibs"
$OSDEMO_LD $CFLAGS -I$osmesaprefix/include -I../../src/util $INCLUDES  -o osdemo32 osdemo32.c -L$osmesaprefix/lib $LIBS32 $llvmlibs
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

# Local Variables:
# indent-tabs-mode: nil
# sh-basic-offset: 4
# sh-indentation: 4
