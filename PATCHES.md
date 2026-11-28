# Why OSMesa, and what the patches do

This document explains why this script exists, and what each change it makes to Mesa is for. The patch descriptions below refer to the patch set for Mesa 18.3.6 (`patches/mesa-18.3.6/`), the newest autoconf version; older versions use the same patches, with small adaptations. Mesa 25.0.7, the default, has its own section ([6. Moving to Mesa 25.0.7](#6-moving-to-mesa-2507)).

## What OSMesa is for

[OSMesa](https://docs.mesa3d.org/osmesa.html) ("off-screen Mesa") is Mesa's software OpenGL implementation that renders into a memory buffer supplied by the application. It needs no window system, no display connection and no GPU.

Applications such as [Natron](https://natrongithub.github.io/) and its OpenFX plugins use it to run OpenGL-based image processing on machines without a usable GPU, for example render farms, headless servers, virtual machines and CI. They also use it as a CPU fallback when the GPU's OpenGL is missing or broken.

Using OSMesa in such an application has two requirements that stock Mesa did not meet. Almost all the non-build-related patches exist because of them:

1. **Thread safety.** The application renders from many threads at once, each with its own OSMesa context.
2. **Living in the same process as the system OpenGL.** The same application also uses the GPU's OpenGL (for its user interface and for GPU rendering). Both libraries export the same `gl*` functions, so OSMesa's functions must have different names.

The script also adds a third, smaller feature: choosing the Gallium driver (softpipe or llvmpipe) for each context.

## 1. Thread safety

**Patch:** `gallium-osmesa-threadsafe.patch`. Upstream bug: [mesa#880](https://gitlab.freedesktop.org/mesa/mesa/-/issues/880), originally [fdo#95035](https://bugs.freedesktop.org/show_bug.cgi?id=95035).

The Gallium OSMesa front-end (`src/gallium/state_trackers/osmesa/osmesa.c`) kept its state in three unprotected global variables:

| Global | Problem |
|---|---|
| `stapi`, created on first use in `get_st_api()` | Two threads calling `OSMesaCreateContext()` at the same time could both create it, or use it half-initialized. |
| `stmgr`, created on first use in `get_st_manager()`, holding the single `pipe_screen` | Same race. Also, every context shared one screen, so all contexts had to use the same driver. |
| `BufferList`, a global linked list of `osmesa_buffer` | `OSMesaMakeCurrent()` reused any buffer in the list with the same formats and size. Two threads rendering to two different images of the same size therefore got **the same buffer**, so they drew into each other's memory and also raced on the list itself. |

What the patch changes:

- **Per-context state.** `struct osmesa_context` gets its own `api` and `manager`, and therefore its own `pipe_screen`, created in `OSMesaCreateContext()`. Every place that used `get_st_api()` or `get_st_manager()` now uses the context's own copy. If creation fails, everything created so far is cleaned up.
- **No global buffer list.** Each context owns exactly one buffer, `current_buffer`. `OSMesaMakeCurrent()` reuses it only if the formats and size match. Otherwise it destroys it and creates a new one. `OSMesaDestroyContext()` frees it, so buffers no longer leak. Before the patch, `osmesa_destroy_buffer()` was never called.
- **Stale framebuffer pointers.** The state tracker decides whether it can reuse a framebuffer by comparing *pointers* (`st_framebuffer_reuse_or_create()`). A buffer freed and immediately reallocated can get the same address, so Mesa would keep using the freed framebuffer. After creating a new buffer, the patch clears `ctx->WinSysDrawBuffer` and `ctx->WinSysReadBuffer` to force a fresh lookup.
- **Releasing the current context.** `OSMesaMakeCurrent(NULL, ...)` now calls `_mesa_make_current(NULL, NULL, NULL)`, so the thread no longer references a context that may be destroyed afterwards. `OSMesaMakeCurrent(ctx, NULL, ...)` unbinds the context's buffer and frees it.
- **`OSMesaGetCurrentContext()`** reads the thread's current GL context (`_mesa_get_current_context()`), instead of asking the global `stapi`.
- **Defensive checks:** `assert`s and `NULL` checks on the color resource in `osmesa_read_buffer()` and `OSMesaGetDepthBuffer()`.

The same kind of fix for the other drivers:

- `lp_scene-safe.patch`: llvmpipe's `lp_scene_end_rasterization()` returns early when `scene` is `NULL`, which can happen when a context is unbound or destroyed while no scene is active.
- `swrast-makecurrentnull.patch`: the classic (non-Gallium) OSMesa driver `src/mesa/drivers/osmesa/osmesa.c` gets the same `OSMesaMakeCurrent(NULL, ...)` behavior: release the current context instead of only returning `GL_FALSE`.

## 2. Living in the same process as the system OpenGL ("mangling")

When an application links both the system OpenGL (OpenGL.framework, `libGL`, `opengl32.dll`) and OSMesa, both define `glBegin`, `glDrawArrays`, and so on. With static libraries, or a flat namespace, only one of them can win, and calls go to the wrong implementation.

Mesa used to support a *mangled* build, where every OpenGL function is renamed `mgl*` (`mglBegin`, `mglDrawArrays`, ...). An application then calls the system OpenGL through `gl*` and OSMesa through `mgl*`, in the same process. In practice, the application includes `GL/gl_mangle.h` (which `#define`s every `glFoo` to `mglFoo`) in the code that renders with OSMesa. Natron's OpenFX plugins do exactly that.

How the script builds a mangled OSMesa (`MANGLED=1`, the default):

- **Mesa:** configure with `--enable-mangling`, which defines `USE_MGL_NAMESPACE`. Mesa's headers (`gl.h`, `glx.h`, `glapi.h`) and its generated dispatch code (`mapi_abi.py`: `GLAPI_PREFIX(func)` becomes `mgl##func`) then produce `mgl*` entry points. `OSMesaGetProcAddress("mglFoo")` and `("glFoo")` both work, because `mapi_glapi.c` skips the leading `m`. On Windows (SCons build), `-DUSE_MGL_NAMESPACE` is passed directly, and `mgl_export.patch` renames all exported `gl*` symbols in `osmesa.def` and `osmesa.mingw.def` to `mgl*`.
- **`gl_mangle.h` is regenerated** from the actual headers. Upstream's copy only listed functions from `gl.h` and `glext.h` declared with `GLAPI`. The script adds the GLES headers (`GLES/gl.h`, `GLES2/gl2.h`, `GLES3/gl3*.h`) and also matches `GL_API`, so that the ES entry points are mangled too ([fdo#91724](https://bugs.freedesktop.org/show_bug.cgi?id=91724)).
- **GLU** is built with `CPPFLAGS=-DUSE_MGL_NAMESPACE` against the mangled Mesa, and installed as `libMangledGLU`, so that `mgluSphere()` and friends call `mgl*` functions. GLU 9.0.1 is used because 9.0.2 dropped mangling support.
- **Library names:** the libraries are installed as `libMangledOSMesa32` and `libMangledGLU`, and the `.la` and `.pc` files are adjusted. That way they can't be confused with an unmangled `libOSMesa` or the system `libGLU`.
- `glapi_getproc.c`: the script replaces `MANGLE` with `MANGLE_disabled` there, so that the dispatch table is looked up by unmangled names. This was needed before Mesa 11.2.2, together with `glapi-getproc-mangled.patch`. Since then the file contains no `MANGLE` and the substitution does nothing.

The libraries are static by default (`SHARED=0`). The application embeds its own OSMesa and doesn't depend on whatever `libOSMesa` the system may have.

## 3. Choosing the Gallium driver per context

**Patch:** `osmesa-gallium-driver.patch`.

Stock OSMesa picks softpipe or llvmpipe once, for the whole process, from the `GALLIUM_DRIVER` environment variable. The patch adds a context attribute, `OSMESA_GALLIUM_DRIVER` (`0x38`), to `OSMesaCreateContextAttribs()`: `0` = softpipe, `1` = llvmpipe, `2` = swr. It also passes the driver name down to `osmesa_create_screen()` and `sw_screen_create_named()`, which the patch makes non-`static` for that purpose.

This only works because, after the thread-safety patch, each context has its own `pipe_screen`. The classic driver accepts the attribute and ignores it.

## 4. Build fixes

These patches don't change behavior. They make Mesa build with compilers, SDKs and LLVM versions newer (or older) than the ones Mesa 18.3.6 was released with. Most come from [MacPorts](https://github.com/macports/macports-ports/tree/master/x11/mesa/files) or MSYS2.

| Patch | Applied on | Why |
|---|---|---|
| `gallium_llvm.patch` | all | Build gallivm (llvmpipe's LLVM code generator) with LLVM 5 to 12+: API changes in `lp_bld_init.c` and `lp_bld_misc.cpp`, for example `deregisterEHFrames()` and removed or renamed passes. |
| `gallivm_math_h.patch` | all | Missing `#include <math.h>` in `lp_bld_format_srgb.c`. |
| `install-GL-headers.patch` | all | Install the GL headers and `gl.pc` even though GLX is disabled (`--disable-glx`). Applications need `GL/gl.h`, `GL/osmesa.h` and `GL/gl_mangle.h` from the OSMesa prefix. |
| `swr-sched.patch` | all (swr) | Include `<sched.h>` for `sched_yield()` in the swr driver on non-Windows systems. |
| `add_pi.patch` | all | Define `M_PI`, `M_PI_2` and `M_PI_4` when `<math.h>` doesn't (MinGW in strict mode). |
| `scons-llvm-3-9-libs.patch`, `scons-swr-cc-arch.patch`, `msys2_scons_fix.patch` | Windows (SCons) | Link `ole32` and `uuid`, which LLVM ≥ 3.9 needs. Don't pass MSVC-only flags when the compiler is gcc. Run the code generators with `python2.exe` on MSYS2. |
| `5002-darwin-Suppress-type-conversion-warnings-for-GLhandl.patch` | macOS | On macOS `GLhandleARB` is a `void *`, not an integer: add casts in `shader_query.cpp`. |
| `0002-applegl-Provide-requirements-of-_SET_DrawBuffers.patch` | macOS | MacPorts fix for the Apple GLX backend's link dependencies. GLX is disabled here, so it is harmless. |
| `0002-Hack-to-address-build-failure-when-using-newer-macOS.patch` | macOS | Newer macOS SDKs provide `timespec_get()`, which clashes with Mesa's C11 threads emulation (`include/c11/threads_posix.h`). |
| `missing_clock_gettime.patch` | macOS < 10.12 | `clock_gettime()` only exists since macOS 10.12: use `gettimeofday()` before that. |
| `static-strndup.patch` | macOS < 10.7 | `strndup()` is missing on old macOS: use a private copy in `xmlconfig.c`. |
| `o-cloexec.patch` | macOS 10.6 | `O_CLOEXEC` is missing: fall back to `fcntl(FD_CLOEXEC)` in `disk_cache.c`. |
| `no-missing-prototypes-error.patch` | macOS | Don't turn missing-prototype warnings into errors (`-Werror=missing-prototypes`), which breaks the build with Apple's toolchain. |
| `disable_shader_cache.patch` | macOS < 10.10 | Disable the on-disk shader cache, which doesn't build or work there ([MacPorts #54638](https://trac.macports.org/ticket/54638)). |

On top of these patches, the script passes `-Wno-int-conversion` to clang ≥ 15, which turned int/pointer conversions into errors. It also works around the gl_mangle.h issue described in section 2.

## 5. Status in current Mesa

| | Mesa 18.3.6 + these patches | Current upstream |
|---|---|---|
| OSMesa | yes | **Removed in Mesa 25.1.** The last release with OSMesa is 25.0.7. Upstream's replacement is EGL with the surfaceless platform (`EGL_MESA_platform_surfaceless`) and pbuffers. |
| Thread safety | `gallium-osmesa-threadsafe.patch` | **Fixed upstream** (mesa#880 was closed in Dec 2020). In 25.0.7, each context owns its buffer (no global list), the shared screen is created with `call_once()`, framebuffers are matched by a unique `drawable_ID` instead of by pointer, and `OSMesaMakeCurrent(NULL, NULL, ...)` releases the context. All contexts still share one `pipe_screen`. |
| Per-context driver choice (`OSMESA_GALLIUM_DRIVER`) | `osmesa-gallium-driver.patch` | Not upstream. Only the process-wide `GALLIUM_DRIVER` environment variable. |
| Mangled `mgl*` symbols | `--enable-mangling` | **Removed in Mesa 19.2.2** ([commit](https://gitlab.freedesktop.org/mesa/mesa/-/commit/a0829cf23b307ca44ab8c4505974fb7c8d71a35a)). |
| Build system | autoconf | autoconf was removed in 19.0 and SCons in 21.1. Only meson remains. |
| Classic `swrast` driver | yes | Removed in 21.0. |

## 6. Moving to Mesa 25.0.7

Mesa 25.0.7 is the last release with OSMesa. It was tested on macOS 27 (Xcode 27.2) and macOS 15.7.7 (Xcode 16.4), both arm64, and covers both requirements:

- **Thread safety without patches.** `osdemo/osmesa_mt_test.c` runs N threads. Each creates its own context and renders its own color into its own same-size buffer, which is the case that shared buffers before the fix. It then checks every pixel. Stock 25.0.7 passed every run (up to 64 threads, with llvmpipe and softpipe). The patched 18.3.6 crashed in about 1 run out of 15 with 8 threads.
- **Mangling with a small patch.** `patches/mesa-25.0.7/mgl-namespace.patch` puts back the `USE_MGL_NAMESPACE` hooks that Mesa 19.2.2 removed. They are about 50 lines in `gl.h`, `glx.h`, `glapi.h`, `glapi_dispatch.c`, `glapi_getproc.c`, the dispatch generators and `include/meson.build`. `gl_mangle.h` is generated from the actual headers by running `patches/mesa-25.0.7/gl_mangle.h.in` with `sh` in `include/GL`. That template is the 18.3.6 generator with the GLES fix, extended to `GLES/glext.h` and `GLES2/gl2ext.h`, because some dispatch functions are declared only there. Built with `-DUSE_MGL_NAMESPACE`, `libOSMesa` exports no `gl*` symbols, only 1296 `mgl*` and 13 `OSMesa*`. A program linked with both OpenGL.framework and this OSMesa gets `glGetString` from Apple's `libGL.dylib` and `mglGetString` from OSMesa. The multithreaded test passes in that configuration too.

- **Per-context driver choice.** `patches/mesa-25.0.7/osmesa-gallium-driver.patch` ports `OSMESA_GALLIUM_DRIVER` (`0x38`): `0` = softpipe, `1` = llvmpipe. `2` (swr) falls back to llvmpipe, because swr was removed from Mesa (22.0). Instead of one screen per context (the 18.3.6 approach), there is one shared screen per driver (default, softpipe, llvmpipe), created on demand under a mutex. Each context and its buffers use their driver's screen. Contexts sharing objects must use the same driver. At exit, the screens are destroyed only if no context is left. Otherwise a program that calls `exit()` with a live context could hang: destroying llvmpipe's screen while that context's rendering is queued leaves some rasterizer threads waiting forever (found with piglit, [#26](https://github.com/devernay/osmesa-install/issues/26); Mesa's own OSMesa has the same race with its single screen). This also keeps the screens valid for exit handlers or static destructors that destroy contexts later. `OSMESA_MAJOR_VERSION.OSMESA_MINOR_VERSION` is still 11.2, so code testing `>= 1102` (like openfx-misc's Shadertoy) keeps working. Tested with every thread on softpipe, every thread on llvmpipe, and alternating threads.
- **Static library.** Shadertoy (openfx-misc) links `-lMangledOSMesa32` statically into its plugin bundle, with `-fvisibility=hidden` and an `-exported_symbols_list`. All OSMesa and LLVM symbols then stay hidden inside the plugin, and no dylib needs to ship with it. Mesa only builds `libOSMesa` as a shared library, but its link line lists every internal static archive and object (17 of them). Merging those with `libtool -static` (or `ar` on Linux) gives a complete `libMangledOSMesa32.a`: no `gl*` symbols, 2224 `mgl*` and 13 `OSMesa*`. A program linked statically against it, as Shadertoy links (`-lMangledOSMesa32 -lz` plus the LLVM static libraries), passes the multithreaded test.

### LLVM version

| LLVM | Result with Mesa 25.0.7 |
|---|---|
| 6.0.1 | Doesn't compile: gallivm uses `LLVMBuildIntCast2` (LLVM ≥ 8) and atomic `FAdd` (LLVM ≥ 10) unconditionally. Meson's `>= 5.0.0` check is misleading. |
| 15.0.7 | Works. Built from the `llvm-project` tarball (LLVM ≥ 15 can't be built from the standalone `llvm-X.src` tarball, which needs the separate `cmake` modules), static, RTTI, host target only, without zlib, zstd and libxml2. The resulting program only depends on system libraries. Homebrew's `llvm@15` works too. |
| 19.1.7 | Works. **This is the default the script builds**, because LLVM 19 is the version Mesa 25.0's CI used (x86_64 and arm64). Built by the script in 10 min on 8 cores, with system library dependencies only. |
| 22.1.8 (MacPorts), 23.1.4 (Homebrew) | Work. As with any MacPorts or Homebrew LLVM, a program linked statically against them depends on their dylibs (`libzstd`, and `libz3` or `libunwind`), and they target the macOS version they were built on (27.0 here). |

**Minimum: LLVM 15**; 15.0.7 to 23.1.4 were tested. Versions 10 to 14 may work, but are untested: many of gallivm's code paths are only for LLVM ≥ 15. Linking needs these LLVM components: `bitwriter engine mcdisassembler mcjit core executionengine scalaropts transformutils instcombine coroutines native passes`. That's more than the `engine mcjit mcdisassembler` that Natron's build scripts pass today. For the host-only LLVM the script builds, those components are 52 of LLVM's 77 libraries (79 of 90 MB), because `passes` pulls in all the optimization passes. Building only those components would save little.

**Redistribution:** LLVM is always linked statically (`-Dshared-llvm=disabled`, `llvm-config --link-static`), and plugins like Shadertoy hide all its symbols. A dynamic `libLLVM` or exported LLVM symbols would clash with the host's or other plugins' LLVM: either a different version gets used, or LLVM aborts with `CommandLine Error: Option ... registered more than once`. For redistributed binaries, use the LLVM built by the script, which has no dependencies besides the system libraries and follows `MACOSX_DEPLOYMENT_TARGET`. `LLVM_SYSTEM=1` uses an installed LLVM, which is fine for local builds.

### C++20 (VFX Reference Platform CY2027)

Mesa 25.0.7 is C++17 by default (`cpp_std=c++17` in its `meson.build`). It also builds as C++20 (`-Dcpp_std=c++20`). This was tested with Apple clang 21 (Xcode 27.2), mangled, llvmpipe, with LLVM 19.1.7. There are no errors, only 16 extra warnings: bitwise operations between different enum types in `src/mesa/main/formats.h`, which C++20 deprecates (`-Wdeprecated-enum-enum-conversion`; C++26 would make them errors). The resulting library passes the multithreaded test, compiled as C++20.

Code that uses OSMesa can be C++20 either way. The installed headers (`GL/gl_mangle.h`, `GL/osmesa.h`, `GL/gl.h`, `GL/glext.h`) compile cleanly with `-std=c++20 -Wall -Wextra -Wpedantic`. A C++20 plugin can also link the default C++17 `libMangledOSMesa32.a` and LLVM, because OSMesa's API is C and both use the same C++ standard library. So the default build is fine for CY2027.

Not tested: gcc in C++20 mode, and LLVM itself built as C++20 (it is C++17 by default, which doesn't matter for code using it).

### Windows (MSYS2 MINGW64)

Mesa 25.0.7 builds with meson and MinGW gcc. The script works around five Windows-specific problems (the SCons build of Mesa 18.3.6 needs Python 2, which MSYS2 no longer has):

- **Windows platform:** meson is run with `-Dplatforms=windows`. Only then does Mesa define `_GLAPI_NO_EXPORTS` for libmesa, without which `osmesa.dll` fails to link (`__imp__mesa_glapi_get_context`, ...).
- **DLL exports:** `osmesa.def.in` and libgl-gdi's `opengl32.def.in` list the `gl*` functions, which don't exist in a mangled build (`cannot export glAccum`). They are renamed to `mgl*`, as `mgl_export.patch` does for SCons.
- **GL headers:** Mesa doesn't install `GL/gl.h`, `glext.h`, ... on Windows, because it expects the system's. Without them, GLU builds against MinGW's GL 1.1 `gl.h`, and there is no `gl_mangle.h`. The script copies Mesa's headers (and `KHR/khrplatform.h`) to the prefix.
- **dllimport:** GLU's `glu.h` declares `GLAPI __declspec(dllimport)` whenever `_DLL` is defined, which MinGW does. That also applies to the OSMesa functions declared after it, and breaks linking with the static libraries (`__imp_mgluNewQuadric`, `__imp_OSMesaMakeCurrent`). For static builds, dllimport is only used if `GLU_DLL` is defined.
- **System libraries:** programs linking the static library also need `-lsynchronization` (`WaitOnAddress`, used by Mesa's futex code) and `-lws2_32`. They are listed in `osmesa.pc`.

Paths given to native Windows programs (meson, ar, and `osmesa.pc`, whose output goes to the native compiler) are converted with `cygpath -m`. The OSMesa library's link inputs are read with `ninja -t query`, because on Windows the link command uses a response file. CI uses MSYS2's static LLVM 23.1.5 (`LLVM_PREFIX=/mingw64`); LLVM built by the script on Windows is untested.

### Remaining work

- **Build system:** meson and ninja, plus Python 3 with `mako` and `PyYAML`.
- **Exported symbols of the shared library:** on macOS, the dylib also exports all internal LLVM and Mesa symbols. The `osmesa.sym` version script is only used with GNU ld, so macOS needs an `-exported_symbols_list`. This only matters if `SHARED=1`.

- **llvmpipe on AArch64: saturating packs.** `patches/mesa-25.0.7/llvmpipe-pack-saturate.patch` makes gallivm's `lp_build_pack2()` saturate on every architecture. On x86 (and PowerPC) it uses the `packss`/`packus` instructions, which saturate, and some callers rely on that although the function's contract says they must clamp first. Elsewhere it used a plain shuffle, so out-of-range values wrapped around: e.g. blending into an snorm format gave −0.165 instead of 1.0 on AArch64 (piglit's `fbo-blending-snorm`, [#29](https://github.com/devernay/osmesa-install/issues/29)). Mesa's CI only tests llvmpipe on x86, and Mesa 26.3 has the same code.

## 7. Piglit on OSMesa (release gate)

Piglit creates its GL contexts through its "framework" layer (`tests/util/piglit-framework-gl/`), over Waffle (GLX, EGL, WGL, CGL) or GLUT. None of them can create an OSMesa context, and our builds have no GLX or EGL. `patches/piglit-6865856/` (piglit at `6865856`, the commit used by Mesa 25.0's CI) has:

- `osmesa-framework.patch`: adds `piglit_osmesa_framework.c`, selected with `-DPIGLIT_USE_OSMESA=ON` (which turns Waffle, GLUT, X11, GBM, Wayland, EGL, GLX, the GLES and Vulkan tests off), and the `osmesa` platform for `piglit run -p osmesa`. The test's "window" is an RGBA buffer in memory (`OSMesaCreateContextAttribs` and `OSMesaMakeCurrent`), with a core profile context if the test supports one, else a compatibility one, of the version it asks for. Swapping buffers only flushes, and `-fbo` renders to an FBO as Waffle's FBO framework does. OSMesa can't make debug, forward-compatible or multisample contexts, so those tests are skipped. `piglit-dispatch` gets every GL function from `OSMesaGetProcAddress`, which accepts the `gl*` names in a mangled build too (`patches/mesa-25.0.7/mgl-namespace.patch` makes `glapi_getproc.c` skip the leading `m`), so piglit itself needs no mangling. Every test links `OSMesa_LIBRARIES` in place of the GL library: `release/piglit.sh` makes `libOSMesaPiglit.so` from the archive's static OSMesa and LLVM, so that LLVM isn't linked into each of the ~2000 test programs.
- `disable-vs_in.patch`: Mesa's CI patch for piglit, which drops the generated `arb_vertex_attrib_64bit` vs_in tests, so that the test list is the one Mesa's expectations were made with.
- `numpy2-reshape.patch`: numpy 2.5 removed `reshape()`'s `newshape` keyword, which piglit's test generators use at this commit.
- `osmesa-fails*.txt`: our expected failures, on top of Mesa's: in general (single front buffer, no shader cache), per architecture, OS or platform (llvmpipe on AArch64, [#29](https://github.com/devernay/osmesa-install/issues/29); macOS, [#30](https://github.com/devernay/osmesa-install/issues/30)), and without `spirv-as`. One of them that passes fails the comparison, so that they don't go stale. `osmesa-passes.txt`: the minimum number of passing tests per profile and platform, which catches tests that skip instead of passing.
