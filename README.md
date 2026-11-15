# osmesa-install

Script and patches to build and install variations of OSMesa http://www.mesa3d.org/osmesa.html:
- "mangled" or not (in mangled OSMesa, all functions start with `mgl` instead of `gl`)
- debug or not
- choice of osmesa driver: `swrast`, `softpipe`, `llvmpipe` or `swr` (SWR is not yet supported on macOS)
- possibility to also compile and install LLVM 6.0.1, 4.0.1 or 3.4.2 for the `llvmpipe` driver (LLVM 19.1.7 for Mesa 25.0.7)
- Mesa 18.3.6 (default, autoconf) or Mesa 25.0.7, the last Mesa release with OSMesa (meson, see below)

## Prerequisites (macOS)

Xcode or the Command Line Tools, plus the following, e.g. from MacPorts:
```
sudo port install python27 cmake autoconf automake libtool pkgconfig gsed xz
sudo port select --set python python27
```
- GNU sed (`gsed`; `brew install gnu-sed` on Homebrew) is required: Mesa's configure is run with `SED=gsed` on macOS.
- `xz` provides `xzcat`, used to unpack the Mesa and LLVM tarballs (macOS doesn't ship it).
- On macOS older than 10.12, the script also needs MacPorts `clang-9.0`, and on 10.6 and older, `coreutils` (for `gsort`).

## Prerequisites (Linux, Mesa 25.0.7)

On Debian/Ubuntu: `sudo apt-get install build-essential cmake pkg-config xz-utils zlib1g-dev meson ninja-build python3-mako python3-yaml python3-packaging bison flex freeglut3-dev` (`freeglut3-dev` provides `GL/glut.h`, needed to compile the osdemo tests).

## Usage

- edit variables / paths as the beginning of the `osmesa-install.sh`
  script
- compile and install:
```
mkdir build
cd build
bash ../osmesa-install.sh
```
  (the script needs bash: `sh` is not bash on e.g. Debian/Ubuntu)
- there is a test program on the `osdemo` directory, with a few checks, and a multithreaded test (`osdemo/osmesa_mt_test.c`), which the script runs at the end
- LLVM (for the `llvmpipe` driver): by default (`LLVM_BUILD=auto`), the script uses the LLVM in `LLVM_PREFIX` (`/opt/llvm`) if it is suitable for the Mesa version (version, RTTI, static libraries), and downloads and builds it there if `LLVM_PREFIX` contains no LLVM. An existing, unsuitable LLVM is never replaced automatically: the script stops, and you can give another `LLVM_PREFIX` (e.g. `/opt/llvm-15.0.7` for Mesa 25.0.7), or use `LLVM_BUILD=1` to rebuild it in place. `LLVM_BUILD=0` never builds LLVM. With `LLVM_SYSTEM=1`, if `LLVM_PREFIX` has no suitable LLVM, the newest suitable LLVM installed by MacPorts, Homebrew or the system is used instead (skipping those built for a newer macOS than `MACOSX_DEPLOYMENT_TARGET`). LLVM is still linked statically, but the result then depends on that LLVM's own dependencies (e.g. `libzstd`, `libxml2` from MacPorts or Homebrew) and minimum macOS version: use it for local builds, not for redistributed plugins.

## Mesa 25.0.7

Mesa 25.0.7 is the last Mesa release with OSMesa (it was removed in 25.1). It is thread-safe without patches, and the script adds back mangling support and per-context driver selection (see [PATCHES.md](PATCHES.md)). To build it:
```
env OSMESA_VERSION=25.0.7 bash ../osmesa-install.sh
```
It needs, in addition to the prerequisites above:
- `meson` and `ninja` (e.g. `sudo port install meson ninja`)
- Python 3 with the `mako` and `yaml` modules (e.g. `python3 -m pip install mako pyyaml`; set `PYTHON` to use another `python3`)
- LLVM 15 or later for `llvmpipe` (15.0.7, 19.1.7, 22.1.8 and 23.1.4 were tested). LLVM 19.1.7, the version used by Mesa 25.0's CI, is built by default if `LLVM_PREFIX` has no LLVM. The LLVM built by the script has no dependencies besides the system libraries, so it is the one to use for redistributed binaries.

The static library (`libMangledOSMesa32.a`, the default) needs more LLVM components than with Mesa 18. Link with:
```
-lMangledOSMesa32 -lz `llvm-config --link-static --ldflags --libs bitwriter engine mcdisassembler mcjit core executionengine scalaropts transformutils instcombine coroutines native passes --system-libs`
```
(or use `pkg-config --static --libs osmesa`).

## Why these patches?

OSMesa is used here by applications that render with OpenGL from many threads, without a GPU, in the same process as the system's OpenGL. Stock Mesa supports neither. See [PATCHES.md](PATCHES.md) for why OSMesa is used, what each patch does, and which of these fixes are now upstream.

## Notes and caveats

The latest Mesa version that can be built using this script with autoconf is 18.3.6, and with meson 25.0.7 (only on macOS and Linux for now, and Linux is untested).

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

