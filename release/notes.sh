#!/bin/bash
# Release notes for TAG (osmesa-mesa-<mesa version>-llvm-<llvm version>), on stdout.
# Usage: release/notes.sh TAG
set -eu
tag=$1
repo=${GITHUB_REPOSITORY:-devernay/osmesa-install}
mesaversion=${tag#osmesa-mesa-}; mesaversion=${mesaversion%%-llvm-*}
llvmversion=${tag##*-llvm-}
commit=${GITHUB_SHA:-$(git -C "$(dirname "$0")" rev-parse "$tag^{commit}" 2>/dev/null || echo "$tag")}
cat <<NOTES
Prebuilt OSMesa: Mesa $mesaversion, static, mangled (mgl*), llvmpipe and softpipe, with GLU 9.0.1 and the static LLVM $llvmversion libraries it needs. Built by [release.yml](https://github.com/$repo/blob/$commit/.github/workflows/release.yml) from $commit.

| Archive | Platform |
|---|---|
| \`osmesa-install-$tag-macos-arm64.tar.xz\` | macOS 14.0 and later, arm64 |
| \`osmesa-install-$tag-macos-x86_64.tar.xz\` | macOS 14.0 and later, x86_64 |
| \`osmesa-install-$tag-windows-ucrt64-x86_64.tar.xz\` | Windows 10 and later, x86_64, MSYS2 UCRT64 (MinGW-w64 gcc), only Windows system DLLs |
| \`osmesa-install-$tag-linux-x86_64.tar.xz\` | Linux x86_64, glibc 2.34+ (Rocky/RHEL 9, gcc-toolset-14), no libdrm |
| \`osmesa-install-$tag-linux-aarch64.tar.xz\` | Linux aarch64, glibc 2.34+ (Rocky/RHEL 9, gcc-toolset-14), no libdrm |

Each archive has one top-level directory with \`osmesa/include/\`, \`osmesa/lib/\` (\`libMangledOSMesa32.a\`, \`libMangledGLU.a\`), \`osmesa/lib/pkgconfig/osmesa.pc\` (relocatable; \`Libs.private\` lists the LLVM and system libraries), \`osmesa/lib/cmake/OSMesa/\` (\`find_package(OSMesa CONFIG)\`), \`llvm/bin/llvm-config\`, \`llvm/lib/libLLVM*.a\`, \`link-flags.txt\`, \`licenses/\` and a \`README.txt\` with the build flags. Verify downloads with \`<archive>.sha256\` or \`SHA256SUMS\` (\`sha256sum -c\`, or \`shasum -a 256 -c\` on macOS).

Each archive is added as soon as its platform is built and checked; the release is a pre-release until every platform is there.
NOTES
