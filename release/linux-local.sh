#!/bin/bash
# Fallback for when GitHub's Linux runners are unavailable: build the Linux release archives
# (x86_64 and aarch64) locally, in rockylinux:9 containers with podman (or docker), with the same
# script as the release workflow (release/linux-build.sh), and optionally add them to the GitHub
# release. See "Making a release" in README.md.
#
# Usage: release/linux-local.sh [--upload] [TAG]
#   TAG: osmesa-mesa-<mesa version>-llvm-<llvm version> (default: the versions in release.yml). The
#        sources are "git archive TAG" (or HEAD if the tag doesn't exist yet and --upload isn't given).
#   --upload: add the archives, with ARCHIVE.sha256, to the release TAG with gh (see
#        release/publish.sh and release/finalize.sh), and make it a full release if every platform is
#        there. Architectures already in the release (built on GitHub) are skipped. Without it, the
#        archives are only left in $WORK/out.
#
# Each architecture is built in its own throwaway container (--rm), one at a time; the container
# needs network access (dnf, pip). The architecture that isn't the host's runs under emulation
# (binfmt): with qemu (podman machine's default on Apple Silicon; qemu-user-static on Linux) LLVM
# takes hours, with Rosetta (podman machine with Rosetta enabled, or OrbStack) it is much faster.
# The container engine (e.g. podman machine) needs at least CPUS CPUs and MEMORY_GB of memory
# (podman machine set --cpus 4 --memory 8192), and 15 GB free in its storage (checked).
#
# Host requirements: podman (or CONTAINER=docker), git, curl, and gh for --upload.
# Environment: WORK (/tmp/osmesa-linux-local, must not be in ~/Documents), ARCHS ("aarch64 x86_64"),
# CONTAINER (podman), IMAGE (docker.io/library/rockylinux:9), CPUS (4), MEMORY_GB (6), MKJOBS (4),
# MAX_LOAD (number of CPUs: each build waits until the host load average is below it), MIN_FREE_GB
# (30: and until that much space is free on WORK's disk).

OS=linux
OSNAME=Linux
DEFAULT_ARCHS="aarch64 x86_64"
DEFAULT_WORK=/tmp/osmesa-linux-local
# shellcheck source=release/common.sh
. "$(dirname "$0")/common.sh"
init "$@"
CONTAINER=${CONTAINER:-podman}
IMAGE=${IMAGE:-docker.io/library/rockylinux:9}
CPUS=${CPUS:-4}
MEMORY_GB=${MEMORY_GB:-6}
MKJOBS=${MKJOBS:-4}
storage_gb=15 # free space needed in the container storage

command -v "$CONTAINER" >/dev/null || die "$CONTAINER not found"
resolve_source
skip_published
prepare_sources

# one container at a time, started only when the host isn't overloaded
for arch in $ARCHS; do
    case "$arch" in aarch64) platform=linux/arm64;; x86_64) platform=linux/amd64;; *) die "unknown arch $arch";; esac
    wait_for_host "$WORK"
    # podman machine's disk (40 GB by default) is separate from the host's, and the build needs
    # about 10 GB there
    free=$("$CONTAINER" run --rm --platform "$platform" "$IMAGE" df -Pk / | awk 'NR==2 {print int($4 / 1048576)}') \
        || die "can't run a $IMAGE container for $platform (is the container engine running?)"
    number "$free" "the container storage's free space"
    [ "$free" -ge "$storage_gb" ] || die "only $free GB free in the container storage, $storage_gb GB needed"
    name="osmesa-install-$tag-linux-$arch"
    # the release gate: piglit's full llvmpipe_gl profile on the host's architecture; under
    # emulation (qemu), where it would take hours and time out, only its sanity profile
    profiles="sanity llvmpipe_gl"
    case "$(uname -m)-$arch" in arm64-aarch64|aarch64-aarch64|x86_64-x86_64) ;;
        *) profiles=sanity; log "$arch: emulated, piglit runs only its sanity profile";; esac
    log "$arch: building in a $IMAGE container ($platform; log: $WORK/out/build-$arch.log)"
    # the build runs in the container's own filesystem; only the sources, the tarballs and the
    # output are on the shared directory
    # label=disable: SELinux hosts would deny access to the shared directory (podman and docker)
    # shellcheck disable=SC2016 # expanded in the container
    "$CONTAINER" run --rm --platform "$platform" --security-opt label=disable \
        --cpus "$CPUS" --memory "${MEMORY_GB}g" -v "$WORK:/host" \
        -e CI_MESA_VERSION="$mesaversion" -e CI_LLVM_VERSION="$llvmversion" \
        -e MKJOBS="$MKJOBS" -e NAME="$name" -e ARCH="$arch" -e PIGLIT_PROFILES="$profiles" \
        -e BUILDINFO="$CONTAINER $platform on $(uname -s) $(uname -m), osmesa-install $commit (release/linux-local.sh)" \
        "$IMAGE" bash -c '
            set -eu
            cp -R /host/src /root/w && cd /root/w
            mkdir -p build && cp /host/dl/* build/
            echo "arch: $(uname -m)"
            bash release/linux-build.sh deps
            bash release/linux-build.sh osmesa
            bash release/linux-build.sh check "$ARCH"
            bash release/linux-build.sh package "$NAME" "$ARCH"
            bash release/linux-build.sh test-cmake "$NAME"
            bash release/linux-build.sh test-pkgconfig "$NAME"
            # the release gate, as in the release workflow (release/piglit.sh)
            bash release/piglit.sh deps > /root/piglit-deps.log 2>&1 || { tail -n 30 /root/piglit-deps.log; exit 1; }
            status=0
            WORK=/root/piglit-work JOBS=$(nproc) bash release/piglit.sh all "out/$NAME.tar.xz" $PIGLIT_PROFILES || status=$?
            # the piglit results, also when the gate fails
            mkdir -p "/host/out/piglit-$ARCH" && cp -R /root/piglit-work/results/. "/host/out/piglit-$ARCH/"
            [ "$status" = 0 ] || exit "$status"
            cp "out/$NAME.tar.xz" /host/out/
            echo "container build $ARCH: OK"' > "$WORK/out/build-$arch.log" 2>&1 \
        || die "$arch build failed, see $WORK/out/build-$arch.log"
    tail -n 1 "$WORK/out/build-$arch.log"
done
ls -la "$WORK"/out/*.tar.xz

publish_archives linux-local.sh
