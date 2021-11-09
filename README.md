# osmesa-install

Script and patches to build and install variations of OSMesa http://www.mesa3d.org/osmesa.html:
- "mangled" or not (in mangled OSMesa, all functions start with `mgl` instead of `gl`)
- debug or not
- choice of osmesa driver: `swrast`, `softpipe`, `llvmpipe` or `swr` (SWR is not yet supported on macOS)
- possibility to also compile and install LLVM 6.0.1, 4.0.1 or 3.4.2 for the `llvmpipe` driver

## Usage

- edit variables / paths as the beginning of the `osmesa-install.sh`
  script
- compile and install:
```
mkdir build
cd build
sh ../osmesa-install.sh
```
- there is a test program on the `osdemo` directory, with a few checks

## Notes and caveats

The latest Mesa version that can be built using this script is 18.3.6.

The reasons are:
- Mesa dropped autoconf support with 19.0, supporting only meson and SCons builds. SCons support was also dropped in 21.1. Mangled OSMesa support was only accessible from autoconf and SCons, but it is just a matter of adding `-DUSE_MGL_NAMESPACE` to `CPPFLAGS`, so it should still be possible to easily get mangled OSMesa using meson.
- Source support for GL symbol mangling support was dropped with 19.2.2 ([commit](https://gitlab.freedesktop.org/mesa/mesa/-/commit/a0829cf23b307ca44ab8c4505974fb7c8d71a35a), [relnotes](https://docs.mesa3d.org/relnotes/19.2.2.html)). Re-adding it means we would have to maintain that large patch.
- The legacy `swrast` driver was dropped in Mesa 21.0.0.

An [upstream bug was filed](https://gitlab.freedesktop.org/mesa/mesa/-/issues/880) ([original bug](https://bugs.freedesktop.org/show_bug.cgi?id=95035)) to integrate at least the thread-safety fixes into Mesa, but it may require some work to port to the latest version of Mesa.

Pick the rigght LLVM version for your build:
- Mesa 17.1.10 - 17.3.9 were tested with LLVM 4.0.1.
- Mesa 18.0.4 - 18.3.6 were tested with LLVM 6.0.1.
- LLVM 9 and LLVM 13 hang in osdemo16 for Mesa versions up to 18.2.8 (Mesa 18.3.6 seems to run OK).

The script fixes the following Mesa bugs related to mangled OSMesa:
- [GL/gl_mangle.h misses symbols from GLES/gl.h](https://bugs.freedesktop.org/show_bug.cgi?id=91724)

Also note that the latest clang (tested with 4.0.0) does not build on 32 bits mingw64 due to the following gcc bug (older versions of clang work):
- http://lists.llvm.org/pipermail/cfe-dev/2016-December/052017.html
- https://gcc.gnu.org/bugzilla/show_bug.cgi?id=78936

