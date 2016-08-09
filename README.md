# osmesa-install
Script and patches to build and install variations of OSMesa http://www.mesa3d.org/osmesa.html:
- "mangled" or not (in mangled OSMesa, all functions start with `mgl` instead of `gl`)
- debug or not
- choice of osmesa driver: `swrast`, `softpipe` or `llvmpipe`
- possibility to also compile and install LLVM 3.4.2 for the `llvmpipe` driver

## Usage:

- edit variables / paths as the beginning of the `osmesa-install.sh`
  script
- compile and install:
```
mkdir build
cd build
sh ../osmesa-install.sh
```
- there is a test program on the `osdemo` directory, with a few checks

Note that the script fixes the following Mesa bugs related to mangles OSMesa:
- [GL/gl_mangle.h misses symbols from GLES/gl.h](https://bugs.freedesktop.org/show_bug.cgi?id=91724)
